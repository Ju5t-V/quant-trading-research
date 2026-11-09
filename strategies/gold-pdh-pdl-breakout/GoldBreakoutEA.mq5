//+------------------------------------------------------------------+
//|                                             GoldBreakoutEA.mq5   |
//|  Previous-day high/low breakout for XAUUSD (MetaTrader 5)        |
//|                                                                  |
//|  Each trading day, at InpEntryHour (server time):                |
//|    - deletes yesterday's unfilled pending orders                 |
//|    - places a BUY STOP at the previous day's high                |
//|    - places a SELL STOP at the previous day's low                |
//|  Both orders stay active, so up to 2 trades can trigger in one   |
//|  day if both levels are tested.                                  |
//|                                                                  |
//|  Once a trade is 300 points (default) in profit, the stop loss   |
//|  is trailed aggressively 150 points (default) behind price on    |
//|  every tick.                                                     |
//|                                                                  |
//|  v1.10 changes (from Jan-Jul 2026 XAUUSD backtest):              |
//|    - InpEntryHour (default 6): orders are placed after the thin  |
//|      Asian session instead of at midnight. In testing, every     |
//|      full stop-out happened on breakouts triggered 00:00-05:59   |
//|      server time. Set to 0 for the old always-on behaviour.      |
//|    - Default SL tightened 1000 -> 500 points: losing breakouts   |
//|      almost never recovered, so the wider stop only lost more.   |
//|                                                                  |
//|  v1.20 changes (validated on 100% real ticks, Jan-Jul 2026):     |
//|    - Trail defaults 100/50 -> 300/150: on real ticks the 50-pt   |
//|      distance was consumed by tick noise within seconds; the     |
//|      wider trail netted ~27% more with the same drawdown and is  |
//|      far more robust to live-broker spreads (15-30 pts).         |
//|    - Auto lot ON by default (2% risk). Fixed 2.0 lots exceeded   |
//|      free margin on a $10k account at 1:100 after one loss.      |
//|                                                                  |
//|  v1.30 changes (after 2020-2022 stress test):                    |
//|    - All SL/TP/trail distances now scale with daily ATR(14)      |
//|      relative to InpAtrRefPts (14000 pts = 2026 calibration).    |
//|      2026 had ~$142 daily ranges vs ~$25-30 in 2020-22; fixed    |
//|      points were 5x oversized there (PF 1.01, 46% drawdown).     |
//|      Floors: SL>=200, TP>=400, start>=150, dist>=80 points.      |
//|      Set InpAtrRefPts=0 to restore fixed-point behaviour.        |
//|                                                                  |
//|  v1.31: recovery mode. When the sum of the last 10 closed        |
//|  trades is negative, risk drops to 1/10 (0.2%) until the small   |
//|  sampling trades turn net positive again. Caps regime damage     |
//|  (2020 COVID chop bled 10 of 12 months) without trying to        |
//|  predict regimes. Disable with InpRecoveryMode=false.            |
//|                                                                  |
//|  v1.40: on-chart info panel (InpShowPanel) - server time and     |
//|  session, prev-day levels (also drawn as dotted lines), order    |
//|  status, scaled SL/TP/trail, risk mode, next lot size, account.  |
//|                                                                  |
//|  v1.41: restart safety. If MT5 closes and reopens mid-day after  |
//|  orders were already placed or a trade already filled, the EA    |
//|  now detects this (ActedToday) and leaves existing orders and    |
//|  positions untouched instead of deleting and re-placing them -   |
//|  so a restart can never double the day's exposure. Open trades   |
//|  keep their server-side SL/TP the whole time MT5 is closed;      |
//|  only the aggressive trailing pauses until the EA is running.    |
//+------------------------------------------------------------------+
#property copyright   "Jerry"
#property version     "1.41"
#property description "Previous-day high/low breakout with aggressive trailing stop"

#include <Trade\Trade.mqh>

