//+------------------------------------------------------------------+
//|                                           OneBarBreakoutEA.mq5   |
//|  One-candle-at-a-time previous-day breakout, symbol-generic.     |
//|  Derived from OneBarGoldEA v1.10 (XAUUSD, PF 2.01 real ticks     |
//|  2020-2026); the gold-specific floor distances are now inputs    |
//|  so SL/TP/trail geometry can be calibrated per symbol            |
//|  (spread-to-ATR ratios differ 4x between e.g. gold and silver).  |
//|                                                                  |
//|  Every trade lives inside a single D1 candle:                    |
//|    - at InpEntryHour a buy stop is placed at the previous day's  |
//|      high and a sell stop at the previous day's low              |
//|    - stops, targets and the trailing distance scale with daily   |
//|      ATR(14) relative to InpAtrRefPts                            |
//|    - any open position is force-closed at InpFlatHour:InpFlatMin |
//|      server time, and unfilled orders expire at midnight, so no  |
//|      trade ever spans two daily candles                          |
//+------------------------------------------------------------------+
#property copyright   "Jerry"
#property version     "1.00"
#property description "One-candle prev-day breakout with trailing stop, symbol-generic"

#include <Trade\Trade.mqh>

//--- inputs
input double InpTakeProfitPts = 1000;     // Take Profit (points, ATR-scaled)
input double InpStopLossPts   = 500;      // Stop Loss (points, ATR-scaled)
input int    InpEntryHour     = 6;        // Place orders at this server hour
input int    InpLastEntryHour = 24;       // Cancel unfilled stops after this hour (24 = never)
input bool   InpEODFlat       = true;     // One-candle rule: flat before daily close
input int    InpFlatHour      = 23;       // Force-flat hour (server)
input int    InpFlatMin       = 50;       // Force-flat minute
input bool   InpTradeLong     = true;     // Arm buy stop at prev-day high
input bool   InpTradeShort    = false;    // Arm sell stop at prev-day low
input int    InpTrendSmaDays  = 50;       // D1 SMA trend filter period (0 = off)
input bool   InpUseTrail      = true;     // Aggressive trailing stop
input double InpTrailStartPts = 300;      // Trailing Start (points, ATR-scaled)
input double InpTrailDistPts  = 150;      // Trailing Stop Distance (points, ATR-scaled)
input double InpAtrRefPts     = 14000;    // ATR reference in points (0 = fixed points)
input bool   InpAutoLot       = true;     // Auto Lot Size
input double InpRiskPercent   = 2.0;      // Risk % for Auto Lot
input double InpLotSize       = 0.1;      // Lot Size (when Auto Lot = false)
input bool   InpRecoveryMode  = true;     // Cut risk to 1/10 while recent trades net negative
input int    InpRecentTrades  = 10;       // Trades checked by recovery mode
input double InpMinSlPts      = 200;      // Floor: SL points
input double InpMinTpPts      = 400;      // Floor: TP points
input double InpMinStartPts   = 150;      // Floor: trail-start points
input double InpMinDistPts    = 80;       // Floor: trail-distance points
input ulong  InpMagicNumber   = 20260719; // Magic Number

CTrade   trade;
datetime g_dayStart    = 0;
bool     g_placedToday = false;
bool     g_flatDone    = false;
int      g_atrHandle   = INVALID_HANDLE;
int      g_maHandle    = INVALID_HANDLE;
double   g_slPts, g_tpPts, g_trailStartPts, g_trailDistPts;

