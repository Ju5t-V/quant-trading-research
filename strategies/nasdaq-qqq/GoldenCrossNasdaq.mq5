//+------------------------------------------------------------------+
//|                                        GoldenCrossNasdaq.mq5     |
//|  Golden Cross trend following for Nasdaq 100 (index CFD or ETF)  |
//|                                                                  |
//|  Checked once per day on the first tick of the new daily bar,    |
//|  using only completed bars (same as acting at the next open):    |
//|    - hold a long position while SMA(fast) > SMA(slow)            |
//|    - be flat while SMA(fast) < SMA(slow)                         |
//|  Position size: InpInvestFrac of equity as notional, no leverage.|
//+------------------------------------------------------------------+
#property copyright "Jerry"
#property version   "1.00"

#include <Trade\Trade.mqh>

input int    InpFastMA     = 50;       // Fast SMA (days)
input int    InpSlowMA     = 200;      // Slow SMA (days)
input double InpInvestFrac = 0.95;     // Fraction of equity invested
input ulong  InpMagic      = 20260711; // Magic Number

CTrade   trade;
int      g_hFast = INVALID_HANDLE, g_hSlow = INVALID_HANDLE;
datetime g_lastBar = 0;

//+------------------------------------------------------------------+
int OnInit()
{
   trade.SetExpertMagicNumber(InpMagic);
   trade.SetTypeFillingBySymbol(_Symbol);
   g_hFast = iMA(_Symbol, PERIOD_D1, InpFastMA, 0, MODE_SMA, PRICE_CLOSE);
   g_hSlow = iMA(_Symbol, PERIOD_D1, InpSlowMA, 0, MODE_SMA, PRICE_CLOSE);
   if(g_hFast == INVALID_HANDLE || g_hSlow == INVALID_HANDLE)
      return(INIT_FAILED);
   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
void OnTick()
{
   datetime bar = iTime(_Symbol, PERIOD_D1, 0);
   if(bar == 0 || bar == g_lastBar)
      return;

   // values of the completed daily bars (never the still-forming one)
   double f[1], s[1];
   if(CopyBuffer(g_hFast, 0, 1, 1, f) != 1 || CopyBuffer(g_hSlow, 0, 1, 1, s) != 1)
      return; // not enough history yet - try again next tick
   if(f[0] <= 0.0 || s[0] <= 0.0)
      return;

   g_lastBar = bar;
   bool bull  = f[0] > s[0];
   bool inPos = HasPosition();

   if(bull && !inPos)
   {
      double vol = CalcVolume();
      if(vol > 0.0 && !trade.Buy(vol, _Symbol))
         PrintFormat("Buy failed: %u %s", trade.ResultRetcode(),
                     trade.ResultRetcodeDescription());
   }
   else if(!bull && inPos)
      CloseAll();
}

//+------------------------------------------------------------------+
bool HasPosition()
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0 || PositionGetString(POSITION_SYMBOL) != _Symbol)
         continue;
      if(PositionGetInteger(POSITION_MAGIC) == (long)InpMagic)
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
      if(PositionGetInteger(POSITION_MAGIC) == (long)InpMagic)
         trade.PositionClose(ticket);
   }
}

//+------------------------------------------------------------------+
//| Volume worth InpInvestFrac of equity in notional (no leverage)   |
//+------------------------------------------------------------------+
double CalcVolume()
{
   double price    = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double contract = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_CONTRACT_SIZE);
   if(price <= 0.0 || contract <= 0.0)
      return(0.0);
   double vol = AccountInfoDouble(ACCOUNT_EQUITY) * InpInvestFrac / (price * contract);

   double vmin  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double vmax  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double vstep = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   if(vstep > 0.0)
      vol = MathFloor(vol / vstep) * vstep;
   if(vol < vmin)
   {
      Print("Equity too small for the minimum volume - staying flat");
      return(0.0);
   }
   return(MathMin(vol, vmax));
}
//+------------------------------------------------------------------+
