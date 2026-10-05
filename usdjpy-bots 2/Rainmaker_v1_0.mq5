//+------------------------------------------------------------------+
//|  Rainmaker v1.0 — Persistence-Confirmed Momentum Engine          |
//|                                                                  |
//|  The "heavy vacuum" rebuilt from 3.5yr of tick research.         |
//|  Logic:  spike fires -> must be DECELERATING (exhaustion gate)   |
//|          -> watch post-spike path tick by tick                   |
//|          -> if price PERSISTS InpConfirmPips further in the      |
//|             spike direction (before retracing), ENTER WITH it    |
//|          -> manage live: hard loss cap + trailing stop           |
//|                                                                  |
//|  Validated (friction-baked, all 4 years green):                 |
//|     CONFIRM 5 | cap 5 | trail 10 | decel-gated | full day        |
//|     ~+2.2 pips/trade net, 44% win, ~257 trades/yr               |
//|                                                                  |
//|  NOTE: depends on dense LIVE ticks. The Strategy Tester cannot   |
//|  feed ticks at live density, so the persistence detection will   |
//|  behave differently there. VALIDATE ON DEMO, not backtest.       |
//+------------------------------------------------------------------+
#property copyright "Rainmaker v1.0"
#property version   "1.00"

#include <Trade\Trade.mqh>
CTrade trade;

//--- Inputs --------------------------------------------------------
input group "=== Session (broker time) ==="
input int    InpStartHour     = 7;     // Session start hour
input int    InpEndHour       = 16;    // Session end hour (exclusive)

input group "=== Spike Detection ==="
input double InpMoveRatio     = 2.5;   // Spike = M1 move > this x rolling avg
input int    InpAvgBars       = 20;    // Bars for rolling average move
input int    InpBarTicksMin   = 0;     // Optional min ticks per spike bar (0=off)

input group "=== Exhaustion Gate (decay) ==="
input bool   InpUseDecayGate  = true;  // Only trade DECELERATING spikes
input int    InpDecayWindow   = 60;    // Seconds before spike to measure decay

input group "=== Persistence Entry ==="
input double InpConfirmPips   = 5.0;   // Pips of further push to confirm momentum
input int    InpWatchSeconds  = 1200;  // Max secs to watch for confirm (20 min)

input group "=== Trade Management ==="
input double InpLossCapPips   = 5.0;   // Hard loss cap (pips from entry)
input double InpTrailPips     = 10.0;  // Trailing stop distance (pips)
input int    InpMaxTradeMin   = 20;    // Max minutes in a trade

input group "=== Risk ==="
input double InpRiskPct       = 0.5;   // Risk % per trade (sized off loss cap)
input int    InpCooldownSecs  = 120;   // Min seconds between entries

//--- Globals -------------------------------------------------------
double   pip;
datetime lastTrade = 0;

// Spike detection (M1 bar tracking)
datetime curBarTime = 0;
double   curBarHigh = 0, curBarLow = 0, curBarOpen = 0;
int      curBarTicks = 0;
double   moveHist[];           // recent completed-bar moves (pips)
int      moveHistN = 0;

// Tick buffer (circular) for decay measurement
double   tickMids[];
datetime tickTimes[];
int      tickBufN = 0;
int      tickBufMax = 20000;

// Spike-watch state machine
bool     watching   = false;   // armed: waiting for persistence or rollover
int      spikeDir   = 0;       // +1 up spike, -1 down spike
double   spikeStart  = 0;      // mid price at spike completion
double   watchExtreme = 0;     // running extreme since spike
datetime watchBegin  = 0;

// Open position trailing
ulong    posTicket  = 0;
double   bestPrice  = 0;       // best favorable price since entry
datetime entryTime  = 0;

//+------------------------------------------------------------------+
int OnInit()
  {
   pip = (StringFind(Symbol(),"JPY") >= 0) ? 0.01 : 0.0001;
   trade.SetExpertMagicNumber(20260101);
   ArrayResize(tickMids,  tickBufMax);
   ArrayResize(tickTimes, tickBufMax);
   ArrayResize(moveHist,  InpAvgBars);
   if(MQLInfoInteger(MQL_TESTER))
      Print("Rainmaker v1.0 — WARNING: running in TESTER. Persistence detection ",
            "needs live tick density; results here are NOT representative. Use DEMO.");
   else
      Print("Rainmaker v1.0 ready — persistence-momentum, live ticks.");
   return INIT_SUCCEEDED;
  }