//--- inputs
input double InpTakeProfitPts = 1000;     // Take Profit (points)
input double InpStopLossPts   = 500;      // Stop Loss (points)
input int    InpEntryHour     = 6;        // Place orders at this server hour (0 = at day open)
input double InpLotSize       = 0.1;      // Lot Size (used when Auto Lot = false)
input bool   InpAutoLot       = true;     // Auto Lot Size
input double InpRiskPercent   = 2.0;      // Risk % for Auto Lot
input double InpTrailStartPts = 300;      // Trailing Start (points)
input double InpTrailDistPts  = 150;      // Trailing Stop Distance (points)
input double InpAtrRefPts     = 14000;    // ATR reference in points for scaling (0 = fixed points)
input bool   InpRecoveryMode  = true;     // Cut risk to 1/10 while recent trades are net negative
input int    InpRecentTrades  = 10;       // Number of recent trades checked by recovery mode
input bool   InpShowPanel     = true;     // Show info panel on the chart
input ulong  InpMagicNumber   = 20260705; // Magic Number

CTrade   trade;
datetime g_dayStart    = 0;     // opening time of the current daily bar
bool     g_placedToday = false; // whether today's orders have been placed yet
int      g_atrHandle   = INVALID_HANDLE;

// today's volatility-scaled distances (points); refreshed when orders are placed
double   g_slPts, g_tpPts, g_trailStartPts, g_trailDistPts;
double   g_atrScale = 1.0;

// info-panel state
double   g_pdh = 0.0, g_pdl = 0.0;      // today's order levels
string   g_buyNote = "", g_sellNote = ""; // outcome of today's order placement

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
   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| Scale SL/TP/trail with current daily ATR relative to the         |
//| reference. Floors keep distances above spread/tick noise.        |
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
   g_atrScale = scale;
   g_slPts         = MathMax(200.0, InpStopLossPts   * scale);
   g_tpPts         = MathMax(400.0, InpTakeProfitPts * scale);
   g_trailStartPts = MathMax(150.0, InpTrailStartPts * scale);
   g_trailDistPts  = MathMax(80.0,  InpTrailDistPts  * scale);
}

//+------------------------------------------------------------------+
void OnTick()
{
   datetime dayStart = iTime(_Symbol, PERIOD_D1, 0);
   if(dayStart == 0)
      return; // daily history not loaded yet

   // first tick of a new day OR first tick after a restart
   if(dayStart != g_dayStart)
   {
      g_dayStart = dayStart;
      if(ActedToday(dayStart))
      {
         // restarted mid-day after already placing/trading: leave everything
         // in place so we never re-add an order that already exists or filled
         g_placedToday = true;
         g_pdh = iHigh(_Symbol, PERIOD_D1, 1);
         g_pdl = iLow(_Symbol, PERIOD_D1, 1);
         RefreshScaledDistances();
         UpdateLevelLine("GBEA_pdh", g_pdh, clrGoldenrod, "Prev Day High");
         UpdateLevelLine("GBEA_pdl", g_pdl, clrCornflowerBlue, "Prev Day Low");
         if(g_buyNote  == "") g_buyNote  = "restored after restart";
         if(g_sellNote == "") g_sellNote = "restored after restart";
      }
      else
      {
         // genuine new day: clear yesterday's unfilled orders, arm at entry hour
         g_placedToday = false;
         DeletePendingOrders();
      }
   }

   // place today's orders once the entry hour is reached
   if(!g_placedToday)
   {
      MqlDateTime dt;
      TimeToStruct(TimeCurrent(), dt);
      if(dt.hour >= InpEntryHour)
      {
         g_placedToday = true;
         PlaceDailyOrders();
      }
   }

   ManageTrailing();

   // refresh the info panel at most every 2 seconds
   static datetime s_lastPanel = 0;
   if(TimeCurrent() - s_lastPanel >= 2)
   {
      s_lastPanel = TimeCurrent();
      UpdatePanel();
   }
}

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   ObjectsDeleteAll(0, "GBEA_");
}

