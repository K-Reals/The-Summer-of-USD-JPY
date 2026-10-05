//+------------------------------------------------------------------+
//| Postman_v1_0.mq5                                                  |
//| Two-Burst tick pattern scalper                                    |
//| Session: 09:00-14:00 UTC, Tue-Thu only                           |
//| SL=0.8, Trail@60s, Dist=0.5, MaxHold=180s                       |
//+------------------------------------------------------------------+
#property copyright "Research"
#property version   "1.00"

input group "=== Session Filter ==="
input int      InpSessionStart    = 9;
input int      InpSessionEnd      = 14;
input bool     InpTueThuOnly      = true;

input group "=== Signal Parameters ==="
input int      InpSilenceN        = 12;
input double   InpSilenceGapMs    = 250.0;
input int      InpBurst1N         = 3;
input double   InpBurst1GapMs     = 104.0;
input double   InpBurst1Vert      = 0.80;
input int      InpPauseN          = 3;
input double   InpPauseGapMs      = 200.0;
input double   InpPauseMaxPips    = 0.3;
input int      InpBurst2N         = 3;
input double   InpBurst2MultMax   = 1.2;
input double   InpBurst2Vert      = 0.75;
input int      InpRefracTicks     = 50;

input group "=== Risk & Exit ==="
input double   InpRiskPct         = 0.5;
input double   InpSLPips          = 0.8;
input double   InpTrailActivate   = 60.0;
input double   InpTrailPips       = 0.5;
input double   InpMaxHoldSecs     = 180.0;
input double   InpSoftStopMult    = 1.5;

//--- Globals
double g_pip;
double g_point;

#define BUF 200
long   g_ms[BUF];
double g_mid[BUF];
int    g_count  = 0;
int    g_head   = 0;
int    g_last   = -100;

ulong    g_ticket      = 0;
datetime g_entry_time  = 0;
double   g_highest_mfe = 0;
bool     g_trail_active= false;
int      g_trade_dir   = 0;

//+------------------------------------------------------------------+
int OnInit()
{
   g_point = SymbolInfoDouble(Symbol(), SYMBOL_POINT);
   g_pip   = g_point * 10;
   if(g_pip <= 0) { Print("ERROR: Invalid pip"); return INIT_FAILED; }
   Print("Postman v1.0 started. pip=", g_pip, " symbol=", Symbol());
   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   Print("Postman stopped. Ticks=", g_count);
}

//+------------------------------------------------------------------+
void AddTick(long ms, double mid)
{
   g_head = (g_head + 1) % BUF;
   g_ms[g_head]  = ms;
   g_mid[g_head] = mid;
   g_count++;
}

//+------------------------------------------------------------------+
bool GetTk(int age, long &ms, double &mid)
{
   if(age >= BUF || age >= g_count) return false;
   int idx = ((g_head - age) % BUF + BUF) % BUF;
   ms  = g_ms[idx];
   mid = g_mid[idx];
   return true;
}

//+------------------------------------------------------------------+
bool Window(int start, int n, double &gap, double &vert, int &dir)
{
   if(g_count < start + n + 1) return false;
   double tg = 0;
   int up = 0, dn = 0;
   long t0 = 0, t1 = 0;
   double p0 = 0, p1 = 0;
   for(int i = start; i < start + n; i++)
   {
      if(!GetTk(i,   t1, p1)) return false;
      if(!GetTk(i+1, t0, p0)) return false;
      tg += (double)(t1 - t0);
      double d = p1 - p0;
      if(d > 0) up++;
      else if(d < 0) dn++;
   }
   gap  = tg / n;
   int dom = MathMax(up, dn);
   int tot = up + dn;
   vert = (tot > 0) ? (double)dom / tot : 0;
   dir  = (up >= dn) ? 1 : -1;
   return true;
}