//+------------------------------------------------------------------+
int OnInit()
{
   trade.SetExpertMagicNumber(InpMagicNumber);
   trade.SetTypeFillingBySymbol(_Symbol);
   trade.SetDeviationInPoints(20);

   g_slPts         = InpStopLossPts;
   g_tpPts         = InpTakeProfitPts;
   g_trailStartPts = InpTrailStartPts;
   g_trailDistPts  = InpTrailDistPts;

   if(InpAtrRefPts > 0)
   {
      g_atrHandle = iATR(_Symbol, PERIOD_D1, 14);
      if(g_atrHandle == INVALID_HANDLE)
         Print("iATR handle failed - falling back to fixed points");
   }
   if(InpTrendSmaDays > 0)
   {
      g_maHandle = iMA(_Symbol, PERIOD_D1, InpTrendSmaDays, 0, MODE_SMA, PRICE_CLOSE);
      if(g_maHandle == INVALID_HANDLE)
         Print("iMA handle failed - trend filter disabled");
   }
   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
void RefreshScaledDistances()
{
   double scale = 1.0;
   if(InpAtrRefPts > 0 && g_atrHandle != INVALID_HANDLE)
   {
      double buf[1];
      if(CopyBuffer(g_atrHandle, 0, 1, 1, buf) == 1 && buf[0] > 0.0)
         scale = MathMax(0.1, MathMin(2.0, (buf[0] / _Point) / InpAtrRefPts));
   }
   g_slPts         = MathMax(InpMinSlPts,    InpStopLossPts   * scale);
   g_tpPts         = MathMax(InpMinTpPts,    InpTakeProfitPts * scale);
   g_trailStartPts = MathMax(InpMinStartPts, InpTrailStartPts * scale);
   g_trailDistPts  = MathMax(InpMinDistPts,  InpTrailDistPts  * scale);
}

//+------------------------------------------------------------------+
void OnTick()
{
   datetime dayStart = iTime(_Symbol, PERIOD_D1, 0);
   if(dayStart == 0)
      return;

   if(dayStart != g_dayStart)
   {
      g_dayStart    = dayStart;
      g_placedToday = false;
      g_flatDone    = false;
      DeletePendingOrders();
   }

   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   int nowMin  = dt.hour * 60 + dt.min;
   int flatMin = InpFlatHour * 60 + InpFlatMin;

   // one-candle rule: flat before the daily candle closes
   if(InpEODFlat && nowMin >= flatMin)
   {
      if(!g_flatDone)
      {
         g_flatDone = true;
         DeletePendingOrders();
         CloseAllPositions();
      }
      return; // nothing else to do until the next candle
   }

   if(!g_placedToday && dt.hour >= InpEntryHour)
   {
      g_placedToday = true;
      if(dt.hour < InpLastEntryHour)
         PlaceDailyOrders();
   }

   // a breakout this late has no room to run before the force-flat
   if(InpLastEntryHour < 24 && dt.hour >= InpLastEntryHour)
      DeletePendingOrders();

   if(InpUseTrail)
      ManageTrailing();
}

//+------------------------------------------------------------------+
void PlaceDailyOrders()
{
   double prevHigh = iHigh(_Symbol, PERIOD_D1, 1);
   double prevLow  = iLow(_Symbol, PERIOD_D1, 1);
   if(prevHigh <= 0.0 || prevLow <= 0.0)
      return;

   RefreshScaledDistances();

   double ask     = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid     = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double minDist = StopsLevelPoints() * _Point;

   bool     canExpire = CanUseSpecifiedExpiry();
   datetime expiry    = g_dayStart + PeriodSeconds(PERIOD_D1);
   ENUM_ORDER_TYPE_TIME timeType = canExpire ? ORDER_TIME_SPECIFIED : ORDER_TIME_GTC;

   double lots = CalcLots();
   if(lots <= 0.0)
   {
      Print("Lot calculation failed - no orders placed");
      return;
   }

   // trend filter: only trade breakouts aligned with the D1 SMA side
   bool longOK = true, shortOK = true;
   if(InpTrendSmaDays > 0 && g_maHandle != INVALID_HANDLE)
   {
      double ma[1];
      double prevClose = iClose(_Symbol, PERIOD_D1, 1);
      if(CopyBuffer(g_maHandle, 0, 1, 1, ma) == 1 && ma[0] > 0.0 && prevClose > 0.0)
      {
         longOK  = prevClose > ma[0];
         shortOK = prevClose < ma[0];
      }
   }

   if(InpTradeLong && longOK)
   {
      double entry = NormalizeDouble(prevHigh, _Digits);
      if(entry >= ask + minDist)
      {
         double sl = NormalizeDouble(entry - g_slPts * _Point, _Digits);
         double tp = NormalizeDouble(entry + g_tpPts * _Point, _Digits);
         if(!trade.BuyStop(lots, entry, _Symbol, sl, tp, timeType,
                           canExpire ? expiry : 0, "PDH 1-bar"))
            PrintFormat("BuyStop @%.2f failed: %u %s",
                        entry, trade.ResultRetcode(), trade.ResultRetcodeDescription());
      }
   }

   if(InpTradeShort && shortOK)
   {
      double entry = NormalizeDouble(prevLow, _Digits);
      if(entry <= bid - minDist)
      {
         double sl = NormalizeDouble(entry + g_slPts * _Point, _Digits);
         double tp = NormalizeDouble(entry - g_tpPts * _Point, _Digits);
         if(!trade.SellStop(lots, entry, _Symbol, sl, tp, timeType,
                            canExpire ? expiry : 0, "PDL 1-bar"))
            PrintFormat("SellStop @%.2f failed: %u %s",
                        entry, trade.ResultRetcode(), trade.ResultRetcodeDescription());
      }
   }
}

//+------------------------------------------------------------------+
void ManageTrailing()
{
   double minDist = StopsLevelPoints() * _Point;

   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0)
         continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol)
         continue;
      if(PositionGetInteger(POSITION_MAGIC) != (long)InpMagicNumber)
         continue;

      long   type  = PositionGetInteger(POSITION_TYPE);
      double open  = PositionGetDouble(POSITION_PRICE_OPEN);
      double curSL = PositionGetDouble(POSITION_SL);
      double tp    = PositionGetDouble(POSITION_TP);
      double bid   = SymbolInfoDouble(_Symbol, SYMBOL_BID);
      double ask   = SymbolInfoDouble(_Symbol, SYMBOL_ASK);

      if(type == POSITION_TYPE_BUY)
      {
         double profitPts = (bid - open) / _Point;
         if(profitPts < g_trailStartPts)
            continue;
         double newSL = bid - g_trailDistPts * _Point;
         newSL = MathMin(newSL, bid - minDist);
         newSL = NormalizeDouble(newSL, _Digits);
         if(curSL == 0.0 || newSL > curSL + _Point / 2.0)
            trade.PositionModify(ticket, newSL, tp);
      }
      else
      {
         double profitPts = (open - ask) / _Point;
         if(profitPts < g_trailStartPts)
            continue;
         double newSL = ask + g_trailDistPts * _Point;
         newSL = MathMax(newSL, ask + minDist);
         newSL = NormalizeDouble(newSL, _Digits);
         if(curSL == 0.0 || newSL < curSL - _Point / 2.0)
            trade.PositionModify(ticket, newSL, tp);
      }
   }
}