//+------------------------------------------------------------------+
//| Place buy stop at previous day high, sell stop at previous low   |
//+------------------------------------------------------------------+
void PlaceDailyOrders()
{
   double prevHigh = iHigh(_Symbol, PERIOD_D1, 1);
   double prevLow  = iLow(_Symbol, PERIOD_D1, 1);
   if(prevHigh <= 0.0 || prevLow <= 0.0)
      return;

   RefreshScaledDistances();

   g_pdh = prevHigh;
   g_pdl = prevLow;
   UpdateLevelLine("GBEA_pdh", prevHigh, clrGoldenrod, "Prev Day High");
   UpdateLevelLine("GBEA_pdl", prevLow, clrCornflowerBlue, "Prev Day Low");

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

   //--- buy stop at previous day's high
   double entry = NormalizeDouble(prevHigh, _Digits);
   if(entry >= ask + minDist)
   {
      double sl = NormalizeDouble(entry - g_slPts * _Point, _Digits);
      double tp = NormalizeDouble(entry + g_tpPts * _Point, _Digits);
      if(trade.BuyStop(lots, entry, _Symbol, sl, tp, timeType,
                       canExpire ? expiry : 0, "PDH breakout"))
         g_buyNote = "armed";
      else
      {
         g_buyNote = "FAILED: " + trade.ResultRetcodeDescription();
         PrintFormat("BuyStop @%.2f failed: %u %s",
                     entry, trade.ResultRetcode(), trade.ResultRetcodeDescription());
      }
   }
   else
   {
      g_buyNote = "skipped - price opened above level";
      PrintFormat("Buy stop skipped: price already at/above previous day high %.2f (ask %.2f)",
                  prevHigh, ask);
   }

   //--- sell stop at previous day's low
   entry = NormalizeDouble(prevLow, _Digits);
   if(entry <= bid - minDist)
   {
      double sl = NormalizeDouble(entry + g_slPts * _Point, _Digits);
      double tp = NormalizeDouble(entry - g_tpPts * _Point, _Digits);
      if(trade.SellStop(lots, entry, _Symbol, sl, tp, timeType,
                        canExpire ? expiry : 0, "PDL breakout"))
         g_sellNote = "armed";
      else
      {
         g_sellNote = "FAILED: " + trade.ResultRetcodeDescription();
         PrintFormat("SellStop @%.2f failed: %u %s",
                     entry, trade.ResultRetcode(), trade.ResultRetcodeDescription());
      }
   }
   else
   {
      g_sellNote = "skipped - price opened below level";
      PrintFormat("Sell stop skipped: price already at/below previous day low %.2f (bid %.2f)",
                  prevLow, bid);
   }
}

//+------------------------------------------------------------------+
//| Aggressive trailing stop, checked on every tick                  |
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
         newSL = MathMin(newSL, bid - minDist); // respect broker minimum stop distance
         newSL = NormalizeDouble(newSL, _Digits);
         if(curSL == 0.0 || newSL > curSL + _Point / 2.0) // only ever move SL up
            trade.PositionModify(ticket, newSL, tp);
      }
      else // POSITION_TYPE_SELL
      {
         double profitPts = (open - ask) / _Point;
         if(profitPts < g_trailStartPts)
            continue;
         double newSL = ask + g_trailDistPts * _Point;
         newSL = MathMax(newSL, ask + minDist);
         newSL = NormalizeDouble(newSL, _Digits);
         if(curSL == 0.0 || newSL < curSL - _Point / 2.0) // only ever move SL down
            trade.PositionModify(ticket, newSL, tp);
      }
   }
}

//+------------------------------------------------------------------+
//| Delete this EA's unfilled stop orders on this symbol             |
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
//| True if this EA already placed an order or opened a trade today. |
//| Lets the bot stay hands-off after a mid-day restart instead of   |
//| deleting and re-placing (which could double the day's exposure). |
//+------------------------------------------------------------------+
bool ActedToday(datetime dayStart)
{
   // a pending stop order set up today?
   for(int i = OrdersTotal() - 1; i >= 0; i--)
   {
      ulong ticket = OrderGetTicket(i);
      if(ticket == 0 || OrderGetString(ORDER_SYMBOL) != _Symbol)
         continue;
      if(OrderGetInteger(ORDER_MAGIC) != (long)InpMagicNumber)
         continue;
      if((datetime)OrderGetInteger(ORDER_TIME_SETUP) >= dayStart)
         return(true);
   }
   // a position opened today?
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0 || PositionGetString(POSITION_SYMBOL) != _Symbol)
         continue;
      if(PositionGetInteger(POSITION_MAGIC) != (long)InpMagicNumber)
         continue;
      if((datetime)PositionGetInteger(POSITION_TIME) >= dayStart)
         return(true);
   }
   // an entry deal executed today (covers trades already opened AND closed)?
   if(HistorySelect(dayStart, TimeCurrent() + 60))
   {
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
   }
   return(false);
}

