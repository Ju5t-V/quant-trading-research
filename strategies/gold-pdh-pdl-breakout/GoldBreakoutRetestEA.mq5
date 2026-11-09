//+------------------------------------------------------------------+
//|                                       GoldBreakoutRetestEA.mq5   |
//|  Previous-day breakout WITH a retest confirmation (XAUUSD)       |
//|                                                                  |
//|  Difference vs the plain breakout EA: it does NOT buy the moment |
//|  price crosses yesterday's high. It waits for a 3-step sequence  |
//|  on the signal timeframe (default M15), so a fake spike that     |
//|  immediately reverses never triggers a trade:                    |
//|                                                                  |
//|   LONG setup (mirror for SHORT at the previous-day low):         |
//|    1. BREAK   - a bar CLOSES above prev-day high by >0.1*ATR      |
//|    2. RETEST  - a later bar dips back to within 0.25*ATR of the   |
//|                 high BUT still CLOSES above it (level holds)      |
//|    3. ENTER   - market buy on that confirming bar                 |
//|    FAIL       - if a bar closes 0.5*ATR back below the high, the  |
//|                 setup is cancelled (the breakout was fake)        |
//|    TIMEOUT    - if no retest within InpRetestBars, cancel         |
//|                                                                  |
//|  Stop sits just beyond the reclaimed level (tight, logical).     |
//|  Then the same aggressive ATR trailing stop as the original EA.  |
//|  One long + one short setup per day (up to 2 trades/day).        |
//|                                                                  |
//|  Risk framework (from the validated gold EA): 2% auto-sizing via |
//|  OrderCalcProfit + free-margin cap, recovery mode (1/10 size     |
//|  while last N trades net negative), restart-safe, info panel.    |
//+------------------------------------------------------------------+
#property copyright   "Jerry"
#property version     "1.00"
#property description "Prev-day breakout that waits for a retest of the level before entering (anti-fakeout)."

#include <Trade\Trade.mqh>

input int             InpEntryHour       = 6;            // Start watching after this server hour
input ENUM_TIMEFRAMES InpSignalTF        = PERIOD_M15;   // Timeframe for break/retest bars
input int             InpAtrPeriod       = 14;           // ATR period (signal TF)
input double          InpBreakoutATR     = 0.10;         // Break confirmed: close beyond level by > this x ATR
input double          InpRetestATR       = 0.25;         // Retest zone: bar wick returns within this x ATR of level
input double          InpFailATR         = 0.50;         // Fail: bar closes this x ATR back through the level
input double          InpStopBufferATR   = 0.50;         // Stop distance beyond the level (x ATR)
input double          InpTpATR           = 6.0;          // Take profit (x ATR from entry; 0 = none)
input int             InpRetestBars      = 8;            // Cancel setup if no retest within this many bars
input double          InpTrailStartATR   = 1.0;          // Start trailing after this much profit (x ATR)
input double          InpTrailDistATR    = 0.7;          // Trailing distance behind price (x ATR)
input double          InpRiskPercent     = 2.0;          // Risk % of balance per trade
input bool            InpRecoveryMode    = true;         // 1/10 size while last N trades net negative
input int             InpRecentTrades    = 10;           // N recent trades for recovery mode
input bool            InpShowPanel       = true;         // Show info panel
input ulong           InpMagicNumber     = 20260715;     // Magic Number

enum SideState { ST_WAIT_BREAK = 0, ST_WAIT_RETEST = 1, ST_DONE = 2 };

CTrade   trade;
int      g_atr = INVALID_HANDLE;
datetime g_day = 0, g_lastSig = 0;
double   g_pdh = 0.0, g_pdl = 0.0;
SideState g_long = ST_WAIT_BREAK, g_short = ST_WAIT_BREAK;
datetime g_longBreak = 0, g_shortBreak = 0;

//+------------------------------------------------------------------+
int OnInit()
{
   trade.SetExpertMagicNumber(InpMagicNumber);
   trade.SetTypeFillingBySymbol(_Symbol);
   trade.SetDeviationInPoints(30);
   g_atr = iATR(_Symbol, InpSignalTF, InpAtrPeriod);
   if(g_atr == INVALID_HANDLE)
      return(INIT_FAILED);
   return(INIT_SUCCEEDED);
}

void OnDeinit(const int reason) { ObjectsDeleteAll(0, "GBR_"); }

