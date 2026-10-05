//+------------------------------------------------------------------+
//| Reverso_v1_0.mq5                                                  |
//| M1 spike reversion EA                                             |
//| Signal: M1 bar range >= 2.5x avg of prior 20 bars -> bet reversal|
//| Exit: TP = 0.5x spike range, SL = 0.3x spike range               |
//+------------------------------------------------------------------+
#property copyright "Research"
#property version   "1.00"

input group "=== Signal ==="
input int      InpLookback        = 20;     // bars for average range
input double   InpSpikeThreshold  = 2.5;    // spike range / avg range
input int      InpSessionStart    = 7;      // hour UTC
input int      InpSessionEnd      = 16;     // hour UTC

input group "=== Exit ==="
input double   InpTPFrac          = 0.50;   // TP as fraction of spike range
input double   InpSLFrac          = 0.30;   // SL as fraction of spike range
input int      InpMaxHoldSec      = 900;    // 15 min

input group "=== Risk ==="
input double   InpRiskPct         = 0.25;

double   g_pip, g_point;
datetime g_last_bar_time = 0;
ulong    g_ticket = 0;
datetime g_entry_time = 0;

int OnInit()
{
   g_point = SymbolInfoDouble(Symbol(), SYMBOL_POINT);
   g_pip   = g_point * 10;
   Print("Reverso v1.0 started. pip=", g_pip);
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason) { Print("Reverso stopped."); }

bool InSession()
{
   MqlDateTime dt;
   TimeToStruct(TimeGMT(), dt);
   if(dt.hour < InpSessionStart || dt.hour >= InpSessionEnd) return false;
   if(dt.day_of_week == 0 || dt.day_of_week == 6) return false;
   return true;
}

double CalcLots(double sl_pips)
{
   double bal  = AccountInfoDouble(ACCOUNT_BALANCE);
   double risk = bal * InpRiskPct / 100.0;
   double tv   = SymbolInfoDouble(Symbol(), SYMBOL_TRADE_TICK_VALUE);
   double ts   = SymbolInfoDouble(Symbol(), SYMBOL_TRADE_TICK_SIZE);
   double pv   = tv * g_pip / ts;
   if(pv <= 0 || sl_pips <= 0) return 0;
   double lots = risk / (sl_pips * pv);
   double step = SymbolInfoDouble(Symbol(), SYMBOL_VOLUME_STEP);
   double mn   = SymbolInfoDouble(Symbol(), SYMBOL_VOLUME_MIN);
   double mx   = SymbolInfoDouble(Symbol(), SYMBOL_VOLUME_MAX);
   lots = MathFloor(lots / step) * step;
   lots = MathMax(mn, MathMin(mx, lots));

   double margin_req = 0;
   if(OrderCalcMargin(ORDER_TYPE_BUY, Symbol(), lots,
                      SymbolInfoDouble(Symbol(), SYMBOL_ASK), margin_req))
   {
      double fm = AccountInfoDouble(ACCOUNT_MARGIN_FREE);
      if(margin_req > fm * 0.90 && margin_req > 0)
      {
         lots = MathFloor((fm * 0.90 / margin_req) * lots / step) * step;
         if(lots < mn) return 0;
      }
   }
   return lots;
}

bool CheckStopsOK(double sl_price, double tp_price, double ref_price, bool is_buy)
{
   long stops_level = SymbolInfoInteger(Symbol(), SYMBOL_TRADE_STOPS_LEVEL);
   double min_dist = stops_level * g_point;
   double sl_dist = is_buy ? (ref_price - sl_price) : (sl_price - ref_price);
   double tp_dist = is_buy ? (tp_price - ref_price) : (ref_price - tp_price);
   if(sl_dist < min_dist || tp_dist < min_dist)
   {
      Print("Stops too tight: sl_dist=", sl_dist, " tp_dist=", tp_dist,
            " min_required=", min_dist);
      return false;
   }
   return true;
}

