//+------------------------------------------------------------------+
//|  Monkey v2.0 — Literal "It's Going Up, So It Must Keep Going Up" |
//|                                                                  |
//|  NOT a validated edge. Built deliberately to let you play with   |
//|  the levers and see how they behave. Python test of this exact  |
//|  logic (5min/5pip trigger, SL7/arm3/lock1/TP7/15min) lost        |
//|  ~-0.95 pips/trade, every year, 2023-2026, ~51 trades/day.       |
//|  Exposed here so you can find out if any lever combo changes    |
//|  that story — or confirms it.                                   |
//|                                                                  |
//|  Logic:                                                          |
//|   - Flat? Measure displacement over the last InpLookbackMin      |
//|     minutes. If |displacement| >= InpTriggerPips, enter in that  |
//|     direction (rookie reads momentum at face value).             |
//|   - Initial SL = InpSL pips.                                     |
//|   - Once price is InpArmAtPips in profit, move SL to lock in     |
//|     InpLockPips of profit ("protect the first few pips").       |
//|   - TP = InpTP pips.                                             |
//|   - If InpUseTimeLimit, force-close after InpTimeLimitMin        |
//|     minutes regardless of P&L.                                   |
//|   - One trade at a time. No pyramiding, no revenge sizing.       |
//+------------------------------------------------------------------+
#property copyright "Monkey v2.0"
#property version   "1.00"

#include <Trade\Trade.mqh>
CTrade trade;

//--- Inputs --------------------------------------------------------
input group "=== Session (broker time) ==="
input int    InpStartHour      = 7;     // Session start hour
input int    InpEndHour        = 16;    // Session end hour (exclusive)

input group "=== Going Up / Going Down Trigger ==="
input int    InpLookbackMin    = 5;     // Minutes to measure displacement over
input double InpTriggerPips    = 5.0;   // Pips of displacement to call it "going X"

input group "=== Money Management ==="
input double InpSL             = 7.0;   // Initial stop loss (pips)
input double InpArmAtPips      = 3.0;   // Profit level that arms the protective stop
input double InpLockPips       = 1.0;   // Stop moves to lock THIS many pips once armed (this is the "TTP")
input double InpTP             = 7.0;   // Take profit (pips)
input bool   InpUseTimeLimit   = true;  // If false, no time limit — only SL/TP decide the exit
input int    InpTimeLimitMin   = 15;    // Max minutes in trade (ignored if InpUseTimeLimit=false)

input group "=== Risk ==="
input double InpRiskPct        = 0.25;  // Risk % per trade (sized off InpSL)
input int    InpCooldownSecs   = 5;     // Min seconds after a close before re-arming

//--- Globals -------------------------------------------------------
double   pip;
datetime lastCloseTime = 0;

double   tickMids[];
datetime tickTimes[];
int      tickBufN = 0;
int      tickBufMax = 20000;

bool     armed     = false;   // has the protective-lock stop been applied?
datetime entryTime = 0;
long     posType   = -1;

//+------------------------------------------------------------------+
int OnInit()
  {
   pip = (StringFind(Symbol(),"JPY") >= 0) ? 0.01 : 0.0001;
   trade.SetExpertMagicNumber(20260102);
   ArrayResize(tickMids,  tickBufMax);
   ArrayResize(tickTimes, tickBufMax);
   if(MQLInfoInteger(MQL_TESTER))
      Print("Monkey v2.0 — running in TESTER. Displacement trigger is bar/tick based ",
            "and should behave consistently here, unlike Rainmaker. Still: validate on demo too.");
   else
      Print("Monkey v2.0 ready. Reminder: this logic tested net NEGATIVE in research. ",
            "It's here for lever experimentation, not because it's proven.");
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

   if(HasPosition())
     {
      ManagePosition(tk, now);
      return;
     }

   if(!SessionOK()) return;
   if(now - lastCloseTime < InpCooldownSecs) return;

   double disp = Displacement(now);
   if(MathAbs(disp) >= InpTriggerPips)
     {
      int dir = (disp > 0) ? 1 : -1;
      EnterMarket(dir);
     }
  }

//+------------------------------------------------------------------+
void UpdateTickBuffer(double mid, datetime now)
  {
   int idx = tickBufN % tickBufMax;
   tickMids[idx]  = mid;
   tickTimes[idx] = now;
   tickBufN++;
  }

//+------------------------------------------------------------------+
//| Displacement over the last InpLookbackMin minutes, in pips        |
//+------------------------------------------------------------------+
double Displacement(datetime now)
  {
   int total = MathMin(tickBufN, tickBufMax);
   if(total < 5) return 0.0;

   datetime cutoff = now - InpLookbackMin * 60;
   double curMid = tickMids[(tickBufN - 1) % tickBufMax];
   double pastMid = curMid;
   bool   found = false;

   for(int i = 0; i < total; i++)
     {
      int idx = (tickBufN - 1 - i) % tickBufMax;
      if(idx < 0) idx += tickBufMax;
      if(tickTimes[idx] <= cutoff)
        {
         pastMid = tickMids[idx];
         found = true;
         break;
        }
     }
   if(!found) return 0.0;   // not enough history yet

   return (curMid - pastMid) / pip;
  }

