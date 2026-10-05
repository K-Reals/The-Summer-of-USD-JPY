//+------------------------------------------------------------------+
//|  SpikeCatcher EA v7.3 — Velocity + Decay Filter + Dynamic TP    |
//|  Only trades when volatility decay is in extreme range           |
//|  Skips middling/ambiguous pre-spike environments                 |
//+------------------------------------------------------------------+
#property copyright "SpikeCatcher v7.6"
#property version   "7.60"

#include <Trade\Trade.mqh>
CTrade trade;

//--- Inputs
input group "=== Session ==="
input int    InpStartHour      = 9;     // Session start (broker time)
input int    InpEndHour        = 10;    // Session end (broker time)

input group "=== Velocity Signal ==="
input double InpVelMinQ4       = 2.80;  // Min ticks/second (live mode)
input int    InpBarTicksMin    = 720;   // Min ticks per M1 bar (backtest mode)

input group "=== Decay Filter ==="
input double InpDecayHigh      = 0.15;  // Min positive decay for bull signal
input double InpDecayLow       = -0.21; // Max negative decay for bear signal
input int    InpDecayWindow    = 60;    // Seconds to measure decay

input group "=== Dynamic TP ==="
input int    InpTPLookback     = 200;    // M1 bars to average for dynamic TP
input double InpTPMultiplier   = 6.0;   // TP = avg spike size x this
input double InpTPMinPips      = 20.0;  // Minimum TP in pips
input double InpTPMaxPips      = 200.0;  // Maximum TP in pips

input group "=== Bracket ==="
input double InpOffsetPips     = 7.0;   // Pips above/below price for stops
input double InpSLPips         = 6.0;   // Stop loss in pips
input int    InpExpirySeconds  = 80;    // Cancel bracket after X seconds
input bool   InpUseTrailing    = false;  // Use trailing stop?
input double InpTrailPips      = 20.0;  // Trailing stop distance in pips
input double InpTrailStartPips = 50.0;  // Start trailing after X pips profit

input group "=== Regime Filter ==="
input bool   InpUseRegime        = true;   // Use regime filter?
input int    InpRegimeLookback   = 5;      // Number of recent trades to measure
input double InpRegimeMinFollow  = 10.0;   // Min avg follow-through to trade (pips)

input group "=== Directional Score ==="
input bool   InpUseScore       = true;   // Use directional score filter?
input int    InpScoreThreshold = 4;      // Score to override bracket with single entry
input int    InpTickWindow     = 30;     // Seconds of ticks to analyse

input group "=== Direction ==="
input int    InpDirection      = 0;     // 0=Both, 1=Long only, -1=Short only

input group "=== Risk ==="
input double InpRiskPct        = 1.0;   // Risk % per trade
input int    InpCooldownSecs   = 120;   // Seconds between signals

//--- Globals
double   pip;
datetime lastTrade    = 0;
ulong    ticketBuy    = 0;
ulong    ticketSell   = 0;
datetime bracketTime  = 0;
bool     bracketOn    = false;

// Tick counting
int      barTicks     = 0;
datetime currentBar   = 0;

// Velocity tracking
int      velTicks     = 0;
datetime velStart     = 0;

// Regime tracking
double   recentFollows[];   // stores follow-through of last N completed trades
int      recentFollowCount = 0;

// Tick buffer for directional score
double   tickMids[];          // rolling tick mid prices
datetime tickTimes[];         // rolling tick timestamps
int      tickBufSize = 0;
int      tickBufMax  = 5000;  // max ticks to store

// Per-second pip movement for decay calculation
double   pipMovements[60];  // rolling 60 seconds
datetime lastSecond   = 0;
double   secHigh      = 0;
double   secLow       = 0;

//+------------------------------------------------------------------+
int OnInit()
  {
   pip = (StringFind(Symbol(),"JPY") >= 0) ? 0.01 : 0.0001;
   trade.SetExpertMagicNumber(20240703);
   ArrayInitialize(pipMovements, 0);
   ArrayResize(recentFollows, InpRegimeLookback);
   ArrayInitialize(recentFollows, 999);
   ArrayResize(tickMids,  tickBufMax);
   ArrayResize(tickTimes, tickBufMax);
   Print("SpikeCatcher v7.6 ready on ", Symbol());
   return INIT_SUCCEEDED;
  }

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
   DeleteBracket();
   Comment("");
  }