//+------------------------------------------------------------------+
//| Fixed lots, or auto lots risking InpRiskPercent of balance       |
//+------------------------------------------------------------------+
double CalcLots()
{
   double lots = InpLotSize;
   double ask  = SymbolInfoDouble(_Symbol, SYMBOL_ASK);

   if(InpAutoLot)
   {
      // exact money lost per 1.0 lot if the SL is hit, using the broker's own
      // calculation (tick-value fields proved unreliable on some feeds)
      double lossPerLot = 0.0;
      if(!OrderCalcProfit(ORDER_TYPE_BUY, _Symbol, 1.0, ask,
                          ask - g_slPts * _Point, lossPerLot) || lossPerLot >= 0.0)
      {
         Print("Auto lot: OrderCalcProfit failed - no orders placed");
         return(0.0);
      }
      double riskPct = InpRiskPercent;
      if(InpRecoveryMode && RecentClosedTradesPL(InpRecentTrades) < 0.0)
         riskPct /= 10.0; // losing streak: keep sampling the market at minimal size
      double riskMoney = AccountInfoDouble(ACCOUNT_BALANCE) * riskPct / 100.0;
      lots = riskMoney / MathAbs(lossPerLot);
   }

   // never request more than 40% of free margin per order (two orders/day)
   double marginPerLot = 0.0;
   if(OrderCalcMargin(ORDER_TYPE_BUY, _Symbol, 1.0, ask, marginPerLot) && marginPerLot > 0.0)
   {
      double maxLots = AccountInfoDouble(ACCOUNT_MARGIN_FREE) * 0.4 / marginPerLot;
      if(lots > maxLots)
      {
         PrintFormat("Lot size %.2f exceeds margin allowance, reduced to %.2f", lots, maxLots);
         lots = maxLots;
      }
   }

   double minLot  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxLot  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double lotStep = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   if(lotStep > 0.0)
      lots = MathFloor(lots / lotStep) * lotStep;
   if(lots < minLot)
      return(0.0); // cannot trade the broker minimum within the risk limit
   lots = MathMin(maxLot, lots);
   return(NormalizeDouble(lots, 2));
}

//+------------------------------------------------------------------+
//| Summed P/L of this EA's last N closed trades on this symbol      |
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
//| Does the broker allow pending orders with a specific expiry?     |
//+------------------------------------------------------------------+
bool CanUseSpecifiedExpiry()
{
   long modes = SymbolInfoInteger(_Symbol, SYMBOL_EXPIRATION_MODE);
   return((modes & SYMBOL_EXPIRATION_SPECIFIED) != 0);
}

//+------------------------------------------------------------------+
//| Horizontal line marking an order level                           |
//+------------------------------------------------------------------+
void UpdateLevelLine(string name, double price, color clr, string text)
{
   if(!InpShowPanel)
      return;
   if(ObjectFind(0, name) < 0)
   {
      ObjectCreate(0, name, OBJ_HLINE, 0, 0, price);
      ObjectSetInteger(0, name, OBJPROP_STYLE, STYLE_DOT);
      ObjectSetInteger(0, name, OBJPROP_WIDTH, 1);
      ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
      ObjectSetInteger(0, name, OBJPROP_BACK, true);
   }
   ObjectSetInteger(0, name, OBJPROP_COLOR, clr);
   ObjectSetDouble(0, name, OBJPROP_PRICE, price);
   ObjectSetString(0, name, OBJPROP_TEXT, text + " " + DoubleToString(price, _Digits));
}