//+------------------------------------------------------------------+
void OnDeinit(const int reason) { Comment(""); }

//+------------------------------------------------------------------+
void OnTick()
  {
   MqlTick tk;
   if(!SymbolInfoTick(Symbol(), tk)) return;
   double mid = (tk.bid + tk.ask) / 2.0;
   datetime now = TimeCurrent();

   UpdateTickBuffer(mid, now);
   UpdateBar(mid, now);

   // 1) If a position is open, manage it (trail + cap + time) and nothing else
   if(HasPosition())
     {
      ManagePosition(tk);
      return;
     }

   // 2) If armed and watching a spike, look for persistence (enter) or rollover (disarm)
   if(watching)
     {
      WatchSpike(mid, now);
      return;
     }

   // 3) Otherwise, detection happens on bar close inside UpdateBar()
  }

//+------------------------------------------------------------------+
//| Maintain circular tick buffer                                    |
//+------------------------------------------------------------------+
void UpdateTickBuffer(double mid, datetime now)
  {
   int idx = tickBufN % tickBufMax;
   tickMids[idx]  = mid;
   tickTimes[idx] = now;
   tickBufN++;
  }

//+------------------------------------------------------------------+
//| Track current M1 bar; on bar change, finalize & test for spike   |
//+------------------------------------------------------------------+
void UpdateBar(double mid, datetime now)
  {
   datetime barTime = iTime(Symbol(), PERIOD_M1, 0);

   if(barTime != curBarTime)
     {
      // finalize the bar that just closed (if we had one)
      if(curBarTime != 0)
         OnBarClose();

      // start new bar
      curBarTime  = barTime;
      curBarOpen  = mid;
      curBarHigh  = mid;
      curBarLow   = mid;
      curBarTicks = 0;
     }

   if(mid > curBarHigh) curBarHigh = mid;
   if(mid < curBarLow)  curBarLow  = mid;
   curBarTicks++;
  }

//+------------------------------------------------------------------+
//| A completed M1 bar: compute its move, update rolling avg,        |
//| decide if it's a spike, and if so arm the watcher.               |
//+------------------------------------------------------------------+
void OnBarClose()
  {
   double moveP = (curBarHigh - curBarLow) / pip;

   // need a full rolling window before we can judge spikes
   if(moveHistN >= InpAvgBars)
     {
      double avg = 0;
      for(int i = 0; i < InpAvgBars; i++) avg += moveHist[i];
      avg /= InpAvgBars;

      bool bigEnough = (avg > 0 && moveP > InpMoveRatio * avg);
      bool ticksOK   = (InpBarTicksMin <= 0 || curBarTicks >= InpBarTicksMin);

      if(bigEnough && ticksOK && CanTrade())
        {
         // direction of the spike: close vs open of the spike bar
         int dir = (iClose(Symbol(),PERIOD_M1,1) >= iOpen(Symbol(),PERIOD_M1,1)) ? 1 : -1;

         // exhaustion gate
         if(!InpUseDecayGate || DecayIntoExtreme() > 0)
            ArmWatcher(dir);
        }
     }

   // push this bar's move into the rolling history (circular)
   moveHist[moveHistN % InpAvgBars] = moveP;
   moveHistN++;
  }

//+------------------------------------------------------------------+
//| Decay: was activity decelerating into the spike?                 |
//| (ticks in first half of window) - (ticks in second half) > 0     |
//+------------------------------------------------------------------+
double DecayIntoExtreme()
  {
   datetime now  = TimeCurrent();
   datetime mid  = now - InpDecayWindow/2;
   datetime from = now - InpDecayWindow;
   int early = 0, late = 0;
   int total = MathMin(tickBufN, tickBufMax);
   for(int i = 0; i < total; i++)
     {
      int idx = (tickBufN - 1 - i) % tickBufMax;
      if(idx < 0) idx += tickBufMax;
      datetime tt = tickTimes[idx];
      if(tt < from) break;
      if(tt >= mid) late++;
      else          early++;
     }
   // positive => decelerating (more activity earlier than later)
   return (double)(early - late);
  }