//+------------------------------------------------------------------+
//| LAYER 1 of protection: attach SL/TP ATOMICALLY in the same        |
//| order-send the broker processes, not as a follow-up call that     |
//| can silently fail. If the broker still rejects it (e.g. price     |
//| moved, requote), we retry via PositionModify and VERIFY the       |
//| result — if it still fails, we close the naked position           |
//| immediately rather than letting it ride unprotected.              |
//+------------------------------------------------------------------+
void EnterMarket(int dir)
  {
   double lots = CalcLots(InpSL);
   double price = (dir > 0) ? SymbolInfoDouble(Symbol(), SYMBOL_ASK)
                             : SymbolInfoDouble(Symbol(), SYMBOL_BID);
   double slPrice = (dir > 0) ? price - InpSL*pip : price + InpSL*pip;
   double tpPrice = (dir > 0) ? price + InpTP*pip : price - InpTP*pip;

   bool ok;
   if(dir > 0) ok = trade.Buy (lots, Symbol(), 0.0, slPrice, tpPrice, "Monkey LONG");
   else        ok = trade.Sell(lots, Symbol(), 0.0, slPrice, tpPrice, "Monkey SHORT");

   if(!ok)
     {
      Print("Entry failed: ", trade.ResultRetcode(), " ", trade.ResultRetcodeDescription());
      return;
     }

   Sleep(10);
   if(!PositionSelect(Symbol()))
     {
      Print("Monkey: entry reported OK but no position found — aborting management");
      return;
     }

   double op = PositionGetDouble(POSITION_PRICE_OPEN);
   posType   = PositionGetInteger(POSITION_TYPE);
   entryTime = TimeCurrent();
   armed     = false;

   // Verify the SL actually attached. If the broker silently dropped it
   // (e.g. requote, min-stop-distance), retry once via PositionModify and
   // VERIFY that too. If protection still isn't on, close immediately —
   // never let a position sit naked.
   double curSL = PositionGetDouble(POSITION_SL);
   if(curSL == 0.0)
     {
      double retrySL = (posType == POSITION_TYPE_BUY) ? op - InpSL*pip : op + InpSL*pip;
      double retryTP = (posType == POSITION_TYPE_BUY) ? op + InpTP*pip : op - InpTP*pip;
      bool modOk = trade.PositionModify(Symbol(), retrySL, retryTP);
      Sleep(10);
      PositionSelect(Symbol());
      if(!modOk || PositionGetDouble(POSITION_SL) == 0.0)
        {
         Print("Monkey: SL FAILED TO ATTACH after retry — closing naked position immediately");
         trade.PositionClose(Symbol());
         lastCloseTime = TimeCurrent();
         posType = -1;
         return;
        }
     }

   Print("Monkey ENTER ", (dir>0?"LONG":"SHORT"), " lots:", lots,
         " | SL:", PositionGetDouble(POSITION_SL), " TP:", PositionGetDouble(POSITION_TP),
         " disp-triggered");
  }

//+------------------------------------------------------------------+
//| Manage: arm the protective stop once InpArmAtPips reached;        |
//| enforce time limit if enabled. TP/initial SL are native broker    |
//| orders so they work even if the EA hiccups.                       |
//+------------------------------------------------------------------+
void ManagePosition(MqlTick &tk, datetime now)
  {
   if(!PositionSelect(Symbol())) { posType = -1; armed = false; return; }

   double open = PositionGetDouble(POSITION_PRICE_OPEN);

   // LAYER 2 of protection: manual backstop, independent of whatever the
   // broker-side SL is doing. If floating loss ever exceeds InpSL by more
   // than a small margin (catches a stripped/failed broker stop, gap, or
   // sync issue), close immediately. This should never fire if Layer 1
   // (atomic SL at entry) is working — it exists for when it doesn't.
   double backstopPips;
   if(posType == POSITION_TYPE_BUY) backstopPips = (open - tk.bid)/pip;
   else                              backstopPips = (tk.ask - open)/pip;
   if(backstopPips >= InpSL * 1.5)
     {
      Print("Monkey: BACKSTOP triggered — floating loss ", backstopPips,
            " pips exceeds 1.5x intended SL (", InpSL, "). Broker-side stop may have failed. Closing.");
      trade.PositionClose(Symbol());
      lastCloseTime = TimeCurrent();
      posType = -1; armed = false;
      return;
     }

   if(!armed)
     {
      double profitPips;
      if(posType == POSITION_TYPE_BUY) profitPips = (tk.bid - open)/pip;
      else                              profitPips = (open - tk.ask)/pip;

      if(profitPips >= InpArmAtPips)
        {
         double lockPrice = (posType == POSITION_TYPE_BUY) ? open + InpLockPips*pip
                                                             : open - InpLockPips*pip;
         double curTP = PositionGetDouble(POSITION_TP);
         if(trade.PositionModify(Symbol(), lockPrice, curTP))
           {
            armed = true;
            Print("Monkey ARMED — stop locked at +", InpLockPips, " pips");
           }
        }
     }

   if(InpUseTimeLimit && (now - entryTime > InpTimeLimitMin * 60))
     {
      trade.PositionClose(Symbol());
      Print("Monkey CLOSE (time limit)");
      lastCloseTime = TimeCurrent();
      posType = -1; armed = false;
     }
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
         long   entry  = HistoryDealGetInteger(trans.deal, DEAL_ENTRY);
         if(entry == DEAL_ENTRY_OUT)
           {
            lastCloseTime = TimeCurrent();
            posType = -1; armed = false;
            Print("Monkey Deal closed | Profit: ", profit);
           }
        }
  }

//+------------------------------------------------------------------+
bool HasPosition()
  {
   return (PositionSelect(Symbol()) &&
           PositionGetInteger(POSITION_MAGIC) == 20260102);
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
