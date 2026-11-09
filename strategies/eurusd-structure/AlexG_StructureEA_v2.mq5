//+------------------------------------------------------------------+
//|                                       AlexG_StructureEA_v2.mq5   |
//|  Rescue attempt — two faithfulness fixes vs v1:                  |
//|   1. Breakeven-at-1R REMOVED (it capped winners into scratches). |
//|   2. Fixed 2R target REPLACED with a structure trailing exit:    |
//|      hold the runner, ratchet the stop under the most recent     |
//|      swing low (long) / over the swing high (short), exit when    |
//|      structure breaks. This is what Alex actually does           |
//|      ("bank a third, hold the runner until structure breaks").   |
//|                                                                  |
//|  Everything else identical to v1: Daily+H4 bias must agree,      |
//|  pullback into the H4 AOI EMA, entry on the structure break,     |
//|  initial stop beyond the pullback swing, 0.5% risk auto-sized,   |
//|  recovery mode, one position at a time.                          |
//+------------------------------------------------------------------+
#property copyright   "Jerry"
#property version     "2.00"
#property description "AlexG EURUSD H4 - rescue build: no breakeven, structure trailing exit (hold the runner)."

#include <Trade\Trade.mqh>

input ENUM_TIMEFRAMES InpBiasTF        = PERIOD_D1;
input int             InpBiasEma       = 50;
input int             InpTrendEma      = 200;
input int             InpAoiEma        = 50;
input double          InpAoiDistPips   = 18;
input int             InpPullbackBars  = 6;
input int             InpBosLookback   = 4;
input int             InpSlLookback    = 6;
input double          InpSlBufferPips  = 6;
input bool            InpUseFixedTP    = false;   // false = structure trail (rescue), true = old fixed 2R
input double          InpRewardR       = 2.0;     // used only if InpUseFixedTP
input int             InpTrailSwingBars= 6;       // trail stop under lowest low of this many H4 bars
input double          InpRiskPercent   = 0.5;
input bool            InpRecoveryMode  = true;
input int             InpRecentTrades  = 10;
input ulong           InpMagicNumber   = 20260718;

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
      TrailStructure();

   datetime bar = iTime(_Symbol, PERIOD_H4, 0);
   if(bar == 0 || bar == g_lastBar)
      return;
   g_lastBar = bar;

   if(HasPosition())
      return;
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
void EvaluateEntry()
{
   double bias  = EmaVal(g_hBias, 0);
   double biasP = iClose(_Symbol, InpBiasTF, 0);
   double trend = EmaVal(g_hTrend, 1);
   double aoi   = EmaVal(g_hAoi, 1);
   double c1    = iClose(_Symbol, PERIOD_H4, 1);
   if(bias <= 0.0 || trend <= 0.0 || aoi <= 0.0 || c1 <= 0.0)
      return;

   bool biasUp = biasP > bias, biasDn = biasP < bias;
   bool trendUp = c1 > trend,  trendDn = c1 < trend;

   if(biasUp && trendUp)
   {
      bool pulled = false;
      for(int i = 1; i <= InpPullbackBars; i++)
         if(iLow(_Symbol, PERIOD_H4, i) <= aoi + InpAoiDistPips * g_pip) { pulled = true; break; }
      double recentHigh = 0.0;
      for(int i = 2; i <= InpBosLookback + 1; i++)
         recentHigh = MathMax(recentHigh, iHigh(_Symbol, PERIOD_H4, i));
      if(pulled && c1 > recentHigh)
      {
         double swingLow = iLow(_Symbol, PERIOD_H4, 1);
         for(int i = 1; i <= InpSlLookback; i++)
            swingLow = MathMin(swingLow, iLow(_Symbol, PERIOD_H4, i));
         Enter(1, swingLow - InpSlBufferPips * g_pip);
      }
   }
   else if(biasDn && trendDn)
   {
      bool pulled = false;
      for(int i = 1; i <= InpPullbackBars; i++)
         if(iHigh(_Symbol, PERIOD_H4, i) >= aoi - InpAoiDistPips * g_pip) { pulled = true; break; }
      double recentLow = DBL_MAX;
      for(int i = 2; i <= InpBosLookback + 1; i++)
         recentLow = MathMin(recentLow, iLow(_Symbol, PERIOD_H4, i));
      if(pulled && c1 < recentLow)
      {
         double swingHigh = iHigh(_Symbol, PERIOD_H4, 1);
         for(int i = 1; i <= InpSlLookback; i++)
            swingHigh = MathMax(swingHigh, iHigh(_Symbol, PERIOD_H4, i));
         Enter(-1, swingHigh + InpSlBufferPips * g_pip);
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
   if(risk < 5 * g_pip)
      return;
   double tp = 0.0;
   if(InpUseFixedTP)
      tp = NormalizeDouble((dir > 0) ? price + InpRewardR * risk : price - InpRewardR * risk, _Digits);
   sl = NormalizeDouble(sl, _Digits);

   double lots = CalcLots(price, sl, dir);
   if(lots <= 0.0)
      return;
   bool ok = (dir > 0) ? trade.Buy(lots, _Symbol, 0.0, sl, tp, "AlexG2")
                       : trade.Sell(lots, _Symbol, 0.0, sl, tp, "AlexG2");
   if(!ok)
      PrintFormat("Entry failed: %u %s", trade.ResultRetcode(), trade.ResultRetcodeDescription());
}

//+------------------------------------------------------------------+
//| Structure trailing exit: ratchet stop under recent swing         |
//+------------------------------------------------------------------+
void TrailStructure()
{
   double minDist = (double)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL) * _Point;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0 || PositionGetString(POSITION_SYMBOL) != _Symbol)
         continue;
      if(PositionGetInteger(POSITION_MAGIC) != (long)InpMagicNumber)
         continue;

      long   type = PositionGetInteger(POSITION_TYPE);
      double sl   = PositionGetDouble(POSITION_SL);
      double tp   = PositionGetDouble(POSITION_TP);
      double bid  = SymbolInfoDouble(_Symbol, SYMBOL_BID);
      double ask  = SymbolInfoDouble(_Symbol, SYMBOL_ASK);

      if(type == POSITION_TYPE_BUY)
      {
         double swing = iLow(_Symbol, PERIOD_H4, 1);
         for(int k = 1; k <= InpTrailSwingBars; k++)
            swing = MathMin(swing, iLow(_Symbol, PERIOD_H4, k));
         double newSL = NormalizeDouble(swing - InpSlBufferPips * g_pip, _Digits);
         if(newSL > sl + _Point / 2.0 && newSL < bid - minDist)
            trade.PositionModify(ticket, newSL, tp);
      }
      else
      {
         double swing = iHigh(_Symbol, PERIOD_H4, 1);
         for(int k = 1; k <= InpTrailSwingBars; k++)
            swing = MathMax(swing, iHigh(_Symbol, PERIOD_H4, k));
         double newSL = NormalizeDouble(swing + InpSlBufferPips * g_pip, _Digits);
         if((sl == 0.0 || newSL < sl - _Point / 2.0) && newSL > ask + minDist)
            trade.PositionModify(ticket, newSL, tp);
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
      if(t == 0) continue;
      if(HistoryDealGetInteger(t, DEAL_MAGIC) != (long)InpMagicNumber) continue;
      if(HistoryDealGetString(t, DEAL_SYMBOL) != _Symbol) continue;
      if(HistoryDealGetInteger(t, DEAL_ENTRY) != DEAL_ENTRY_OUT) continue;
      sum += HistoryDealGetDouble(t, DEAL_PROFIT) + HistoryDealGetDouble(t, DEAL_SWAP)
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
      if(lots > maxLots) lots = maxLots;
   }
   double vmin  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double vmax  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double vstep = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   if(vstep > 0.0) lots = MathFloor(lots / vstep) * vstep;
   if(lots < vmin) return(0.0);
   return(NormalizeDouble(MathMin(lots, vmax), 2));
}
//+------------------------------------------------------------------+