//+------------------------------------------------------------------+
void ArmWatcher(int dir)
  {
   watching     = true;
   spikeDir     = dir;
   spikeStart   = (SymbolInfoDouble(Symbol(),SYMBOL_BID)+SymbolInfoDouble(Symbol(),SYMBOL_ASK))/2.0;
   watchExtreme = spikeStart;
   watchBegin   = TimeCurrent();
   Comment("Rainmaker | ARMED ", (dir>0?"UP":"DOWN"), " spike — watching for persistence");
  }

//+------------------------------------------------------------------+
//| While armed: enter if price persists CONFIRM further in spike    |
//| direction; disarm if it rolls over CONFIRM against it first.     |
//+------------------------------------------------------------------+
void WatchSpike(double mid, datetime now)
  {
   // timeout
   if(now - watchBegin > InpWatchSeconds)
     {
      watching = false;
      Comment("Rainmaker | watch timeout — disarmed");
      return;
     }

   if(spikeDir > 0)
     {
      if(mid > watchExtreme) watchExtreme = mid;
      // rollover against the spike => this one belongs to the fade engine, not us
      if((watchExtreme - mid) / pip >= InpConfirmPips)
        { watching = false; Comment("Rainmaker | rolled over — disarmed (fade's job)"); return; }
      // persistence: extreme advanced CONFIRM beyond spike start => ENTER LONG
      if((watchExtreme - spikeStart) / pip >= InpConfirmPips)
        { watching = false; EnterMarket(1); return; }
     }
   else
     {
      if(mid < watchExtreme) watchExtreme = mid;
      if((mid - watchExtreme) / pip >= InpConfirmPips)
        { watching = false; Comment("Rainmaker | rolled over — disarmed (fade's job)"); return; }
      if((spikeStart - watchExtreme) / pip >= InpConfirmPips)
        { watching = false; EnterMarket(-1); return; }
     }
  }

//+------------------------------------------------------------------+
//+------------------------------------------------------------------+
//| LAYER 1 of protection: a WIDE broker-side "catastrophe" stop,     |
//| attached ATOMICALLY at order-send, verified after. This is not    |
//| the real exit logic — that's still the tick-by-tick cap/trail in  |
//| ManagePosition() (Layer 2), which should always fire first under  |
//| normal operation. This stop exists purely so the position is      |
//| never 100% naked if OnTick ever stops firing (disconnect, freeze, |
//| terminal crash) — it's set at 3x the intended loss cap so it      |
//| never interferes with normal trailing/exit behaviour.             |
//+------------------------------------------------------------------+
void EnterMarket(int dir)
  {
   double lots = CalcLots(InpLossCapPips);
   double price = (dir > 0) ? SymbolInfoDouble(Symbol(), SYMBOL_ASK)
                             : SymbolInfoDouble(Symbol(), SYMBOL_BID);
   double catastropheSL = (dir > 0) ? price - InpLossCapPips*3*pip
                                     : price + InpLossCapPips*3*pip;

   bool ok;
   if(dir > 0) ok = trade.Buy (lots, Symbol(), 0.0, catastropheSL, 0, "Rainmaker LONG");
   else        ok = trade.Sell(lots, Symbol(), 0.0, catastropheSL, 0, "Rainmaker SHORT");

   if(!ok)
     {
      Print("Entry failed: ", trade.ResultRetcode(), " ", trade.ResultRetcodeDescription());
      return;
     }

   lastTrade = TimeCurrent();
   entryTime = TimeCurrent();
   Sleep(10);
   if(!PositionSelect(Symbol()))
     {
      Print("Rainmaker: entry reported OK but no position found — aborting management");
      return;
     }
   posTicket = PositionGetInteger(POSITION_TICKET);
   bestPrice = PositionGetDouble(POSITION_PRICE_OPEN);

   // verify the catastrophe stop attached; retry once if not, close if it still fails
   if(PositionGetDouble(POSITION_SL) == 0.0)
     {
      double op = bestPrice;
      double retrySL = (dir > 0) ? op - InpLossCapPips*3*pip : op + InpLossCapPips*3*pip;
      bool modOk = trade.PositionModify(Symbol(), retrySL, 0);
      Sleep(10);
      PositionSelect(Symbol());
      if(!modOk || PositionGetDouble(POSITION_SL) == 0.0)
        {
         Print("Rainmaker: catastrophe SL FAILED TO ATTACH after retry — closing naked position");
         trade.PositionClose(Symbol());
         posTicket = 0; bestPrice = 0;
         return;
        }
     }

   Print("Rainmaker ENTER ", (dir>0?"LONG":"SHORT"), " lots:", lots,
         " | catastrophe SL:", PositionGetDouble(POSITION_SL), " | persistence confirmed");
   Comment("Rainmaker | IN ", (dir>0?"LONG":"SHORT"));
  }