//+------------------------------------------------------------------+
void OnTick()
  {
   // --- Update trackers ---
   UpdateDecayTracker();
   
   // --- Manage trailing stop ---
   if(InpUseTrailing) ManageTrailingStop();

   // Per bar tick count
   datetime thisBar = iTime(Symbol(), PERIOD_M1, 0);
   if(thisBar != currentBar) { currentBar = thisBar; barTicks = 0; }
   barTicks++;

   // Per second velocity
   datetime now = TimeCurrent();
   if(velStart == 0) velStart = now;
   velTicks++;
   double elapsed  = (double)(now - velStart);
   double velocity = (elapsed > 0) ? velTicks / elapsed : 0;
   if(elapsed >= 30) { velTicks = 0; velStart = now; }

   // --- Manage bracket ---
   if(bracketOn) { ManageBracket(); return; }

   // --- Gates ---
   if(!SessionOK())                                return;
   if(PositionsTotal() > 0)                        return;
   if(TimeCurrent() - lastTrade < InpCooldownSecs) return;

   // --- Velocity signal ---
   bool isBacktest = (MQLInfoInteger(MQL_TESTER) == 1);
   bool velSignal  = (!isBacktest && velocity >= InpVelMinQ4);
   bool barSignal  = (barTicks >= InpBarTicksMin);
   if(!velSignal && !barSignal)
     {
      Comment("v7.3 | Ticks:", barTicks, "/", InpBarTicksMin);
      return;
     }

   // --- Regime filter ---
   if(InpUseRegime && !IsGoodRegime())
     {
      Comment("v7.6 | Vel OK | Regime filter: poor follow-through");
      return;
     }

   // --- Decay filter ---
   double decay = GetDecay();
   bool decayOK = (decay > InpDecayHigh || decay < InpDecayLow);

   if(!decayOK)
     {
      Comment("v7.3 | Vel OK | Decay filtered: ", DoubleToString(decay,3));
      return;
     }

   // --- Place bracket ---
   Print("v7.3 SIGNAL | Ticks:", barTicks, " Vel:", DoubleToString(velocity,1),
         " Decay:", DoubleToString(decay,3));
   PlaceBracket();
  }

//+------------------------------------------------------------------+
void UpdateDecayTracker()
  {
   MqlTick tick;
   if(!SymbolInfoTick(Symbol(), tick)) return;
   double mid = (tick.bid + tick.ask) / 2.0;
   datetime now = TimeCurrent();

   if(lastSecond == 0) { lastSecond = now; secHigh = mid; secLow = mid; }
   if(mid > secHigh) secHigh = mid;
   if(mid < secLow)  secLow  = mid;

   if(now > lastSecond)
     {
      double pipMove = (secHigh - secLow) * 100;
      for(int i = 58; i >= 0; i--) pipMovements[i+1] = pipMovements[i];
      pipMovements[0] = pipMove;
      lastSecond = now; secHigh = mid; secLow = mid;
     }

   // Update tick buffer — shift if full
   if(tickBufSize < tickBufMax)
     {
      tickMids[tickBufSize]  = mid;
      tickTimes[tickBufSize] = now;
      tickBufSize++;
     }
   else
     {
      for(int i = 0; i < tickBufMax-1; i++)
        { tickMids[i] = tickMids[i+1]; tickTimes[i] = tickTimes[i+1]; }
      tickMids[tickBufMax-1]  = mid;
      tickTimes[tickBufMax-1] = now;
     }
  }

