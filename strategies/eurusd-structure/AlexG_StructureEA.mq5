//+------------------------------------------------------------------+
//|                                          AlexG_StructureEA.mq5   |
//|  EURUSD H4 swing strategy in the style of Alex Gonzalez /        |
//|  "Swing Trading Lab" (set-and-forget, top-down structure).      |
//|                                                                  |
//|  His method is DISCRETIONARY price action. This EA mechanizes    |
//|  its skeleton faithfully, replacing each judgement call with the |
//|  closest measurable rule (noted below):                          |
//|                                                                  |
//|   1. TOP-DOWN BIAS (his "two timeframes must agree")             |
//|      - Higher TF (Daily): close above/below its EMA => bias      |
//|      - Trade TF (H4): close above/below its trend EMA            |
//|      Only trade when BOTH agree (long: both up; short: both down)|
//|                                                                  |
//|   2. AREA OF INTEREST (his "buy weakness into structure")        |
//|      - Price must pull back into the H4 pullback-EMA zone within |
//|        the last InpPullbackBars bars (value, not extended)       |
//|                                                                  |
//|   3. SHIFT OF STRUCTURE (his entry trigger at the AOI)           |
//|      - Long: H4 closes above the recent swing high (breaks the   |
//|        pullback's lower-high => momentum resuming with trend)    |
//|                                                                  |
//|   4. STOP = logical invalidation (below pullback swing low)      |
//|   5. TARGET = fixed reward:risk (his R-multiple focus), with an  |
//|      optional move to breakeven at +1R (his "bank & de-risk")    |
//|   6. RISK 0.5% default (his 0.25-1% range), auto-sized.          |
//|                                                                  |
//|  Reused validated framework: OrderCalcProfit sizing + margin     |
//|  cap, recovery mode, one position at a time, evaluate on the     |
//|  H4 bar close only.                                              |
//+------------------------------------------------------------------+
#property copyright   "Jerry"
#property version     "1.00"
#property description "EURUSD H4 top-down structure swing (Alex Gonzalez style): bias + pullback to AOI + structure-break entry, fixed R:R."

#include <Trade\Trade.mqh>

input ENUM_TIMEFRAMES InpBiasTF        = PERIOD_D1;   // Higher timeframe for bias
input int             InpBiasEma       = 50;          // Bias EMA on the higher TF
input int             InpTrendEma      = 200;         // Trend EMA on H4
input int             InpAoiEma        = 50;          // Pullback / area-of-interest EMA on H4
input double          InpAoiDistPips   = 18;          // Pullback must reach within this of the AOI EMA
input int             InpPullbackBars  = 6;           // Look-back for the pullback touch (H4 bars)
input int             InpBosLookback   = 4;           // Recent swing high/low to break for entry
input int             InpSlLookback    = 6;           // Swing low/high for the stop
input double          InpSlBufferPips  = 6;           // Extra buffer beyond the swing
input double          InpRewardR       = 2.0;         // Take profit as a multiple of risk
input bool            InpBreakevenAt1R = true;        // Move stop to breakeven at +1R
input double          InpRiskPercent   = 0.5;         // Risk % of balance per trade
input bool            InpRecoveryMode  = true;        // 1/10 size while last N trades net negative
input int             InpRecentTrades  = 10;          // N recent trades for recovery mode
input ulong           InpMagicNumber   = 20260717;    // Magic Number

CTrade   trade;
int      g_hBias = INVALID_HANDLE, g_hTrend = INVALID_HANDLE, g_hAoi = INVALID_HANDLE;
datetime g_lastBar = 0;
double   g_pip = 0.0001;