//+------------------------------------------------------------------+
void OnTick()
{
   datetime day = iTime(_Symbol, PERIOD_D1, 0);
   if(day == 0)
      return;

   // ---- new day: reset both setups (or lock them if we already traded) ----
   if(day != g_day)
   {
      g_day = day;
      g_pdh = iHigh(_Symbol, PERIOD_D1, 1);
      g_pdl = iLow(_Symbol, PERIOD_D1, 1);
      if(TradedToday(day))
      {
         g_long = ST_DONE; g_short = ST_DONE;   // restart safety
      }
      else
      {
         g_long = ST_WAIT_BREAK; g_short = ST_WAIT_BREAK;
      }
      g_longBreak = 0; g_shortBreak = 0;
   }

   // ---- evaluate the state machine once per closed signal bar ----
   datetime sig = iTime(_Symbol, InpSignalTF, 0);
   if(sig != g_lastSig)
   {
      g_lastSig = sig;
      EvaluateSetups();
   }

   ManageTrailing();

   static datetime lastPanel = 0;
   if(InpShowPanel && TimeCurrent() - lastPanel >= 2)
   {
      lastPanel = TimeCurrent();
      UpdatePanel();
   }
}

//+------------------------------------------------------------------+
//| Break -> retest -> enter, evaluated on the last CLOSED signal bar|
//+------------------------------------------------------------------+
void EvaluateSetups()
{
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   if(dt.hour < InpEntryHour)
      return;                       // skip the thin pre-session hours
   if(g_pdh <= 0.0 || g_pdl <= 0.0)
      return;

   double a[1];
   if(CopyBuffer(g_atr, 0, 1, 1, a) != 1 || a[0] <= 0.0)
      return;
   double atr = a[0];

   double c = iClose(_Symbol, InpSignalTF, 1);
   double h = iHigh(_Symbol, InpSignalTF, 1);
   double l = iLow(_Symbol, InpSignalTF, 1);
   datetime bt = iTime(_Symbol, InpSignalTF, 1);
   if(c <= 0.0)
      return;

   // -------- LONG side (previous-day high) --------
   if(g_long == ST_WAIT_BREAK)
   {
      if(c >= g_pdh + InpBreakoutATR * atr)
      {
         g_long = ST_WAIT_RETEST;
         g_longBreak = bt;
      }
   }
   else if(g_long == ST_WAIT_RETEST)
   {
      if(c <= g_pdh - InpFailATR * atr)                         // breakout failed
         g_long = ST_DONE;
      else if(l <= g_pdh + InpRetestATR * atr && c > g_pdh)     // retest held -> ENTER
      {
         if(Enter(1, atr))
            g_long = ST_DONE;
      }
      else if(BarsSince(g_longBreak) > InpRetestBars)           // no retest in time
         g_long = ST_DONE;
   }

   // -------- SHORT side (previous-day low) --------
   if(g_short == ST_WAIT_BREAK)
   {
      if(c <= g_pdl - InpBreakoutATR * atr)
      {
         g_short = ST_WAIT_RETEST;
         g_shortBreak = bt;
      }
   }
   else if(g_short == ST_WAIT_RETEST)
   {
      if(c >= g_pdl + InpFailATR * atr)
         g_short = ST_DONE;
      else if(h >= g_pdl - InpRetestATR * atr && c < g_pdl)
      {
         if(Enter(-1, atr))
            g_short = ST_DONE;
      }
      else if(BarsSince(g_shortBreak) > InpRetestBars)
         g_short = ST_DONE;
   }
}

//+------------------------------------------------------------------+
int BarsSince(datetime barTime)
{
   if(barTime == 0)
      return(0);
   int s = iBarShift(_Symbol, InpSignalTF, barTime, false);
   return(s < 0 ? 0 : s);
}

//+------------------------------------------------------------------+
bool Enter(int dir, double atr)
{
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double price = (dir > 0) ? ask : bid;
   double minDist = (double)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL) * _Point;

   double sl = (dir > 0) ? g_pdh - InpStopBufferATR * atr
                         : g_pdl + InpStopBufferATR * atr;
   if(dir > 0) { double maxSl = price - MathMax(minDist, _Point); if(sl > maxSl) sl = maxSl; }
   else        { double minSl = price + MathMax(minDist, _Point); if(sl < minSl) sl = minSl; }
   sl = NormalizeDouble(sl, _Digits);

   double tp = 0.0;
   if(InpTpATR > 0.0)
      tp = NormalizeDouble((dir > 0) ? price + InpTpATR * atr : price - InpTpATR * atr, _Digits);

   double lots = CalcLots(price, sl, dir);
   if(lots <= 0.0)
   {
      Print("Sizing failed - no trade");
      return(false);
   }
   bool ok = (dir > 0) ? trade.Buy(lots, _Symbol, 0.0, sl, tp, "retest")
                       : trade.Sell(lots, _Symbol, 0.0, sl, tp, "retest");
   if(!ok)
      PrintFormat("Entry failed: %u %s", trade.ResultRetcode(),
                  trade.ResultRetcodeDescription());
   return(ok);
}