//+------------------------------------------------------------------+
int GetDirectionalScore()
  {
   // Get ticks from last InpTickWindow seconds
   datetime cutoff = TimeCurrent() - InpTickWindow;
   int start = 0;
   for(int i = 0; i < tickBufSize; i++)
     { if(tickTimes[i] >= cutoff) { start = i; break; } }

   int n = tickBufSize - start;
   if(n < 10) return 0;

   // Extract recent mid prices
   double prices[];
   ArrayResize(prices, n);
   for(int i = 0; i < n; i++) prices[i] = tickMids[start + i];

   int score = 0;

   // 1. Path convexity — is midpoint above or below start?
   double midpoint = prices[n/2];
   double start_p  = prices[0];
   double convexity = (midpoint - start_p) * 100;
   if(convexity > 0.02)  score += 2;  // curving up
   if(convexity < -0.02) score -= 2;  // curving down

   // 2. Price drift — where did price end vs start?
   double drift = (prices[n-1] - prices[0]) * 100;
   if(drift > 0.02)  score += 2;
   if(drift < -0.02) score -= 2;

   // 3. Lower lows — second half vs first half
   double first_low  = prices[0];
   double second_low = prices[0];
   for(int i = 0;   i < n/2; i++) if(prices[i] < first_low)  first_low  = prices[i];
   for(int i = n/2; i < n;   i++) if(prices[i] < second_low) second_low = prices[i];
   if(second_low < first_low) score -= 1;  // lower lows = bear

   // 4. Run asymmetry — up runs vs down runs
   double sumUp = 0, sumDown = 0;
   int cntUp = 0, cntDown = 0;
   int runLen = 1;
   int runDir = (prices[1] > prices[0]) ? 1 : -1;

   for(int i = 2; i < n; i++)
     {
      int d = (prices[i] > prices[i-1]) ? 1 : (prices[i] < prices[i-1] ? -1 : runDir);
      if(d == runDir) { runLen++; }
      else
        {
         if(runDir > 0) { sumUp   += runLen; cntUp++;   }
         else           { sumDown += runLen; cntDown++; }
         runDir = d; runLen = 1;
        }
     }
   if(runDir > 0) { sumUp   += runLen; cntUp++;   }
   else           { sumDown += runLen; cntDown++; }

   double avgUp   = (cntUp   > 0) ? sumUp   / cntUp   : 0;
   double avgDown = (cntDown > 0) ? sumDown / cntDown : 0;
   double asymmetry = avgUp - avgDown;
   if(asymmetry > 0.1)  score += 1;
   if(asymmetry < -0.1) score -= 1;

   return score;
  }

//+------------------------------------------------------------------+
double GetDecay()
  {
   // Early window: seconds 40-60 before spike
   // Recent window: seconds 0-20 before spike
   double earlyAvg  = 0;
   double recentAvg = 0;

   for(int i = 0;  i < 20; i++) recentAvg += pipMovements[i];
   for(int i = 40; i < 60; i++) earlyAvg  += pipMovements[i];

   recentAvg /= 20.0;
   earlyAvg  /= 20.0;

   return earlyAvg - recentAvg;  // positive = decaying, negative = increasing
  }

//+------------------------------------------------------------------+
double GetDynamicTP()
  {
   double sum   = 0;
   int    count = 0;
   double avgRange = 0;

   for(int i = 1; i <= 20; i++)
      avgRange += (iHigh(Symbol(), PERIOD_M1, i) - iLow(Symbol(), PERIOD_M1, i)) * 100;
   avgRange /= 20.0;

   for(int i = 1; i <= InpTPLookback; i++)
     {
      double range = (iHigh(Symbol(), PERIOD_M1, i) - iLow(Symbol(), PERIOD_M1, i)) * 100;
      if(range > avgRange) { sum += range; count++; }
     }

   if(count == 0) return InpTPMinPips;
   double dynTP = (sum / count) * InpTPMultiplier;
   return MathMax(InpTPMinPips, MathMin(InpTPMaxPips, dynTP));
  }