//+------------------------------------------------------------------+
//| One text row of the info panel                                   |
//+------------------------------------------------------------------+
void PanelRow(string name, int y, string text, color clr)
{
   string obj = "GBEA_" + name;
   if(ObjectFind(0, obj) < 0)
   {
      ObjectCreate(0, obj, OBJ_LABEL, 0, 0, 0);
      ObjectSetInteger(0, obj, OBJPROP_CORNER, CORNER_LEFT_UPPER);
      ObjectSetInteger(0, obj, OBJPROP_XDISTANCE, 14);
      ObjectSetInteger(0, obj, OBJPROP_YDISTANCE, y);
      ObjectSetString(0, obj, OBJPROP_FONT, "Consolas");
      ObjectSetInteger(0, obj, OBJPROP_FONTSIZE, 9);
      ObjectSetInteger(0, obj, OBJPROP_SELECTABLE, false);
      ObjectSetInteger(0, obj, OBJPROP_HIDDEN, true);
   }
   ObjectSetInteger(0, obj, OBJPROP_COLOR, clr);
   ObjectSetString(0, obj, OBJPROP_TEXT, text);
}

//+------------------------------------------------------------------+
//| Today's trading session of the symbol, e.g. "01:05 - 23:55"      |
//+------------------------------------------------------------------+
string TodaySessionText()
{
   MqlDateTime dt;
   TimeToStruct(TimeTradeServer(), dt);
   datetime from = 0, to = 0;
   if(!SymbolInfoSessionTrade(_Symbol, (ENUM_DAY_OF_WEEK)dt.day_of_week, 0, from, to))
      return("closed today");
   return(TimeToString(from, TIME_MINUTES) + " - " + TimeToString(to, TIME_MINUTES));
}

