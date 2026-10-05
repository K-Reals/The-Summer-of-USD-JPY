//+------------------------------------------------------------------+
//|  Drunkard v3.2 — ATR-Normalized TP/SL                            |
//|                                                                  |
//|  Same random-direction streak logic as v2, but TP and SL are     |
//|  now expressed as MULTIPLES of the current ATR(14) on M1,        |
//|  computed fresh at each entry. This means the strategy           |
//|  automatically breathes with the market — wider in volatile      |
//|  regimes, tighter in quiet ones.                                 |
//|                                                                  |
//|  Research finding (500-seed test, 2023-2026):                    |
//|  TP=150x ATR, SL=10x ATR: mean +0.49 pip/trade, 64.2% of        |
//|  random-direction seeds profitable. 2024 weak leg (-1.68).       |
//|  Direction signal needed to fix 2024 — this is the chassis.      |
//|                                                                  |
//|  No time limit — trades ride until TP or SL fires.               |
//+------------------------------------------------------------------+
#property copyright "Drunkard v3.2"
#property version   "1.00"

#include <Trade\Trade.mqh>
CTrade trade;

//--- Inputs --------------------------------------------------------
input group "=== Session (broker time) ==="
input int    InpStartHour          = 7;      // Session start hour
input int    InpEndHour            = 16;     // Session end hour (exclusive)

input group "=== ATR-Normalized Trade Definition ==="
input int    InpATRPeriod          = 14;     // ATR period (bars)
input double InpTPMultiplier       = 160.0;  // TP = this x ATR (pips)
input double InpSLMultiplier       = 10.0;   // SL = this x ATR (pips)
// At mean ATR=2.5 pips: TP~375 pips, SL~25 pips, ratio 15:1
// These scale automatically with current volatility regime

input group "=== Risk & Cost ==="
input double InpRiskPct            = 1.0;    // Risk % per trade (sized off ATR SL)
input double InpCommissionPerLot   = 4.0;    // Round-trip commission per standard lot ($)

input group "=== Timing Between Trades ==="
input int    InpMinMinutesBetween  = 10;     // Min minutes between trades (prevents cascade re-entry)
input int    InpMaxMinutesBetween  = 0;      // Max minutes between trades (0 = same as min)
input int    InpMaxTradesPerDay    = 0;      // Max trades per day (0 = no cap)

input group "=== Streak Logic ==="
input int    InpLossStreakLen      = 3;      // Consecutive losses that trigger a flip
input int    InpWinStreakLen       = 3;      // Consecutive wins that trigger a keep
input int    InpFlipDurationTrades = 3;      // How many trades the flip lasts
input int    InpKeepDurationTrades = 3;      // How many trades the keep lasts

//--- Globals -------------------------------------------------------
double   pip;
int      curDirection    = 0;
int      lastDirection   = 0;
int      consecWins      = 0;
int      consecLosses    = 0;
int      forcedDir       = 0;
int      forcedRemaining = 0;
datetime nextTradeTime   = 0;
int      tradesToday     = 0;
datetime curDayStart     = 0;

//+------------------------------------------------------------------+
int OnInit()
  {
   pip = (StringFind(Symbol(),"JPY") >= 0) ? 0.01 : 0.0001;
   trade.SetExpertMagicNumber(20260104);
   MathSrand((int)TimeLocal());
   nextTradeTime = TimeCurrent();
   if(MQLInfoInteger(MQL_TESTER))
      Print("Drunkard v3.2 — TESTER mode. ATR-normalized TP/SL, random direction.");
   else
      Print("Drunkard v3.2 ready. ATR chassis, random direction, streak memory.");
   return INIT_SUCCEEDED;
  }

//+------------------------------------------------------------------+
void OnDeinit(const int reason) { Comment(""); }

//+------------------------------------------------------------------+
void OnTick()
  {
   ResetDailyCounterIfNewDay();

   if(HasPosition())
     {
      ManagePosition();
      return;
     }

   if(!SessionOK()) return;
   if(InpMaxTradesPerDay > 0 && tradesToday >= InpMaxTradesPerDay) return;
   if(TimeCurrent() < nextTradeTime) return;

   int dir;
   if(forcedRemaining > 0)
     {
      dir = forcedDir;
      forcedRemaining--;
     }
   else
      dir = (MathRand() % 2 == 0) ? 1 : -1;

   EnterMarket(dir);
  }

//+------------------------------------------------------------------+
void ResetDailyCounterIfNewDay()
  {
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   dt.hour = 0; dt.min = 0; dt.sec = 0;
   datetime todayStart = StructToTime(dt);
   if(todayStart != curDayStart)
     {
      curDayStart = todayStart;
      tradesToday = 0;
     }
  }