//+------------------------------------------------------------------+
void PlaceBracket()
  {
   double lots  = CalcLots();
   double ask   = SymbolInfoDouble(Symbol(), SYMBOL_ASK);
   double bid   = SymbolInfoDouble(Symbol(), SYMBOL_BID);
   double mid   = (ask + bid) / 2.0;
   double dynTP = GetDynamicTP();

   // Get directional score
   int  dirScore   = InpUseScore ? GetDirectionalScore() : 0;
   bool strongBull = (dirScore >=  InpScoreThreshold);
   bool strongBear = (dirScore <= -InpScoreThreshold);

   double buyEntry  = mid + InpOffsetPips * pip;
   double sellEntry = mid - InpOffsetPips * pip;
   double buySL     = buyEntry  - InpSLPips * pip;
   double buyTP     = buyEntry  + dynTP     * pip;
   double sellSL    = sellEntry + InpSLPips * pip;
   double sellTP    = sellEntry - dynTP     * pip;

   bool   ok        = false;
   string tradeType = "BRACKET";

   // Strong bull — single buy only
   if(strongBull && InpDirection >= 0)
     {
      tradeType = "DIRECTED BUY";
      if(trade.BuyStop(lots, buyEntry, Symbol(), buySL, buyTP, ORDER_TIME_GTC, 0, "v7.6 BUY"))
        { ticketBuy = trade.ResultOrder(); ok = true; }
      else Print("BuyStop failed: ", trade.ResultRetcode());
     }
   // Strong bear — single sell only
   else if(strongBear && InpDirection <= 0)
     {
      tradeType = "DIRECTED SELL";
      if(trade.SellStop(lots, sellEntry, Symbol(), sellSL, sellTP, ORDER_TIME_GTC, 0, "v7.6 SELL"))
        { ticketSell = trade.ResultOrder(); ok = true; }
      else Print("SellStop failed: ", trade.ResultRetcode());
     }
   // No strong signal — full bracket
   else
     {
      if(InpDirection >= 0)
         if(trade.BuyStop(lots, buyEntry, Symbol(), buySL, buyTP, ORDER_TIME_GTC, 0, "v7.6 BUY"))
           { ticketBuy = trade.ResultOrder(); ok = true; }
         else Print("BuyStop failed: ", trade.ResultRetcode());

      if(InpDirection <= 0)
         if(trade.SellStop(lots, sellEntry, Symbol(), sellSL, sellTP, ORDER_TIME_GTC, 0, "v7.6 SELL"))
           { ticketSell = trade.ResultOrder(); ok = true; }
         else Print("SellStop failed: ", trade.ResultRetcode());
     }

   if(ok)
     {
      bracketOn   = true;
      bracketTime = TimeCurrent();
      lastTrade   = TimeCurrent();
      Print("v7.6 | ", tradeType, " | Score:", dirScore,
            " | TP:", DoubleToString(dynTP,1), "pips | Lots:", lots);
      Comment("v7.6 | ", tradeType, " | Score:", dirScore,
              " | TP:", DoubleToString(dynTP,1));
     }
  }

//+------------------------------------------------------------------+
void ManageBracket()
  {
   if(TimeCurrent() - bracketTime > InpExpirySeconds)
     { DeleteBracket(); return; }

   bool buyPending  = OrderSelect(ticketBuy);
   bool sellPending = OrderSelect(ticketSell);

   if(!buyPending && ticketBuy > 0)
     {
      if(sellPending) trade.OrderDelete(ticketSell);
      ticketBuy = 0; ticketSell = 0; bracketOn = false;
      Print("v7.6 BUY triggered");
     }
   if(!sellPending && ticketSell > 0)
     {
      if(buyPending) trade.OrderDelete(ticketBuy);
      ticketBuy = 0; ticketSell = 0; bracketOn = false;
      Print("v7.6 SELL triggered");
     }
  }

//+------------------------------------------------------------------+
void DeleteBracket()
  {
   if(ticketBuy  > 0 && OrderSelect(ticketBuy))  trade.OrderDelete(ticketBuy);
   if(ticketSell > 0 && OrderSelect(ticketSell)) trade.OrderDelete(ticketSell);
   ticketBuy = 0; ticketSell = 0; bracketOn = false;
  }

//+------------------------------------------------------------------+
double CalcLots()
  {
   double balance  = AccountInfoDouble(ACCOUNT_BALANCE);
   double risk     = balance * InpRiskPct / 100.0;
   double tickVal  = SymbolInfoDouble(Symbol(), SYMBOL_TRADE_TICK_VALUE);
   double tickSize = SymbolInfoDouble(Symbol(), SYMBOL_TRADE_TICK_SIZE);
   if(tickVal <= 0 || tickSize <= 0) return 0.01;
   double pipVal   = tickVal * (pip / tickSize);
   if(pipVal <= 0) return 0.01;
   double lots     = risk / (InpSLPips * pipVal);
   double step     = SymbolInfoDouble(Symbol(), SYMBOL_VOLUME_STEP);
   double minL     = SymbolInfoDouble(Symbol(), SYMBOL_VOLUME_MIN);
   double maxL     = SymbolInfoDouble(Symbol(), SYMBOL_VOLUME_MAX);
   lots = MathFloor(lots / step) * step;
   return MathMax(minL, MathMin(maxL, lots));
  }

