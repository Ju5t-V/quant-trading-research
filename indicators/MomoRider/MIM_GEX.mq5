//+------------------------------------------------------------------+
//|  MIM_GEX.mq5                                                     |
//|  Market Intraday Momentum, gated on dealer Gamma Exposure        |
//|                                                                  |
//|  RESEARCH BASIS                                                  |
//|   Baltussen, Da, Lammers & Martens (2021), "Hedging demand and   |
//|   market intraday momentum", Journal of Financial Economics      |
//|   142:377-403.  The last 30 minutes before the cash close is     |
//|   predicted by the return from the previous close up to that     |
//|   point (r_ROD). 60+ futures, 1974-2020, Sharpe 0.87-1.73.       |
//|                                                                  |
//|   Their Table 7 is the important part - the effect is CONDITIONAL |
//|   on dealer gamma:                                               |
//|       NGE >= 0 (dealers long gamma):  beta 0.82, t=1.03  (none)  |
//|       NGE <  0 (dealers short gamma): beta 6.63, t=4.78          |
//|                                                                  |
//|   Dim, Eraker & Vilkov (2025), "0DTEs: Trading, Gamma Risk and   |
//|   Volatility Propagation": positive dealer gamma strengthens     |
//|   intraday REVERSAL, negative gamma strengthens MOMENTUM.        |
//|                                                                  |
//|  STATUS - READ THIS                                              |
//|   I replicated the UNCONDITIONAL effect on MT5 index CFDs        |
//|   2015-2026 (US500/US30/DAX/FRA40/ESP35):                        |
//|       2015-2019  t=3.18   0.45 bp/day  (below cost)              |
//|       2020-2022  t=5.85   2.00 bp/day  (tradable)                |
//|       2023-2026  t=1.38   0.02 bp/day  (DEAD)                    |
//|   A realised-vol proxy for gamma worked beautifully pre-2022     |
//|   (extreme-vol days paid 7.97 bp) and is also dead post-2022.    |
//|   That is consistent with 0DTE: dealer gamma now resets intraday  |
//|   and vol no longer proxies it. So this indicator needs the REAL  |
//|   GEX number, supplied by gex.py. The GEX-gated version is NOT   |
//|   something I could backtest - free historical option OI is not  |
//|   available. Forward-test it before risking size.                |
//+------------------------------------------------------------------+
#property copyright "MomoRider research"
#property version   "1.00"
#property indicator_chart_window
#property indicator_buffers 2
#property indicator_plots   2

#property indicator_label1  "Long signal"
#property indicator_type1   DRAW_ARROW
#property indicator_color1  clrLimeGreen
#property indicator_width1  3
#property indicator_label2  "Short signal"
#property indicator_type2   DRAW_ARROW
#property indicator_color2  clrOrangeRed
#property indicator_width2  3

input int    InpCloseHour     = 23;    // Cash-close HOUR in SERVER time
input int    InpCloseMinute   = 0;     // Cash-close MINUTE in server time
input int    InpWindowMin     = 30;    // Length of the entry window (min)
input double InpMinMovePct    = 0.15;  // Minimum |r_ROD| to act on (%)
input int    InpAtrPeriod     = 14;    // ATR period for SL/TP
input double InpSL_ATR        = 1.0;   // Stop  = x ATR
input double InpTP_ATR        = 1.5;   // Target = x ATR
input string InpGexFile       = "gex_regime.csv"; // written by gex.py into MQL5/Files
input bool   InpRequireGex    = true;  // if false, assume MOMENTUM regime
input bool   InpShowPanel     = true;

double BufUp[], BufDn[];
int    hATR;
double g_gex        = 0.0;
string g_gexTicker  = "";
datetime g_gexTime  = 0;
bool   g_gexOK      = false;

//+------------------------------------------------------------------+
int OnInit()
  {
   SetIndexBuffer(0, BufUp, INDICATOR_DATA);
   SetIndexBuffer(1, BufDn, INDICATOR_DATA);
   PlotIndexSetInteger(0, PLOT_ARROW, 233);
   PlotIndexSetInteger(1, PLOT_ARROW, 234);
   PlotIndexSetDouble(0, PLOT_EMPTY_VALUE, EMPTY_VALUE);
   PlotIndexSetDouble(1, PLOT_EMPTY_VALUE, EMPTY_VALUE);
   ArraySetAsSeries(BufUp, false);
   ArraySetAsSeries(BufDn, false);
   hATR = iATR(_Symbol, _Period, InpAtrPeriod);
   if(hATR == INVALID_HANDLE) { Print("ATR handle failed"); return(INIT_FAILED); }
   IndicatorSetString(INDICATOR_SHORTNAME, "MIM+GEX");
   return(INIT_SUCCEEDED);
  }

void OnDeinit(const int reason) { ObjectsDeleteAll(0, "MIMGEX_"); }

//+------------------------------------------------------------------+
//| Read the GEX regime file written by gex.py                       |
//| format: ticker,iso_utc_time,gex_value                            |
//+------------------------------------------------------------------+
bool ReadGex()
  {
   int h = FileOpen(InpGexFile, FILE_READ|FILE_CSV|FILE_ANSI|FILE_COMMON, ',');
   if(h == INVALID_HANDLE)
      h = FileOpen(InpGexFile, FILE_READ|FILE_CSV|FILE_ANSI, ',');
   if(h == INVALID_HANDLE) return(false);
   bool ok = false;
   while(!FileIsEnding(h))
     {
      string t = FileReadString(h);
      if(FileIsEnding(h)) break;
      string ts = FileReadString(h);
      string gv = FileReadString(h);
      if(StringLen(t) == 0) continue;
      if(t == "ticker") continue;              // header
      g_gexTicker = t;
      g_gex       = StringToDouble(gv);
      g_gexTime   = StringToTime(ts);
      ok = true;
     }
   FileClose(h);
   return(ok);
  }