//+------------------------------------------------------------------+
//| Info panel                                                       |
//+------------------------------------------------------------------+
void UpdatePanel()
{
   if(!InpShowPanel)
      return;
   if(MQLInfoInteger(MQL_TESTER) && !MQLInfoInteger(MQL_VISUAL_MODE))
      return; // nothing to draw in a non-visual backtest

   //--- background
   string bg = "GBEA_bg";
   if(ObjectFind(0, bg) < 0)
   {
      ObjectCreate(0, bg, OBJ_RECTANGLE_LABEL, 0, 0, 0);
      ObjectSetInteger(0, bg, OBJPROP_CORNER, CORNER_LEFT_UPPER);
      ObjectSetInteger(0, bg, OBJPROP_XDISTANCE, 6);
      ObjectSetInteger(0, bg, OBJPROP_YDISTANCE, 18);
      ObjectSetInteger(0, bg, OBJPROP_XSIZE, 340);
      ObjectSetInteger(0, bg, OBJPROP_YSIZE, 212);
      ObjectSetInteger(0, bg, OBJPROP_BGCOLOR, C'18,22,30');
      ObjectSetInteger(0, bg, OBJPROP_BORDER_TYPE, BORDER_FLAT);
      ObjectSetInteger(0, bg, OBJPROP_COLOR, C'80,90,110');
      ObjectSetInteger(0, bg, OBJPROP_SELECTABLE, false);
      ObjectSetInteger(0, bg, OBJPROP_HIDDEN, true);
   }

   //--- live state: pending orders and open positions of this EA
   bool buyArmed = false, sellArmed = false;
   for(int i = OrdersTotal() - 1; i >= 0; i--)
   {
      ulong ticket = OrderGetTicket(i);
      if(ticket == 0 || OrderGetString(ORDER_SYMBOL) != _Symbol)
         continue;
      if(OrderGetInteger(ORDER_MAGIC) != (long)InpMagicNumber)
         continue;
      long type = OrderGetInteger(ORDER_TYPE);
      if(type == ORDER_TYPE_BUY_STOP)  buyArmed = true;
      if(type == ORDER_TYPE_SELL_STOP) sellArmed = true;
   }
   int    nLong = 0, nShort = 0;
   double floating = 0.0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0 || PositionGetString(POSITION_SYMBOL) != _Symbol)
         continue;
      if(PositionGetInteger(POSITION_MAGIC) != (long)InpMagicNumber)
         continue;
      floating += PositionGetDouble(POSITION_PROFIT);
      if(PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY) nLong++;
      else nShort++;
   }

   //--- side status lines
   string buyTxt, sellTxt;
   if(!g_placedToday)
   {
      buyTxt  = StringFormat("waiting for %02d:00 server", InpEntryHour);
      sellTxt = buyTxt;
   }
   else
   {
      buyTxt  = buyArmed  ? "ARMED  @ " + DoubleToString(g_pdh, _Digits)
              : (nLong  > 0 ? "TRIGGERED - position open" : g_buyNote);
      sellTxt = sellArmed ? "ARMED  @ " + DoubleToString(g_pdl, _Digits)
              : (nShort > 0 ? "TRIGGERED - position open" : g_sellNote);
      if(buyTxt == "armed")  buyTxt  = "filled or expired";
      if(sellTxt == "armed") sellTxt = "filled or expired";
   }

   //--- risk mode
   double recentPL  = RecentClosedTradesPL(InpRecentTrades);
   bool   recovery  = InpRecoveryMode && recentPL < 0.0;
   double nextLots  = CalcLots();

   color hd  = clrGold;
   color txt = clrWhiteSmoke;
   color dim = clrSilver;
   int   y   = 24;

   PanelRow("title", y, "GOLD BREAKOUT EA  v1.40", hd);                                     y += 18;
   PanelRow("time",  y, "Server " + TimeToString(TimeTradeServer(), TIME_DATE|TIME_MINUTES)
                       + "   Session " + TodaySessionText(), dim);                          y += 18;
   PanelRow("pdh",   y, StringFormat("Prev Day High : %s", g_pdh > 0 ?
                       DoubleToString(g_pdh, _Digits) : "..."), txt);                       y += 16;
   PanelRow("pdl",   y, StringFormat("Prev Day Low  : %s", g_pdl > 0 ?
                       DoubleToString(g_pdl, _Digits) : "..."), txt);                       y += 18;
   PanelRow("buy",   y, "Buy stop  : " + buyTxt,
                       buyArmed ? clrLimeGreen : (nLong  > 0 ? clrAqua : dim));             y += 16;
   PanelRow("sell",  y, "Sell stop : " + sellTxt,
                       sellArmed ? clrOrangeRed : (nShort > 0 ? clrAqua : dim));            y += 18;
   PanelRow("dist",  y, StringFormat("SL %.0f  TP %.0f  Trail %.0f/%.0f pts",
                       g_slPts, g_tpPts, g_trailStartPts, g_trailDistPts), txt);            y += 16;
   PanelRow("atr",   y, StringFormat("ATR scale x%.2f  (ref %.0f pts)",
                       g_atrScale, InpAtrRefPts), dim);                                     y += 18;
   PanelRow("risk",  y, recovery
                       ? StringFormat("Risk: RECOVERY %.2f%%  (last %d: %.0f)",
                                      InpRiskPercent / 10.0, InpRecentTrades, recentPL)
                       : StringFormat("Risk: NORMAL %.1f%%  (last %d: %+.0f)",
                                      InpRiskPercent, InpRecentTrades, recentPL),
                       recovery ? clrOrange : clrLimeGreen);                                y += 16;
   PanelRow("lots",  y, StringFormat("Next order size: %.2f lots", nextLots), txt);        y += 18;
   PanelRow("pos",   y, StringFormat("Positions: %d long, %d short   P/L %+.2f",
                       nLong, nShort, floating), nLong + nShort > 0 ? clrAqua : dim);       y += 16;
   PanelRow("acct",  y, StringFormat("Balance %.2f   Equity %.2f",
                       AccountInfoDouble(ACCOUNT_BALANCE),
                       AccountInfoDouble(ACCOUNT_EQUITY)), txt);

   ChartRedraw();
}
//+------------------------------------------------------------------+