//+------------------------------------------------------------------+
//| Aggressive ATR trailing stop, every tick                         |
//+------------------------------------------------------------------+
void ManageTrailing()
{
   double a[1];
   if(CopyBuffer(g_atr, 0, 0, 1, a) != 1 || a[0] <= 0.0)
      return;
   double atr = a[0];
   double minDist = (double)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL) * _Point;

   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0 || PositionGetString(POSITION_SYMBOL) != _Symbol)
         continue;
      if(PositionGetInteger(POSITION_MAGIC) != (long)InpMagicNumber)
         continue;

      long   type = PositionGetInteger(POSITION_TYPE);
      double open = PositionGetDouble(POSITION_PRICE_OPEN);
      double curSL = PositionGetDouble(POSITION_SL);
      double tp   = PositionGetDouble(POSITION_TP);
      double bid  = SymbolInfoDouble(_Symbol, SYMBOL_BID);
      double ask  = SymbolInfoDouble(_Symbol, SYMBOL_ASK);

      if(type == POSITION_TYPE_BUY)
      {
         if(bid - open < InpTrailStartATR * atr)
            continue;
         double newSL = MathMin(bid - InpTrailDistATR * atr, bid - minDist);
         newSL = NormalizeDouble(newSL, _Digits);
         if(curSL == 0.0 || newSL > curSL + _Point / 2.0)
            trade.PositionModify(ticket, newSL, tp);
      }
      else
      {
         if(open - ask < InpTrailStartATR * atr)
            continue;
         double newSL = MathMax(ask + InpTrailDistATR * atr, ask + minDist);
         newSL = NormalizeDouble(newSL, _Digits);
         if(curSL == 0.0 || newSL < curSL - _Point / 2.0)
            trade.PositionModify(ticket, newSL, tp);
      }
   }
}

//+------------------------------------------------------------------+
bool TradedToday(datetime dayStart)
{
   if(!HistorySelect(dayStart, TimeCurrent() + 60))
      return(HasAnyPosition());
   for(int i = HistoryDealsTotal() - 1; i >= 0; i--)
   {
      ulong t = HistoryDealGetTicket(i);
      if(t == 0)
         continue;
      if(HistoryDealGetInteger(t, DEAL_MAGIC) != (long)InpMagicNumber)
         continue;
      if(HistoryDealGetString(t, DEAL_SYMBOL) != _Symbol)
         continue;
      if(HistoryDealGetInteger(t, DEAL_ENTRY) == DEAL_ENTRY_IN)
         return(true);
   }
   return(HasAnyPosition());
}

//+------------------------------------------------------------------+
bool HasAnyPosition()
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong t = PositionGetTicket(i);
      if(t == 0 || PositionGetString(POSITION_SYMBOL) != _Symbol)
         continue;
      if(PositionGetInteger(POSITION_MAGIC) == (long)InpMagicNumber)
         return(true);
   }
   return(false);
}

//+------------------------------------------------------------------+
double RecentClosedTradesPL(int n)
{
   if(!HistorySelect(0, TimeCurrent() + 60))
      return(0.0);
   double sum = 0.0;
   int counted = 0;
   for(int i = HistoryDealsTotal() - 1; i >= 0 && counted < n; i--)
   {
      ulong t = HistoryDealGetTicket(i);
      if(t == 0)
         continue;
      if(HistoryDealGetInteger(t, DEAL_MAGIC) != (long)InpMagicNumber)
         continue;
      if(HistoryDealGetString(t, DEAL_SYMBOL) != _Symbol)
         continue;
      if(HistoryDealGetInteger(t, DEAL_ENTRY) != DEAL_ENTRY_OUT)
         continue;
      sum += HistoryDealGetDouble(t, DEAL_PROFIT)
           + HistoryDealGetDouble(t, DEAL_SWAP)
           + HistoryDealGetDouble(t, DEAL_COMMISSION);
      counted++;
   }
   return(sum);
}