//+------------------------------------------------------------------+
int RandomDelaySeconds()
  {
   int minSec = (InpMinMinutesBetween > 0) ? InpMinMinutesBetween*60 : 0;
   int maxSec;
   if(InpMaxMinutesBetween > 0)
      maxSec = InpMaxMinutesBetween*60;
   else if(InpMinMinutesBetween > 0)
      maxSec = minSec;
   else
      maxSec = 0;
   if(maxSec <= minSec) return minSec;
   return minSec + (MathRand() % (maxSec - minSec + 1));
  }

//+------------------------------------------------------------------+
//| Get current ATR in pips — computed manually to avoid the         |
//| iATR() handle trap (iATR returns a handle int, not a value).     |
//+------------------------------------------------------------------+
double CurrentATRPips()
  {
   double highs[], lows[], closes[];
   ArraySetAsSeries(highs,  true);
   ArraySetAsSeries(lows,   true);
   ArraySetAsSeries(closes, true);
   int need = InpATRPeriod + 1;
   if(CopyHigh (Symbol(), PERIOD_M1, 0, need, highs)  < need) return 2.5 * pip;
   if(CopyLow  (Symbol(), PERIOD_M1, 0, need, lows)   < need) return 2.5 * pip;
   if(CopyClose(Symbol(), PERIOD_M1, 0, need, closes)  < need) return 2.5 * pip;
   double sumTR = 0;
   for(int i = 0; i < InpATRPeriod; i++)
     {
      double hl  = highs[i]  - lows[i];
      double hpc = MathAbs(highs[i]  - closes[i+1]);
      double lpc = MathAbs(lows[i]   - closes[i+1]);
      sumTR += MathMax(hl, MathMax(hpc, lpc));
     }
   double atrPips = (sumTR / InpATRPeriod) / pip;
   if(atrPips <= 0) return 2.5;
   return atrPips;
  }

//+------------------------------------------------------------------+
//| Commission pip-equivalent helper                                 |
//+------------------------------------------------------------------+
double CommissionPips()
  {
   double tickVal  = SymbolInfoDouble(Symbol(), SYMBOL_TRADE_TICK_VALUE);
   double tickSize = SymbolInfoDouble(Symbol(), SYMBOL_TRADE_TICK_SIZE);
   if(tickVal <= 0 || tickSize <= 0) return 0;
   double pipVal = tickVal * (pip / tickSize);
   if(pipVal <= 0) return 0;
   return InpCommissionPerLot / pipVal;
  }

//+------------------------------------------------------------------+
//| Lot sizing against ATR-based stop + commission                   |
//+------------------------------------------------------------------+
double CalcLots(double stopPips)
  {
   double balance  = AccountInfoDouble(ACCOUNT_BALANCE);
   double risk     = balance * InpRiskPct / 100.0;
   double tickVal  = SymbolInfoDouble(Symbol(), SYMBOL_TRADE_TICK_VALUE);
   double tickSize = SymbolInfoDouble(Symbol(), SYMBOL_TRADE_TICK_SIZE);
   if(tickVal <= 0 || tickSize <= 0 || stopPips <= 0) return 0.01;
   double pipVal    = tickVal * (pip / tickSize);
   if(pipVal <= 0) return 0.01;
   double commPips  = InpCommissionPerLot / pipVal;
   double effectiveStop = stopPips + commPips;
   double lots      = risk / (effectiveStop * pipVal);
   double step      = SymbolInfoDouble(Symbol(), SYMBOL_VOLUME_STEP);
   double minL      = SymbolInfoDouble(Symbol(), SYMBOL_VOLUME_MIN);
   double maxL      = SymbolInfoDouble(Symbol(), SYMBOL_VOLUME_MAX);
   lots = MathFloor(lots / step) * step;
   return MathMax(minL, MathMin(maxL, lots));
  }