//+------------------------------------------------------------------+
int OnCalculate(const int rates_total, const int prev_calculated,
                const datetime &time[], const double &open[],
                const double &high[], const double &low[],
                const double &close[], const long &tick_volume[],
                const long &volume[], const int &spread[])
  {
   if(rates_total < 100) return(0);
   g_gexOK = ReadGex();

   double atr[];
   ArraySetAsSeries(atr, false);
   if(CopyBuffer(hATR, 0, 0, rates_total, atr) <= 0) return(0);

   int start = (prev_calculated > 1) ? prev_calculated - 2 : InpAtrPeriod + 2;
   if(start < 2) start = 2;

   int entryMin = InpCloseHour * 60 + InpCloseMinute - InpWindowMin;

   for(int i = start; i < rates_total; i++)
     {
      BufUp[i] = EMPTY_VALUE;
      BufDn[i] = EMPTY_VALUE;

      MqlDateTime dt;
      TimeToStruct(time[i], dt);
      int minOfDay = dt.hour * 60 + dt.min;
      if(minOfDay != entryMin) continue;        // only the entry bar

      // previous session's close = close of the bar that ENDED the last window
      double prevClose = 0.0;
      for(int j = i - 1; j >= 1; j--)
        {
         MqlDateTime d2; TimeToStruct(time[j], d2);
         if(d2.hour * 60 + d2.min == entryMin) { prevClose = close[j]; break; }
        }
      if(prevClose <= 0.0) continue;

      double rod = (open[i] / prevClose - 1.0) * 100.0;   // rest-of-day return, %
      if(MathAbs(rod) < InpMinMovePct) continue;

      // ---- gamma regime -------------------------------------------------
      // GEX < 0 : dealers short gamma -> hedge WITH the move -> MOMENTUM
      // GEX > 0 : dealers long  gamma -> hedge AGAINST      -> REVERSAL
      int dir;                                   // +1 long, -1 short
      if(g_gexOK)      dir = (g_gex < 0.0) ?  (rod > 0 ? 1 : -1) : (rod > 0 ? -1 : 1);
      else if(!InpRequireGex) dir = (rod > 0 ? 1 : -1);
      else             continue;                 // no GEX file -> stand aside

      double a = atr[i];
      if(a <= 0.0) continue;

      if(dir > 0) BufUp[i] = low[i]  - 0.5 * a;
      else        BufDn[i] = high[i] + 0.5 * a;

      // ---- draw the SL / TP for this signal ------------------------------
      double entry = open[i];
      double sl = (dir > 0) ? entry - InpSL_ATR * a : entry + InpSL_ATR * a;
      double tp = (dir > 0) ? entry + InpTP_ATR * a : entry - InpTP_ATR * a;
      string tag = "MIMGEX_" + IntegerToString(i);
      DrawLevel(tag + "_e", time[i], entry, clrSilver);
      DrawLevel(tag + "_s", time[i], sl,    clrOrangeRed);
      DrawLevel(tag + "_t", time[i], tp,    clrLimeGreen);
     }

   if(InpShowPanel) Panel();
   return(rates_total);
  }

//+------------------------------------------------------------------+
void DrawLevel(string name, datetime t0, double price, color c)
  {
   datetime t1 = t0 + InpWindowMin * 60;
   if(ObjectFind(0, name) < 0) ObjectCreate(0, name, OBJ_TREND, 0, t0, price, t1, price);
   else { ObjectMove(0, name, 0, t0, price); ObjectMove(0, name, 1, t1, price); }
   ObjectSetInteger(0, name, OBJPROP_COLOR, c);
   ObjectSetInteger(0, name, OBJPROP_WIDTH, 1);
   ObjectSetInteger(0, name, OBJPROP_RAY_RIGHT, false);
   ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
  }

//+------------------------------------------------------------------+
void Panel()
  {
   string n = "MIMGEX_panel";
   if(ObjectFind(0, n) < 0)
     {
      ObjectCreate(0, n, OBJ_LABEL, 0, 0, 0);
      ObjectSetInteger(0, n, OBJPROP_CORNER, CORNER_LEFT_UPPER);
      ObjectSetInteger(0, n, OBJPROP_XDISTANCE, 12);
      ObjectSetInteger(0, n, OBJPROP_YDISTANCE, 22);
      ObjectSetInteger(0, n, OBJPROP_FONTSIZE, 9);
      ObjectSetInteger(0, n, OBJPROP_SELECTABLE, false);
     }
   string txt;
   if(g_gexOK)
     {
      string regime = (g_gex < 0.0) ? "SHORT GAMMA -> MOMENTUM" : "LONG GAMMA -> REVERSAL";
      txt = StringFormat("GEX %s  %.3f bn  |  %s  |  %s",
                         g_gexTicker, g_gex / 1e9, regime, TimeToString(g_gexTime, TIME_DATE|TIME_MINUTES));
      ObjectSetInteger(0, n, OBJPROP_COLOR, (g_gex < 0.0) ? clrLimeGreen : clrGold);
     }
   else
     {
      txt = "GEX file not found (" + InpGexFile + ") - run gex.py.  Standing aside.";
      ObjectSetInteger(0, n, OBJPROP_COLOR, clrOrangeRed);
     }
   ObjectSetString(0, n, OBJPROP_TEXT, txt);
  }
//+------------------------------------------------------------------+