//+------------------------------------------------------------------+
double CalcLots(double price, double sl, int dir)
{
   double lossPerLot = 0.0;
   ENUM_ORDER_TYPE ot = (dir > 0) ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;
   if(!OrderCalcProfit(ot, _Symbol, 1.0, price, sl, lossPerLot) || lossPerLot >= 0.0)
      return(0.0);

   double riskPct = InpRiskPercent;
   if(InpRecoveryMode && RecentClosedTradesPL(InpRecentTrades) < 0.0)
      riskPct /= 10.0;
   double lots = AccountInfoDouble(ACCOUNT_BALANCE) * riskPct / 100.0 / MathAbs(lossPerLot);

   double marginPerLot = 0.0;
   if(OrderCalcMargin(ot, _Symbol, 1.0, price, marginPerLot) && marginPerLot > 0.0)
   {
      double maxLots = AccountInfoDouble(ACCOUNT_MARGIN_FREE) * 0.4 / marginPerLot;
      if(lots > maxLots)
         lots = maxLots;
   }

   double vmin  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double vmax  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double vstep = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   if(vstep > 0.0)
      lots = MathFloor(lots / vstep) * vstep;
   if(lots < vmin)
      return(0.0);
   return(NormalizeDouble(MathMin(lots, vmax), 2));
}

//+------------------------------------------------------------------+
//| Compact info panel                                               |
//+------------------------------------------------------------------+
string StateText(SideState s)
{
   if(s == ST_WAIT_BREAK)  return("waiting for break");
   if(s == ST_WAIT_RETEST) return("BROKE - awaiting retest");
   return("done for today");
}

void Row(string name, int y, string text, color clr)
{
   string o = "GBR_" + name;
   if(ObjectFind(0, o) < 0)
   {
      ObjectCreate(0, o, OBJ_LABEL, 0, 0, 0);
      ObjectSetInteger(0, o, OBJPROP_CORNER, CORNER_LEFT_UPPER);
      ObjectSetInteger(0, o, OBJPROP_XDISTANCE, 14);
      ObjectSetInteger(0, o, OBJPROP_YDISTANCE, y);
      ObjectSetString(0, o, OBJPROP_FONT, "Consolas");
      ObjectSetInteger(0, o, OBJPROP_FONTSIZE, 9);
      ObjectSetInteger(0, o, OBJPROP_SELECTABLE, false);
      ObjectSetInteger(0, o, OBJPROP_HIDDEN, true);
   }
   ObjectSetInteger(0, o, OBJPROP_COLOR, clr);
   ObjectSetString(0, o, OBJPROP_TEXT, text);
}

void UpdatePanel()
{
   if(MQLInfoInteger(MQL_TESTER) && !MQLInfoInteger(MQL_VISUAL_MODE))
      return;
   string bg = "GBR_bg";
   if(ObjectFind(0, bg) < 0)
   {
      ObjectCreate(0, bg, OBJ_RECTANGLE_LABEL, 0, 0, 0);
      ObjectSetInteger(0, bg, OBJPROP_CORNER, CORNER_LEFT_UPPER);
      ObjectSetInteger(0, bg, OBJPROP_XDISTANCE, 6);
      ObjectSetInteger(0, bg, OBJPROP_YDISTANCE, 18);
      ObjectSetInteger(0, bg, OBJPROP_XSIZE, 330);
      ObjectSetInteger(0, bg, OBJPROP_YSIZE, 150);
      ObjectSetInteger(0, bg, OBJPROP_BGCOLOR, C'18,22,30');
      ObjectSetInteger(0, bg, OBJPROP_BORDER_TYPE, BORDER_FLAT);
      ObjectSetInteger(0, bg, OBJPROP_COLOR, C'80,90,110');
      ObjectSetInteger(0, bg, OBJPROP_SELECTABLE, false);
      ObjectSetInteger(0, bg, OBJPROP_HIDDEN, true);
   }
   double recentPL = RecentClosedTradesPL(InpRecentTrades);
   bool recovery = InpRecoveryMode && recentPL < 0.0;
   int y = 24;
   Row("t",  y, "GOLD BREAKOUT + RETEST v1.00", clrGold);           y += 18;
   Row("lv", y, StringFormat("Prev H %.2f   Prev L %.2f", g_pdh, g_pdl), clrWhiteSmoke); y += 18;
   Row("lo", y, "Long : " + StateText(g_long),
       g_long == ST_WAIT_RETEST ? clrLimeGreen : clrSilver);        y += 16;
   Row("sh", y, "Short: " + StateText(g_short),
       g_short == ST_WAIT_RETEST ? clrOrangeRed : clrSilver);       y += 18;
   Row("rk", y, recovery ? StringFormat("Risk: RECOVERY %.2f%%", InpRiskPercent / 10.0)
                         : StringFormat("Risk: NORMAL %.1f%%", InpRiskPercent),
       recovery ? clrOrange : clrLimeGreen);                        y += 16;
   Row("ac", y, StringFormat("Balance %.2f  Equity %.2f",
       AccountInfoDouble(ACCOUNT_BALANCE), AccountInfoDouble(ACCOUNT_EQUITY)), clrWhiteSmoke);
   ChartRedraw();
}
//+------------------------------------------------------------------+
