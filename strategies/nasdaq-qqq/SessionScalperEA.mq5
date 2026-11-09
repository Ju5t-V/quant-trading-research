//+------------------------------------------------------------------+
//|                                          SessionScalperEA.mq5   |
//|  Intraday mean-reversion scalper for index CFDs (USTEC)          |
//|                                                                  |
//|  Logic: during the US cash session, when price stretches more    |
//|  than InpEntryATR x ATR(M5) away from its M5 EMA, fade the move  |
//|  (buy the dip / sell the spike) targeting a return to the EMA.   |
//|  Hard stop at InpStopATR x ATR beyond entry; time stop after     |
//|  InpMaxBars M5 bars; everything closed before the cash close -   |
//|  always flat overnight (no swap).                                |
//|                                                                  |
//|  Guards: max spread filter, one position at a time, max one      |
//|  entry per M5 bar, 0.5% risk sizing via OrderCalcProfit with     |
//|  margin cap, recovery mode (1/10 size while last N trades are    |
//|  net negative), restart-safe (SL/TP live on the server; the      |
//|  time stop is computed from the position's own open time).      |
//+------------------------------------------------------------------+
#property copyright   "Jerry"
#property version     "1.00"
#property description "US-session mean-reversion scalper: fade >k*ATR stretches from the M5 EMA back to the mean."

#include <Trade\Trade.mqh>

input int    InpOpenHour     = 16;       // US cash open - server hour
input int    InpOpenMin      = 30;       // US cash open - server minute
input double InpSessionHours = 6.5;      // Cash session length (hours)
input int    InpEmaPeriod    = 20;       // EMA period (M5)
input int    InpAtrPeriod    = 14;       // ATR period (M5)
input double InpEntryATR     = 1.5;      // Entry stretch (x ATR from EMA)
input double InpStopATR      = 1.5;      // Stop distance beyond entry (x ATR)
input int    InpMaxBars      = 12;       // Time stop (M5 bars, 12 = 1 hour)
input double InpMaxSpreadPts = 150;      // Max spread to trade (points)
input double InpRiskPercent  = 0.5;      // Risk % of balance per trade
input bool   InpRecoveryMode = true;     // 1/10 size while last N trades net negative
input int    InpRecentTrades = 10;       // N recent trades for recovery mode
input ulong  InpMagicNumber  = 20260714; // Magic Number

CTrade   trade;
int      g_hEma = INVALID_HANDLE, g_hAtr = INVALID_HANDLE;
datetime g_lastEntryBar = 0;   // M5 bar of the last entry (one entry per bar)
int      g_sessOpen, g_sessLastEntry, g_sessExit;  // minutes from midnight

//+------------------------------------------------------------------+
int OnInit()
{
   trade.SetExpertMagicNumber(InpMagicNumber);
   trade.SetTypeFillingBySymbol(_Symbol);
   trade.SetDeviationInPoints(30);

   g_hEma = iMA(_Symbol, PERIOD_M5, InpEmaPeriod, 0, MODE_EMA, PRICE_CLOSE);
   g_hAtr = iATR(_Symbol, PERIOD_M5, InpAtrPeriod);
   if(g_hEma == INVALID_HANDLE || g_hAtr == INVALID_HANDLE)
      return(INIT_FAILED);

   g_sessOpen      = InpOpenHour * 60 + InpOpenMin;
   int len         = (int)MathRound(InpSessionHours * 60.0);
   g_sessLastEntry = g_sessOpen + len - 60;   // no new trades in the last hour
   g_sessExit      = g_sessOpen + len - 5;    // flat 5 min before the close
   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
void OnTick()
{
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   int nowMin = dt.hour * 60 + dt.min;

   // ---- manage an open position ----
   if(HasPosition())
   {
      // session end or time stop
      if(nowMin >= g_sessExit || nowMin < g_sessOpen)
         CloseAll("session end");
      else
      {
         datetime opened = PositionOpenTime();
         if(opened > 0 && TimeCurrent() - opened >= (long)InpMaxBars * 300)
            CloseAll("time stop");
      }
      return;
   }

   // ---- entries only inside the session window ----
   if(nowMin < g_sessOpen + 30 || nowMin >= g_sessLastEntry)
      return; // skip the volatile first 30 min and the last hour

   // one entry attempt per M5 bar
   datetime bar = iTime(_Symbol, PERIOD_M5, 0);
   if(bar == 0 || bar == g_lastEntryBar)
      return;

   // spread guard
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   if((ask - bid) / _Point > InpMaxSpreadPts)
      return;

   // indicators from completed bars
   double ema[1], atr[1];
   if(CopyBuffer(g_hEma, 0, 1, 1, ema) != 1 || CopyBuffer(g_hAtr, 0, 1, 1, atr) != 1)
      return;
   if(ema[0] <= 0.0 || atr[0] <= 0.0)
      return;

   double mid = (ask + bid) / 2.0;
   double stretch = mid - ema[0];

   if(stretch <= -InpEntryATR * atr[0])
      Enter(1, ema[0], atr[0], bar);            // stretched below -> buy the dip
   else if(stretch >= InpEntryATR * atr[0])
      Enter(-1, ema[0], atr[0], bar);           // stretched above -> sell the spike
}

//+------------------------------------------------------------------+
void Enter(int dir, double ema, double atr, datetime bar)
{
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double price = (dir > 0) ? ask : bid;

   double sl = (dir > 0) ? price - InpStopATR * atr : price + InpStopATR * atr;
   double tp = ema;   // target: back to the mean
   sl = NormalizeDouble(sl, _Digits);
   tp = NormalizeDouble(tp, _Digits);

   // sanity: target must be on the profitable side and worth > spread
   double reward = (dir > 0) ? tp - price : price - tp;
   if(reward < 2.0 * (ask - bid))
      return;

   double lots = CalcLots(price, sl, dir);
   if(lots <= 0.0)
      return;

   bool ok = (dir > 0) ? trade.Buy(lots, _Symbol, 0.0, sl, tp, "scalp")
                       : trade.Sell(lots, _Symbol, 0.0, sl, tp, "scalp");
   if(ok)
      g_lastEntryBar = bar;
   else
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
datetime PositionOpenTime()
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0 || PositionGetString(POSITION_SYMBOL) != _Symbol)
         continue;
      if(PositionGetInteger(POSITION_MAGIC) == (long)InpMagicNumber)
         return((datetime)PositionGetInteger(POSITION_TIME));
   }
   return(0);
}

//+------------------------------------------------------------------+
void CloseAll(string reason)
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0 || PositionGetString(POSITION_SYMBOL) != _Symbol)
         continue;
      if(PositionGetInteger(POSITION_MAGIC) == (long)InpMagicNumber)
      {
         trade.PositionClose(ticket);
         Print("Closed: ", reason);
      }
   }
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