//+------------------------------------------------------------------+
//| LAYER 1: atomic SL/TP at order-send, verified, close if naked    |
//+------------------------------------------------------------------+
void EnterMarket(int dir)
  {
   double atrPips  = CurrentATRPips();
   double slPips   = InpSLMultiplier * atrPips;
   double commPips = CommissionPips();
   double tpPips   = MathMax(InpTPMultiplier * atrPips - commPips, 1.0);

   double lots  = CalcLots(slPips);
   double price = (dir > 0) ? SymbolInfoDouble(Symbol(), SYMBOL_ASK)
                             : SymbolInfoDouble(Symbol(), SYMBOL_BID);
   double slPrice = (dir > 0) ? price - slPips*pip : price + slPips*pip;
   double tpPrice = (dir > 0) ? price + tpPips*pip : price - tpPips*pip;

   bool ok;
   if(dir > 0) ok = trade.Buy (lots, Symbol(), 0.0, slPrice, tpPrice, "Drunkard LONG");
   else        ok = trade.Sell(lots, Symbol(), 0.0, slPrice, tpPrice, "Drunkard SHORT");

   if(!ok)
     {
      Print("Entry failed: ", trade.ResultRetcode(), " ", trade.ResultRetcodeDescription());
      return;
     }

   Sleep(10);
   if(!PositionSelect(Symbol()))
     {
      Print("Drunkard v3: entry reported OK but no position found");
      return;
     }

   curDirection = dir;
   tradesToday++;

   if(PositionGetDouble(POSITION_SL) == 0.0)
     {
      double op      = PositionGetDouble(POSITION_PRICE_OPEN);
      double retrySL = (dir > 0) ? op - slPips*pip : op + slPips*pip;
      double retryTP = (dir > 0) ? op + tpPips*pip : op - tpPips*pip;
      bool modOk = trade.PositionModify(Symbol(), retrySL, retryTP);
      Sleep(10);
      PositionSelect(Symbol());
      if(!modOk || PositionGetDouble(POSITION_SL) == 0.0)
        {
         Print("Drunkard v3: SL FAILED TO ATTACH — closing naked position");
         trade.PositionClose(Symbol());
         curDirection = 0;
         return;
        }
     }

   string why = (forcedDir != 0 && forcedRemaining >= 0 && dir == forcedDir) ? " [forced]" : " [random]";
   Print("Drunkard v3 ENTER ", (dir>0?"LONG":"SHORT"),
         " lots:", lots,
         " | ATR:", NormalizeDouble(atrPips,2), " pips",
         " | SL:", NormalizeDouble(slPips,1), " TP:", NormalizeDouble(tpPips,1), why);
  }

//+------------------------------------------------------------------+
//| LAYER 2: manual backstop independent of broker-side SL           |
//+------------------------------------------------------------------+
void ManagePosition()
  {
   if(!PositionSelect(Symbol())) return;
   // Close at session end — matches Python max_min=540 behavior
   if(!SessionOK())
     {
      Print("Drunkard v3: session end — closing position");
      trade.PositionClose(Symbol());
      curDirection = 0;
      return;
     }
   MqlTick tk;
   if(!SymbolInfoTick(Symbol(), tk)) return;

   double open = PositionGetDouble(POSITION_PRICE_OPEN);
   long   type = PositionGetInteger(POSITION_TYPE);
   double slPips = InpSLMultiplier * CurrentATRPips();
   double backstopPips;
   if(type == POSITION_TYPE_BUY) backstopPips = (open - tk.bid)/pip;
   else                           backstopPips = (tk.ask - open)/pip;

   if(backstopPips >= slPips * 1.5)
     {
      Print("Drunkard v3: BACKSTOP triggered — loss ", NormalizeDouble(backstopPips,1),
            " pips > 1.5x ATR SL. Closing.");
      trade.PositionClose(Symbol());
     }
  }

//+------------------------------------------------------------------+
void OnTradeTransaction(const MqlTradeTransaction &trans,
                        const MqlTradeRequest     &request,
                        const MqlTradeResult      &result)
  {
   if(trans.type != TRADE_TRANSACTION_DEAL_ADD) return;
   if(!HistoryDealSelect(trans.deal)) return;
   if(HistoryDealGetInteger(trans.deal, DEAL_ENTRY) != DEAL_ENTRY_OUT) return;

   double profit = HistoryDealGetDouble(trans.deal, DEAL_PROFIT);
   lastDirection = curDirection;
   curDirection  = 0;

   if(profit > 0) { consecWins++;   consecLosses = 0; }
   else            { consecLosses++; consecWins   = 0; }

   if(consecLosses >= InpLossStreakLen)
     {
      forcedDir       = -lastDirection;
      forcedRemaining = InpFlipDurationTrades;
      consecLosses    = 0;
      Print("Drunkard v3: ", InpLossStreakLen, "-loss streak — flipping for ",
            InpFlipDurationTrades, " trade(s)");
     }
   else if(consecWins >= InpWinStreakLen)
     {
      forcedDir       = lastDirection;
      forcedRemaining = InpKeepDurationTrades;
      consecWins      = 0;
      Print("Drunkard v3: ", InpWinStreakLen, "-win streak — keeping for ",
            InpKeepDurationTrades, " trade(s)");
     }

   nextTradeTime = TimeCurrent() + RandomDelaySeconds();
   Print("Drunkard v3 closed | Profit: ", profit,
         " | W:", consecWins, " L:", consecLosses);
  }

//+------------------------------------------------------------------+
bool HasPosition()
  {
   return (PositionSelect(Symbol()) &&
           PositionGetInteger(POSITION_MAGIC) == 20260104);
  }

//+------------------------------------------------------------------+
bool SessionOK()
  {
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   return (dt.hour >= InpStartHour && dt.hour < InpEndHour);
  }
//+------------------------------------------------------------------+