//+------------------------------------------------------------------+
int OnInit()
{
   trade.SetExpertMagicNumber(InpMagicNumber);
   trade.SetTypeFillingBySymbol(_Symbol);
   trade.SetDeviationInPoints(20);

   g_hBias  = iMA(_Symbol, InpBiasTF, InpBiasEma, 0, MODE_EMA, PRICE_CLOSE);
   g_hTrend = iMA(_Symbol, PERIOD_H4, InpTrendEma, 0, MODE_EMA, PRICE_CLOSE);
   g_hAoi   = iMA(_Symbol, PERIOD_H4, InpAoiEma,   0, MODE_EMA, PRICE_CLOSE);
   if(g_hBias == INVALID_HANDLE || g_hTrend == INVALID_HANDLE || g_hAoi == INVALID_HANDLE)
      return(INIT_FAILED);

   int d = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   g_pip = (d == 3 || d == 5) ? 10 * _Point : _Point;
   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
void OnTick()
{
   if(HasPosition())
      ManagePosition();

   // act only on a fresh H4 bar
   datetime bar = iTime(_Symbol, PERIOD_H4, 0);
   if(bar == 0 || bar == g_lastBar)
      return;
   g_lastBar = bar;

   if(HasPosition())
      return;                      // one position at a time (set-and-forget)

   EvaluateEntry();
}

//+------------------------------------------------------------------+
double EmaVal(int handle, int shift)
{
   double b[1];
   if(CopyBuffer(handle, 0, shift, 1, b) != 1)
      return(0.0);
   return(b[0]);
}

//+------------------------------------------------------------------+
//| Top-down bias + pullback + structure break                       |
//+------------------------------------------------------------------+
void EvaluateEntry()
{
   double bias  = EmaVal(g_hBias, 0);
   double biasP = iClose(_Symbol, InpBiasTF, 0);
   double trend = EmaVal(g_hTrend, 1);
   double aoi   = EmaVal(g_hAoi, 1);
   double c1    = iClose(_Symbol, PERIOD_H4, 1);
   if(bias <= 0.0 || trend <= 0.0 || aoi <= 0.0 || c1 <= 0.0)
      return;

   bool biasUp = biasP > bias;
   bool biasDn = biasP < bias;
   bool trendUp = c1 > trend;
   bool trendDn = c1 < trend;

   // ---- LONG: Daily up + H4 up + pulled back to AOI + breaks recent high
   if(biasUp && trendUp)
   {
      bool pulled = false;
      for(int i = 1; i <= InpPullbackBars; i++)
         if(iLow(_Symbol, PERIOD_H4, i) <= aoi + InpAoiDistPips * g_pip)
            { pulled = true; break; }

      double recentHigh = 0.0;   // highest high of bars 2..(BosLookback+1)
      for(int i = 2; i <= InpBosLookback + 1; i++)
         recentHigh = MathMax(recentHigh, iHigh(_Symbol, PERIOD_H4, i));

      if(pulled && c1 > recentHigh)
      {
         double swingLow = iLow(_Symbol, PERIOD_H4, 1);
         for(int i = 1; i <= InpSlLookback; i++)
            swingLow = MathMin(swingLow, iLow(_Symbol, PERIOD_H4, i));
         double sl = swingLow - InpSlBufferPips * g_pip;
         Enter(1, sl);
      }
   }
   // ---- SHORT: mirror
   else if(biasDn && trendDn)
   {
      bool pulled = false;
      for(int i = 1; i <= InpPullbackBars; i++)
         if(iHigh(_Symbol, PERIOD_H4, i) >= aoi - InpAoiDistPips * g_pip)
            { pulled = true; break; }

      double recentLow = DBL_MAX;
      for(int i = 2; i <= InpBosLookback + 1; i++)
         recentLow = MathMin(recentLow, iLow(_Symbol, PERIOD_H4, i));

      if(pulled && c1 < recentLow)
      {
         double swingHigh = iHigh(_Symbol, PERIOD_H4, 1);
         for(int i = 1; i <= InpSlLookback; i++)
            swingHigh = MathMax(swingHigh, iHigh(_Symbol, PERIOD_H4, i));
         double sl = swingHigh + InpSlBufferPips * g_pip;
         Enter(-1, sl);
      }
   }
}

//+------------------------------------------------------------------+
void Enter(int dir, double sl)
{
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double price = (dir > 0) ? ask : bid;
   double risk  = MathAbs(price - sl);
   if(risk < 5 * g_pip)          // sanity: stop too tight / bad data
      return;
   double tp = (dir > 0) ? price + InpRewardR * risk : price - InpRewardR * risk;
   sl = NormalizeDouble(sl, _Digits);
   tp = NormalizeDouble(tp, _Digits);

   double lots = CalcLots(price, sl, dir);
   if(lots <= 0.0)
      return;
   bool ok = (dir > 0) ? trade.Buy(lots, _Symbol, 0.0, sl, tp, "AlexG")
                       : trade.Sell(lots, _Symbol, 0.0, sl, tp, "AlexG");
   if(!ok)
      PrintFormat("Entry failed: %u %s", trade.ResultRetcode(),
                  trade.ResultRetcodeDescription());
}

//+------------------------------------------------------------------+
//| Move stop to breakeven once price reaches +1R                    |
//+------------------------------------------------------------------+
void ManagePosition()
{
   if(!InpBreakevenAt1R)
      return;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0 || PositionGetString(POSITION_SYMBOL) != _Symbol)
         continue;
      if(PositionGetInteger(POSITION_MAGIC) != (long)InpMagicNumber)
         continue;

      long   type = PositionGetInteger(POSITION_TYPE);
      double open = PositionGetDouble(POSITION_PRICE_OPEN);
      double sl   = PositionGetDouble(POSITION_SL);
      double tp   = PositionGetDouble(POSITION_TP);
      double bid  = SymbolInfoDouble(_Symbol, SYMBOL_BID);
      double ask  = SymbolInfoDouble(_Symbol, SYMBOL_ASK);

      if(type == POSITION_TYPE_BUY)
      {
         double r = open - sl;
         if(r > 0 && bid >= open + r && sl < open)
            trade.PositionModify(ticket, NormalizeDouble(open + 1 * g_pip, _Digits), tp);
      }
      else
      {
         double r = sl - open;
         if(r > 0 && ask <= open - r && sl > open)
            trade.PositionModify(ticket, NormalizeDouble(open - 1 * g_pip, _Digits), tp);
      }
   }
}

//+------------------------------------------------------------------+
bool HasPosition()
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
