//+------------------------------------------------------------------+
//|                                        IntradayMomentumEA.mq5   |
//|  Market Intraday Momentum - research-backed day strategy         |
//|                                                                  |
//|  Based on:                                                       |
//|   Gao, Han, Li & Zhou (2018) "Market intraday momentum",         |
//|   Journal of Financial Economics 129(2), 394-414.                |
//|   Li, Sakkas & Urquhart (2022), Journal of Financial Markets 57  |
//|   (global confirmation in 16 developed markets).                 |
//|                                                                  |
//|  Rule: the US cash session's FIRST half-hour return (measured    |
//|  from the previous cash close) predicts the LAST half-hour       |
//|  return with the same sign.                                      |
//|   - r1 = P(open+30m) / previous cash close - 1                   |
//|   - optional confirmation (paper): the 12:00-12:30 ET return     |
//|     must have the same sign as r1                                |
//|   - 30 minutes before the cash close: enter in the direction of  |
//|     the signal; exit one minute before the cash close.           |
//|  Always flat overnight -> no swap/financing on CFDs.             |
//|                                                                  |
//|  Times are SERVER times (MetaQuotes = US cash open 16:30,        |
//|  close 23:00 while EU/US daylight saving align; check after DST  |
//|  switches and adjust InpOpenHour/Min if needed).                 |
//|                                                                  |
//|  Risk framework (validated on the gold EA): auto-sizing risks    |
//|  InpRiskPercent of balance against the protective stop using     |
//|  OrderCalcProfit, capped at 40% of free margin; recovery mode    |
//|  trades at 1/10 size while the last N closed trades are net      |
//|  negative. Restart-safe: signal is recomputed from M1 history    |
//|  and the EA checks its own deals before trading twice in a day.  |
//+------------------------------------------------------------------+
#property copyright   "Jerry"
#property version     "1.00"
#property description "First half-hour return predicts last half-hour (JFE 2018). Long/short last 30 min of US session, flat overnight."

#include <Trade\Trade.mqh>

input int    InpOpenHour      = 16;      // US cash open - server hour
input int    InpOpenMin       = 30;      // US cash open - server minute
input double InpSessionHours  = 6.5;     // Cash session length (hours)
input bool   InpLunchConfirm  = true;    // Require 12:00-12:30 ET return to agree
input double InpMinSignalPct  = 0.0;     // Min |first half-hour return| in % (0 = paper rule)
input double InpStopPct       = 0.5;     // Protective stop (% of price)
input double InpRiskPercent   = 2.0;     // Risk % of balance per trade
input bool   InpRecoveryMode  = true;    // 1/10 size while last N trades net negative
input int    InpRecentTrades  = 10;      // N recent trades for recovery mode
input ulong  InpMagicNumber   = 20260713;// Magic Number

CTrade   trade;
datetime g_day      = 0;
bool     g_doneToday = false;

// minutes-from-midnight session anchors, derived in OnInit
int g_open, g_firstEnd, g_lunchA, g_lunchB, g_entryT, g_exitT;