void OpenTrade(int direction, double spike_range_pips)
{
   double tp_pips = spike_range_pips * InpTPFrac;
   double sl_pips = spike_range_pips * InpSLFrac;

   double ask = SymbolInfoDouble(Symbol(), SYMBOL_ASK);
   double bid = SymbolInfoDouble(Symbol(), SYMBOL_BID);

   double lots = CalcLots(sl_pips);
   if(lots <= 0) { Print("Skip: lot size 0"); return; }

   MqlTradeRequest req = {};
   MqlTradeResult  res = {};
   req.action    = TRADE_ACTION_DEAL;
   req.symbol    = Symbol();
   req.volume    = lots;
   req.deviation = 10;
   req.magic     = 20260717;
   req.comment   = "Reverso";

   double sl_price, tp_price, ref_price;
   if(direction == 1)
   {
      req.type  = ORDER_TYPE_BUY;
      req.price = ask;
      ref_price = ask;
      sl_price  = ask - sl_pips * g_pip;
      tp_price  = ask + tp_pips * g_pip;
   }
   else
   {
      req.type  = ORDER_TYPE_SELL;
      req.price = bid;
      ref_price = bid;
      sl_price  = bid + sl_pips * g_pip;
      tp_price  = bid - tp_pips * g_pip;
   }

   if(!CheckStopsOK(sl_price, tp_price, ref_price, direction==1))
      return; // would fail as Invalid Stops anyway -- skip cleanly, no wasted attempt

   req.sl = NormalizeDouble(sl_price, _Digits);
   req.tp = NormalizeDouble(tp_price, _Digits);

   if(!OrderSend(req, res))
   {
      Print("OpenTrade failed: ", res.retcode, " ", res.comment);
      return;
   }

   g_ticket     = res.order;
   g_entry_time = TimeCurrent();
   Print("ENTER ", direction==1?"BUY":"SELL",
         " lots=", lots, " tp=", tp_pips, "p sl=", sl_pips, "p",
         " spike_range=", spike_range_pips, "p");
}

void ManagePosition()
{
   if(!PositionSelectByTicket(g_ticket)) { g_ticket = 0; return; }
   double secs = (double)(TimeCurrent() - g_entry_time);
   if(secs >= InpMaxHoldSec)
   {
      MqlTradeRequest req = {};
      MqlTradeResult  res = {};
      req.action    = TRADE_ACTION_DEAL;
      req.symbol    = Symbol();
      req.position  = g_ticket;
      req.volume    = PositionGetDouble(POSITION_VOLUME);
      req.deviation = 10;
      req.type      = (PositionGetInteger(POSITION_TYPE)==POSITION_TYPE_BUY) ?
                       ORDER_TYPE_SELL : ORDER_TYPE_BUY;
      req.price     = (req.type==ORDER_TYPE_SELL) ?
                       SymbolInfoDouble(Symbol(),SYMBOL_BID) :
                       SymbolInfoDouble(Symbol(),SYMBOL_ASK);
      if(OrderSend(req, res)) Print("Closed on max hold time");
   }
   // TP/SL themselves are enforced by the broker server-side via req.sl/req.tp
   // set at entry -- they work even between our own OnTick checks.
}

void OnTick()
{
   if(g_ticket > 0) { ManagePosition(); return; }

   // detect a new M1 bar starting == the previous bar just closed
   datetime cur_bar_time = iTime(Symbol(), PERIOD_M1, 0);
   if(cur_bar_time == g_last_bar_time) return;
   g_last_bar_time = cur_bar_time;

   if(!InSession()) return;

   // index 1 = the bar that JUST closed (index 0 is the new, still-forming bar)
   double o1 = iOpen(Symbol(), PERIOD_M1, 1);
   double c1 = iClose(Symbol(), PERIOD_M1, 1);
   double h1 = iHigh(Symbol(), PERIOD_M1, 1);
   double l1 = iLow(Symbol(), PERIOD_M1, 1);
   double range1_pips = (h1 - l1) / g_pip;
   if(c1 == o1) return;

   // average range of the prior 20 bars (indices 2..21) -- excludes the
   // spike bar itself, matching the Python .rolling(20).mean().shift(1)
   double sum_range = 0;
   for(int i = 2; i <= InpLookback + 1; i++)
   {
      double hi = iHigh(Symbol(), PERIOD_M1, i);
      double lo = iLow(Symbol(), PERIOD_M1, i);
      sum_range += (hi - lo) / g_pip;
   }
   double avg_range = sum_range / InpLookback;
   if(avg_range <= 0) return;

   double spike_ratio = range1_pips / avg_range;
   if(spike_ratio < InpSpikeThreshold) return;

   int spike_dir = (c1 > o1) ? 1 : -1;
   int trade_dir = -spike_dir;  // REVERSION

   Print("SPIKE ratio=", spike_ratio, " range=", range1_pips,
         "p dir=", spike_dir==1?"UP":"DOWN", " -> ",
         trade_dir==1?"BUY":"SELL");

   OpenTrade(trade_dir, range1_pips);
}