//+------------------------------------------------------------------+
bool Detect(int &sdir)
{
   double gap, vert;
   int dir;

   // Burst2 — most recent
   if(!Window(0, InpBurst2N, gap, vert, dir)) return false;
   if(vert < InpBurst2Vert) return false;
   int b2dir = dir;
   double b2gap = gap;

   // Pause
   if(!Window(InpBurst2N, InpPauseN, gap, vert, dir)) return false;
   if(gap < InpPauseGapMs) return false;
   long t; double pe, ps;
   GetTk(InpBurst2N, t, pe);
   GetTk(InpBurst2N + InpPauseN, t, ps);
   if(MathAbs(pe - ps) / g_pip > InpPauseMaxPips) return false;

   // Burst1
   int b1s = InpBurst2N + InpPauseN;
   if(!Window(b1s, InpBurst1N, gap, vert, dir)) return false;
   if(gap > InpBurst1GapMs || vert < InpBurst1Vert) return false;
   if(dir != b2dir) return false;
   double b1gap = gap;

   // Burst2 speed check
   if(b1gap > 0 && b2gap > b1gap * InpBurst2MultMax) return false;

   // Silence
   int ss = InpBurst2N + InpPauseN + InpBurst1N;
   if(!Window(ss, InpSilenceN, gap, vert, dir)) return false;
   if(gap < InpSilenceGapMs) return false;

   sdir = b2dir;
   return true;
}

//+------------------------------------------------------------------+
bool InSession()
{
   MqlDateTime dt;
   TimeToStruct(TimeGMT(), dt);
   if(dt.hour < InpSessionStart || dt.hour >= InpSessionEnd) return false;
   if(InpTueThuOnly && (dt.day_of_week < 2 || dt.day_of_week > 4)) return false;
   return true;
}

//+------------------------------------------------------------------+
double CalcLots()
{
   double bal  = AccountInfoDouble(ACCOUNT_BALANCE);
   double risk = bal * InpRiskPct / 100.0;
   double tv   = SymbolInfoDouble(Symbol(), SYMBOL_TRADE_TICK_VALUE);
   double ts   = SymbolInfoDouble(Symbol(), SYMBOL_TRADE_TICK_SIZE);
   double pv   = tv * g_pip / ts;
   if(pv <= 0) return 0;
   double lots = risk / (InpSLPips * pv);
   double step = SymbolInfoDouble(Symbol(), SYMBOL_VOLUME_STEP);
   double mn   = SymbolInfoDouble(Symbol(), SYMBOL_VOLUME_MIN);
   double mx   = SymbolInfoDouble(Symbol(), SYMBOL_VOLUME_MAX);
   lots = MathFloor(lots / step) * step;
   return MathMax(mn, MathMin(mx, lots));
}

//+------------------------------------------------------------------+
void ClosePosition(ulong ticket = 0);

bool OpenTrade(int direction)
{
   double lots = CalcLots();
   if(lots <= 0) { Print("ERROR: lot size"); return false; }

   double ask = SymbolInfoDouble(Symbol(), SYMBOL_ASK);
   double bid = SymbolInfoDouble(Symbol(), SYMBOL_BID);

   MqlTradeRequest req = {};
   MqlTradeResult  res = {};
   req.action    = TRADE_ACTION_DEAL;
   req.symbol    = Symbol();
   req.volume    = lots;
   req.deviation = 10;
   req.magic     = 20260707;
   req.comment   = "Postman_v1";

   if(direction == 1)
   {
      req.type  = ORDER_TYPE_BUY;
      req.price = ask;
      req.sl    = NormalizeDouble(ask - InpSLPips * g_pip, _Digits);
      req.tp    = NormalizeDouble(ask + 20.0 * g_pip, _Digits);
   }
   else
   {
      req.type  = ORDER_TYPE_SELL;
      req.price = bid;
      req.sl    = NormalizeDouble(bid + InpSLPips * g_pip, _Digits);
      req.tp    = NormalizeDouble(bid - 20.0 * g_pip, _Digits);
   }

   if(!OrderSend(req, res))
   {
      Print("OpenTrade failed: ", res.retcode, " ", res.comment);
      return false;
   }

   // Verify SL attached
   Sleep(100);
   if(!PositionSelectByTicket(res.order))
   {
      Print("ERROR: Position not found after open");
      return false;
   }
   if(PositionGetDouble(POSITION_SL) == 0)
   {
      Print("ERROR: SL not attached - closing immediately");
      ClosePosition(res.order);
      return false;
   }

   g_ticket       = res.order;
   g_entry_time   = TimeCurrent();
   g_highest_mfe  = 0;
   g_trail_active = false;
   g_trade_dir    = direction;

   Print("Trade opened: ", direction==1?"BUY":"SELL",
         " lots=", lots, " price=", req.price,
         " sl=", req.sl);
   return true;
}