//+------------------------------------------------------------------+
void CloseAllPositions()
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0)
         continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol)
         continue;
      if(PositionGetInteger(POSITION_MAGIC) != (long)InpMagicNumber)
         continue;
      if(!trade.PositionClose(ticket))
         PrintFormat("PositionClose %I64u failed: %u %s",
                     ticket, trade.ResultRetcode(), trade.ResultRetcodeDescription());
   }
}

//+------------------------------------------------------------------+
void DeletePendingOrders()
{
   for(int i = OrdersTotal() - 1; i >= 0; i--)
   {
      ulong ticket = OrderGetTicket(i);
      if(ticket == 0)
         continue;
      if(OrderGetString(ORDER_SYMBOL) != _Symbol)
         continue;
      if(OrderGetInteger(ORDER_MAGIC) != (long)InpMagicNumber)
         continue;

      long type = OrderGetInteger(ORDER_TYPE);
      if(type == ORDER_TYPE_BUY_STOP || type == ORDER_TYPE_SELL_STOP)
         trade.OrderDelete(ticket);
   }
}

//+------------------------------------------------------------------+
double CalcLots()
{
   double lots = InpLotSize;
   double ask  = SymbolInfoDouble(_Symbol, SYMBOL_ASK);

   if(InpAutoLot)
   {
      double lossPerLot = 0.0;
      if(!OrderCalcProfit(ORDER_TYPE_BUY, _Symbol, 1.0, ask,
                          ask - g_slPts * _Point, lossPerLot) || lossPerLot >= 0.0)
      {
         Print("Auto lot: OrderCalcProfit failed - no orders placed");
         return(0.0);
      }
      double riskPct = InpRiskPercent;
      if(InpRecoveryMode && RecentClosedTradesPL(InpRecentTrades) < 0.0)
         riskPct /= 10.0;
      double riskMoney = AccountInfoDouble(ACCOUNT_BALANCE) * riskPct / 100.0;
      lots = riskMoney / MathAbs(lossPerLot);
   }

   double marginPerLot = 0.0;
   if(OrderCalcMargin(ORDER_TYPE_BUY, _Symbol, 1.0, ask, marginPerLot) && marginPerLot > 0.0)
   {
      double maxLots = AccountInfoDouble(ACCOUNT_MARGIN_FREE) * 0.4 / marginPerLot;
      if(lots > maxLots)
         lots = maxLots;
   }

   double minLot  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxLot  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double lotStep = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   if(lotStep > 0.0)
      lots = MathFloor(lots / lotStep) * lotStep;
   if(lots < minLot)
      return(0.0);
   lots = MathMin(maxLot, lots);
   return(NormalizeDouble(lots, 2));
}

//+------------------------------------------------------------------+
double RecentClosedTradesPL(int n)
{
   if(!HistorySelect(0, TimeCurrent() + 60))
      return(0.0);
   double sum = 0.0;
   int    counted = 0;
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
double StopsLevelPoints()
{
   return((double)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL));
}

//+------------------------------------------------------------------+
bool CanUseSpecifiedExpiry()
{
   long modes = SymbolInfoInteger(_Symbol, SYMBOL_EXPIRATION_MODE);
   return((modes & SYMBOL_EXPIRATION_SPECIFIED) != 0);
}
//+------------------------------------------------------------------+