//+------------------------------------------------------------------+
int OnInit()
{
   trade.SetExpertMagicNumber(InpMagicNumber);
   trade.SetTypeFillingBySymbol(_Symbol);
   trade.SetDeviationInPoints(30);

   g_open     = InpOpenHour * 60 + InpOpenMin;
   g_firstEnd = g_open + 30;                                  // 17:00
   g_lunchA   = g_open + 150;                                 // 19:00 (12:00 ET)
   g_lunchB   = g_open + 180;                                 // 19:30 (12:30 ET)
   int len    = (int)MathRound(InpSessionHours * 60.0);
   g_entryT   = g_open + len - 30;                            // 22:30
   g_exitT    = g_open + len - 1;                             // 22:59
   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
void OnTick()
{
   datetime day = iTime(_Symbol, PERIOD_D1, 0);
   if(day == 0)
      return;
   if(day != g_day)
   {
      g_day = day;
      g_doneToday = TradedToday(day);   // restart safety
   }

   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   int nowMin = dt.hour * 60 + dt.min;

   // manage an open position: time-exit at the end of the session,
   // or immediately if we are somehow outside the session (restart case)
   if(HasPosition())
   {
      if(nowMin >= g_exitT || nowMin < g_open)
         CloseAll();
      return;
   }

   // entry window: [entryT, entryT+25) once per day
   if(!g_doneToday && nowMin >= g_entryT && nowMin < g_entryT + 25)
   {
      g_doneToday = true;
      double sig = Signal();
      if(sig > 0.0)
         Enter(1);
      else if(sig < 0.0)
         Enter(-1);
      else
         Print("No trade today: signal empty or filtered");
   }
}

//+------------------------------------------------------------------+
//| Signed first half-hour return, 0 if filtered out                 |
//+------------------------------------------------------------------+
double Signal()
{
   double pFirst = CloseAtMinute(g_day, g_firstEnd);
   double pPrev  = PrevSessionClose();
   if(pFirst <= 0.0 || pPrev <= 0.0)
      return(0.0);
   double r1 = pFirst / pPrev - 1.0;

   if(100.0 * MathAbs(r1) < InpMinSignalPct)
      return(0.0);

   if(InpLunchConfirm)
   {
      double a = CloseAtMinute(g_day, g_lunchA);
      double b = CloseAtMinute(g_day, g_lunchB);
      if(a <= 0.0 || b <= 0.0)
         return(0.0);
      double r2 = b / a - 1.0;
      if(r1 * r2 <= 0.0)                 // signs must agree (paper's joint rule)
         return(0.0);
   }
   return(r1);
}

//+------------------------------------------------------------------+
//| M1 close at (or just before) a given minute-of-day of `day`      |
//+------------------------------------------------------------------+
double CloseAtMinute(datetime day, int minuteOfDay)
{
   datetime t = day + (datetime)((minuteOfDay - 1) * 60); // bar covering final minute
   int shift = iBarShift(_Symbol, PERIOD_M1, t, false);
   if(shift < 0)
      return(0.0);
   datetime bt = iTime(_Symbol, PERIOD_M1, shift);
   if(bt < day || bt > t || (t - bt) > 300)  // tolerate up to 5 missing minutes
      return(0.0);
   return(iClose(_Symbol, PERIOD_M1, shift));
}

//+------------------------------------------------------------------+
//| Previous trading day's cash-close price (~1 min before close)    |
//+------------------------------------------------------------------+
double PrevSessionClose()
{
   for(int d = 1; d <= 5; d++)
   {
      datetime prevDay = iTime(_Symbol, PERIOD_D1, d);
      if(prevDay == 0)
         return(0.0);
      double p = CloseAtMinute(prevDay, g_exitT);
      if(p > 0.0)
         return(p);
   }
   return(0.0);
}

//+------------------------------------------------------------------+
void Enter(int dir)
{
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double price = (dir > 0) ? ask : bid;
   double sl    = (dir > 0) ? price * (1.0 - InpStopPct / 100.0)
                            : price * (1.0 + InpStopPct / 100.0);
   sl = NormalizeDouble(sl, _Digits);

   double lots = CalcLots(price, sl, dir);
   if(lots <= 0.0)
   {
      Print("Sizing failed - no trade");
      return;
   }
   bool ok = (dir > 0) ? trade.Buy(lots, _Symbol, 0.0, sl, 0.0, "ITSM")
                       : trade.Sell(lots, _Symbol, 0.0, sl, 0.0, "ITSM");
   if(!ok)
      PrintFormat("Entry failed: %u %s", trade.ResultRetcode(),
                  trade.ResultRetcodeDescription());
}

//+------------------------------------------------------------------+
bool HasPosition()
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0 || PositionGetString(POSITION_SYMBOL) != _Symbol)
         continue;
      if(PositionGetInteger(POSITION_MAGIC) == (long)InpMagicNumber)
         return(true);
   }
   return(false);
}

//+------------------------------------------------------------------+
void CloseAll()
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0 || PositionGetString(POSITION_SYMBOL) != _Symbol)
         continue;
      if(PositionGetInteger(POSITION_MAGIC) == (long)InpMagicNumber)
         trade.PositionClose(ticket);
   }
}

//+------------------------------------------------------------------+
//| Did this EA already open a trade since `dayStart`?               |
//+------------------------------------------------------------------+
bool TradedToday(datetime dayStart)
{
   if(!HistorySelect(dayStart, TimeCurrent() + 60))
      return(false);
   for(int i = HistoryDealsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = HistoryDealGetTicket(i);
      if(ticket == 0)
         continue;
      if(HistoryDealGetInteger(ticket, DEAL_MAGIC) != (long)InpMagicNumber)
         continue;
      if(HistoryDealGetString(ticket, DEAL_SYMBOL) != _Symbol)
         continue;
      if(HistoryDealGetInteger(ticket, DEAL_ENTRY) == DEAL_ENTRY_IN)
         return(true);
   }
   return(HasPosition());
}

//+------------------------------------------------------------------+
//| Summed P/L of this EA's last N closed trades                     |
//+------------------------------------------------------------------+
double RecentClosedTradesPL(int n)
{
   if(!HistorySelect(0, TimeCurrent() + 60))
      return(0.0);
   double sum = 0.0;
   int counted = 0;
   for(int i = HistoryDealsTotal() - 1; i >= 0 && counted < n; i--)
   {
      ulong ticket = HistoryDealGetTicket(i);
      if(ticket == 0)
         continue;
      if(HistoryDealGetInteger(ticket, DEAL_MAGIC) != (long)InpMagicNumber)
         continue;
      if(HistoryDealGetString(ticket, DEAL_SYMBOL) != _Symbol)
         continue;
      if(HistoryDealGetInteger(ticket, DEAL_ENTRY) != DEAL_ENTRY_OUT)
         continue;
      sum += HistoryDealGetDouble(ticket, DEAL_PROFIT)
           + HistoryDealGetDouble(ticket, DEAL_SWAP)
           + HistoryDealGetDouble(ticket, DEAL_COMMISSION);
      counted++;
   }
   return(sum);
}

//+------------------------------------------------------------------+
//| Risk-based sizing with margin cap and recovery mode              |
//+------------------------------------------------------------------+
double CalcLots(double price, double sl, int dir)
{
   double lossPerLot = 0.0;
   ENUM_ORDER_TYPE ot = (dir > 0) ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;
   if(!OrderCalcProfit(ot, _Symbol, 1.0, price, sl, lossPerLot) || lossPerLot >= 0.0)
   {
      Print("OrderCalcProfit failed");
      return(0.0);
   }
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