//+------------------------------------------------------------------+
void ModifySL(double new_sl)
{
   MqlTradeRequest req = {};
   MqlTradeResult  res = {};
   req.action   = TRADE_ACTION_SLTP;
   req.symbol   = Symbol();
   req.position = g_ticket;
   req.sl       = NormalizeDouble(new_sl, _Digits);
   req.tp       = PositionGetDouble(POSITION_TP);
   if(!OrderSend(req, res))
      Print("ModifySL failed: ", res.retcode);
}

//+------------------------------------------------------------------+
void ClosePosition(ulong ticket = 0)
{
   ulong tkt = (ticket > 0) ? ticket : g_ticket;
   if(!PositionSelectByTicket(tkt)) { g_ticket=0; return; }

   MqlTradeRequest req = {};
   MqlTradeResult  res = {};
   req.action    = TRADE_ACTION_DEAL;
   req.symbol    = Symbol();
   req.position  = tkt;
   req.volume    = PositionGetDouble(POSITION_VOLUME);
   req.deviation = 10;
   req.type      = (PositionGetInteger(POSITION_TYPE)==POSITION_TYPE_BUY) ?
                    ORDER_TYPE_SELL : ORDER_TYPE_BUY;
   req.price     = (req.type==ORDER_TYPE_SELL) ?
                    SymbolInfoDouble(Symbol(),SYMBOL_BID) :
                    SymbolInfoDouble(Symbol(),SYMBOL_ASK);

   if(!OrderSend(req, res))
      Print("ClosePosition failed: ", res.retcode);
   else
   {
      Print("Position closed. Ticket=", tkt);
      g_ticket = 0;
   }
}

//+------------------------------------------------------------------+
void ManagePosition()
{
   if(!PositionSelectByTicket(g_ticket)) { g_ticket=0; return; }

   double cur    = PositionGetDouble(POSITION_PRICE_CURRENT);
   double entry  = PositionGetDouble(POSITION_PRICE_OPEN);
   int    type   = (int)PositionGetInteger(POSITION_TYPE);
   double cur_sl = PositionGetDouble(POSITION_SL);

   double mfe = (type==POSITION_TYPE_BUY) ?
                (cur-entry)/g_pip : (entry-cur)/g_pip;
   g_highest_mfe = MathMax(g_highest_mfe, mfe);

   double secs = (double)(TimeCurrent() - g_entry_time);

   // Software backstop
   if(mfe <= -(InpSLPips * InpSoftStopMult))
   {
      Print("Software backstop at ", mfe, " pips");
      ClosePosition();
      return;
   }

   // Max hold
   if(secs >= InpMaxHoldSecs)
   {
      Print("Max hold reached");
      ClosePosition();
      return;
   }

   // Activate trail
   if(secs >= InpTrailActivate)
      g_trail_active = true;

   // Update trail
   if(g_trail_active && g_highest_mfe > InpTrailPips)
   {
      double trail_level = g_highest_mfe - InpTrailPips;
      double new_sl;

      if(type == POSITION_TYPE_BUY)
      {
         new_sl = NormalizeDouble(entry + trail_level * g_pip, _Digits);
         if(new_sl > cur_sl + g_point)
            ModifySL(new_sl);
      }
      else
      {
         new_sl = NormalizeDouble(entry - trail_level * g_pip, _Digits);
         if(new_sl < cur_sl - g_point)
            ModifySL(new_sl);
      }
   }
}

//+------------------------------------------------------------------+
void OnTick()
{
   MqlTick tick;
   if(!SymbolInfoTick(Symbol(), tick)) return;

   double mid = (tick.bid + tick.ask) / 2.0;
   AddTick(tick.time_msc, mid);

   // Manage open position first
   if(g_ticket > 0)
   {
      ManagePosition();
      return;
   }

   // Session filter
   if(!InSession()) return;

   // Refractory
   if(g_count - g_last < InpRefracTicks) return;

   // Detect pattern
   int sdir;
   if(Detect(sdir))
   {
      Print("SIGNAL: ", sdir==1?"BUY":"SELL", " at ", TimeToString(TimeCurrent()));
      if(OpenTrade(sdir))
         g_last = g_count;
   }
}