//+------------------------------------------------------------------+
void ManageTrailingStop()
  {
   double trailDist  = InpTrailPips      * pip;
   double trailStart = InpTrailStartPips * pip;

   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong ticket = PositionGetTicket(i);
      if(!PositionSelectByTicket(ticket)) continue;
      if(PositionGetString(POSITION_SYMBOL) != Symbol()) continue;
      if(PositionGetInteger(POSITION_MAGIC) != 20240703) continue;

      double openPrice = PositionGetDouble(POSITION_PRICE_OPEN);
      double currentSL = PositionGetDouble(POSITION_SL);
      double currentTP = PositionGetDouble(POSITION_TP);
      long   posType   = PositionGetInteger(POSITION_TYPE);

      if(posType == POSITION_TYPE_BUY)
        {
         double bid   = SymbolInfoDouble(Symbol(), SYMBOL_BID);
         double profit = bid - openPrice;
         if(profit < trailStart) continue; // not enough profit yet
         double newSL = bid - trailDist;
         if(newSL > currentSL + pip)
            trade.PositionModify(ticket, newSL, currentTP);
        }
      else if(posType == POSITION_TYPE_SELL)
        {
         double ask   = SymbolInfoDouble(Symbol(), SYMBOL_ASK);
         double profit = openPrice - ask;
         if(profit < trailStart) continue;
         double newSL = ask + trailDist;
         if(newSL < currentSL - pip || currentSL == 0)
            trade.PositionModify(ticket, newSL, currentTP);
        }
     }
  }

//+------------------------------------------------------------------+
bool IsGoodRegime()
  {
   // Calculate average follow-through of last N completed trades
   double sum = 0;
   for(int i = 0; i < InpRegimeLookback; i++)
      sum += recentFollows[i];
   double avg = sum / InpRegimeLookback;
   return (avg >= InpRegimeMinFollow);
  }

//+------------------------------------------------------------------+
void OnTradeTransaction(const MqlTradeTransaction &trans,
                        const MqlTradeRequest     &request,
                        const MqlTradeResult      &result)
  {
   if(trans.type != TRADE_TRANSACTION_DEAL_ADD) return;
   if(!HistoryDealSelect(trans.deal)) return;
   if(HistoryDealGetInteger(trans.deal, DEAL_MAGIC) != 20240703) return;
   if(HistoryDealGetInteger(trans.deal, DEAL_ENTRY) != DEAL_ENTRY_OUT) return;

   double profit    = HistoryDealGetDouble(trans.deal, DEAL_PROFIT);
   double volume    = HistoryDealGetDouble(trans.deal, DEAL_VOLUME);
   double priceIn   = HistoryDealGetDouble(trans.deal, DEAL_PRICE);
   
   // Approximate follow-through in pips from profit
   double tickVal   = SymbolInfoDouble(Symbol(), SYMBOL_TRADE_TICK_VALUE);
   double tickSize  = SymbolInfoDouble(Symbol(), SYMBOL_TRADE_TICK_SIZE);
   double pipVal    = (tickVal > 0 && tickSize > 0) ? tickVal * (pip / tickSize) : 1;
   double followPips = MathAbs(profit) / (volume * pipVal);
   if(profit < 0) followPips = -followPips; // negative for losses

   // Shift array and add new value
   for(int i = InpRegimeLookback-1; i > 0; i--)
      recentFollows[i] = recentFollows[i-1];
   recentFollows[0] = followPips;

   Print("v7.6 Trade closed | Follow: ", DoubleToString(followPips,1), 
         " pips | Regime avg: ", DoubleToString(recentFollows[0],1));
  }

//+------------------------------------------------------------------+
bool SessionOK()
  {
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   return (dt.hour >= InpStartHour && dt.hour < InpEndHour);
  }
//+------------------------------------------------------------------+