//+------------------------------------------------------------------+
//| Live management: hard loss cap, trailing stop, max time          |
//+------------------------------------------------------------------+
void ManagePosition(MqlTick &tk)
  {
   if(!PositionSelect(Symbol())) { posTicket = 0; return; }

   long   type  = PositionGetInteger(POSITION_TYPE);
   double open  = PositionGetDouble(POSITION_PRICE_OPEN);
   double now   = TimeCurrent();

   if(type == POSITION_TYPE_BUY)
     {
      double price = tk.bid;                       // exit a long at bid
      if(price > bestPrice) bestPrice = price;
      double lossP  = (open  - price) / pip;       // +ve = losing
      double giveP  = (bestPrice - price) / pip;   // pullback from best
      if(lossP >= InpLossCapPips)                   { CloseNow("loss cap"); return; }
      if(bestPrice > open && giveP >= InpTrailPips)  { CloseNow("trail");    return; }
     }
   else // SELL
     {
      double price = tk.ask;                       // exit a short at ask
      if(price < bestPrice || bestPrice == 0) bestPrice = price;
      double lossP  = (price - open) / pip;
      double giveP  = (price - bestPrice) / pip;
      if(lossP >= InpLossCapPips)                   { CloseNow("loss cap"); return; }
      if(bestPrice < open && giveP >= InpTrailPips)  { CloseNow("trail");    return; }
     }

   if(now - entryTime > InpMaxTradeMin * 60)        { CloseNow("max time"); return; }
  }

//+------------------------------------------------------------------+
void CloseNow(string why)
  {
   if(trade.PositionClose(Symbol()))
     {
      Print("Rainmaker CLOSE (", why, ")");
      Comment("Rainmaker | flat (", why, ")");
      posTicket = 0;
      bestPrice = 0;
     }
  }

//+------------------------------------------------------------------+
bool HasPosition()
  {
   return (PositionSelect(Symbol()) &&
           PositionGetInteger(POSITION_MAGIC) == 20260101);
  }

//+------------------------------------------------------------------+
bool CanTrade()
  {
   if(!SessionOK())                                  return false;
   if(TimeCurrent() - lastTrade < InpCooldownSecs)   return false;
   if(watching)                                      return false;
   if(HasPosition())                                 return false;
   return true;
  }

//+------------------------------------------------------------------+
bool SessionOK()
  {
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   return (dt.hour >= InpStartHour && dt.hour < InpEndHour);
  }

//+------------------------------------------------------------------+
double CalcLots(double stopPips)
  {
   double balance  = AccountInfoDouble(ACCOUNT_BALANCE);
   double risk     = balance * InpRiskPct / 100.0;
   double tickVal  = SymbolInfoDouble(Symbol(), SYMBOL_TRADE_TICK_VALUE);
   double tickSize = SymbolInfoDouble(Symbol(), SYMBOL_TRADE_TICK_SIZE);
   if(tickVal <= 0 || tickSize <= 0 || stopPips <= 0) return 0.01;
   double pipVal   = tickVal * (pip / tickSize);
   if(pipVal <= 0) return 0.01;
   double lots     = risk / (stopPips * pipVal);
   double step     = SymbolInfoDouble(Symbol(), SYMBOL_VOLUME_STEP);
   double minL     = SymbolInfoDouble(Symbol(), SYMBOL_VOLUME_MIN);
   double maxL     = SymbolInfoDouble(Symbol(), SYMBOL_VOLUME_MAX);
   lots = MathFloor(lots / step) * step;
   return MathMax(minL, MathMin(maxL, lots));
  }

//+------------------------------------------------------------------+
void OnTradeTransaction(const MqlTradeTransaction &trans,
                        const MqlTradeRequest     &request,
                        const MqlTradeResult      &result)
  {
   if(trans.type == TRADE_TRANSACTION_DEAL_ADD)
      if(HistoryDealSelect(trans.deal))
        {
         double profit = HistoryDealGetDouble(trans.deal, DEAL_PROFIT);
         if(profit != 0.0)
            Print("Rainmaker Deal | Profit: ", profit);
        }
  }
//+------------------------------------------------------------------+
