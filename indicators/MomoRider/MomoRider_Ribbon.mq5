//+------------------------------------------------------------------+
//|  MomoRider_Ribbon.mq5                                            |
//|  Port of 4_JS_Ribbon_Liquidity_Combined.pine (price-pane half)   |
//|                                                                  |
//|  Draws, on the price chart:                                      |
//|    * fast ribbon = EMA(26) of Heikin-Ashi close                  |
//|    * slow ribbon = EMA(52) of Heikin-Ashi close                  |
//|    * staircase   = EMA(26) of HA close taken from a HIGHER TF    |
//|    * 1G / 1R pull-back markers (candle touching the ribbon)      |
//|                                                                  |
//|  All three formulas were reverse-engineered from JS Tradventure's|
//|  charts and verified to the last printed digit:                  |
//|    BTCUSDT.P 30m  EMA26 = 64,141.3   EMA52 = 63,853.7            |
//|    SXTUSDT.P 15m  EMA26 = 0.007306   EMA52 = 0.007257            |
//|                                                                  |
//|  NOTE on Heikin-Ashi: unlike Pine, MQL5's `close` is always the  |
//|  REAL close, so HA is computed here explicitly. That means this  |
//|  indicator gives identical values whether your chart is set to   |
//|  normal candles or not - which is actually safer than the Pine   |
//|  version, where the result depends on the chart type.            |
//|                                                                  |
//|  MT5 has no 2-indicator limit, so this is split from the         |
//|  momentum pane instead of using the force_overlay trick.         |
//+------------------------------------------------------------------+
#property copyright "MomoRider reconstruction"
#property version   "1.00"
#property indicator_chart_window
#property indicator_buffers 5
#property indicator_plots   5

#property indicator_label1  "Ribbon fast (EMA26 HA)"
#property indicator_type1   DRAW_LINE
#property indicator_color1  clrMediumSeaGreen
#property indicator_width1  2

#property indicator_label2  "Ribbon slow (EMA52 HA)"
#property indicator_type2   DRAW_LINE
#property indicator_color2  clrSeaGreen
#property indicator_width2  2

#property indicator_label3  "Staircase (HTF EMA26 HA)"
#property indicator_type3   DRAW_LINE
#property indicator_style3  STYLE_SOLID
#property indicator_color3  clrSilver
#property indicator_width3  1

#property indicator_label4  "1G pullback"
#property indicator_type4   DRAW_ARROW
#property indicator_color4  clrLime
#property indicator_width4  2

#property indicator_label5  "1R pullback"
#property indicator_type5   DRAW_ARROW
#property indicator_color5  clrRed
#property indicator_width5  2

input int              InpFast    = 26;              // Ribbon fast EMA
input int              InpSlow    = 52;              // Ribbon slow EMA
input int              InpStairLen= 26;              // Staircase EMA length
input ENUM_TIMEFRAMES  InpStairTF = PERIOD_H4;       // Staircase anchor timeframe
input bool             InpShow1G  = true;            // Show 1G/1R pullback markers
input bool             InpAlerts  = false;           // Alert on ribbon flip / pullback

double BufFast[], BufSlow[], BufStair[], Buf1G[], Buf1R[];

//--- HA working arrays (natural order)
double haO[], haH[], haL[], haC[];

//+------------------------------------------------------------------+
int OnInit()
  {
   SetIndexBuffer(0, BufFast,  INDICATOR_DATA);
   SetIndexBuffer(1, BufSlow,  INDICATOR_DATA);
   SetIndexBuffer(2, BufStair, INDICATOR_DATA);
   SetIndexBuffer(3, Buf1G,    INDICATOR_DATA);
   SetIndexBuffer(4, Buf1R,    INDICATOR_DATA);
   ArraySetAsSeries(BufFast,  false);
   ArraySetAsSeries(BufSlow,  false);
   ArraySetAsSeries(BufStair, false);
   ArraySetAsSeries(Buf1G,    false);
   ArraySetAsSeries(Buf1R,    false);
   PlotIndexSetInteger(3, PLOT_ARROW, 233);
   PlotIndexSetInteger(4, PLOT_ARROW, 234);
   PlotIndexSetDouble(3, PLOT_EMPTY_VALUE, EMPTY_VALUE);
   PlotIndexSetDouble(4, PLOT_EMPTY_VALUE, EMPTY_VALUE);
   PlotIndexSetInteger(2, PLOT_LINE_STYLE, STYLE_SOLID);
   IndicatorSetString(INDICATOR_SHORTNAME, "MomoRider Ribbon");
   IndicatorSetInteger(INDICATOR_DIGITS, _Digits);
   return(INIT_SUCCEEDED);
  }

//+------------------------------------------------------------------+
//| Heikin-Ashi from real OHLC (natural order, index 0 = oldest)      |
//+------------------------------------------------------------------+
void BuildHA(const int n, const double &o[], const double &h[],
             const double &l[], const double &c[])
  {
   if(ArraySize(haC) < n)
     {
      ArrayResize(haO, n); ArrayResize(haH, n);
      ArrayResize(haL, n); ArrayResize(haC, n);
     }
   for(int i = 0; i < n; i++)
     {
      haC[i] = (o[i] + h[i] + l[i] + c[i]) / 4.0;
      haO[i] = (i == 0) ? (o[0] + c[0]) / 2.0 : (haO[i-1] + haC[i-1]) / 2.0;
      haH[i] = MathMax(h[i], MathMax(haO[i], haC[i]));
      haL[i] = MathMin(l[i], MathMin(haO[i], haC[i]));
     }
  }

//+------------------------------------------------------------------+
//| EMA over an array, natural order. Seeded with the first value,    |
//| matching the Pine reconstruction.                                 |
//+------------------------------------------------------------------+
void EmaArr(const double &src[], const int n, const int len, double &dst[])
  {
   if(ArraySize(dst) < n) ArrayResize(dst, n);
   double a = 2.0 / (len + 1.0);
   for(int i = 0; i < n; i++)
      dst[i] = (i == 0) ? src[0] : a * src[i] + (1.0 - a) * dst[i-1];
  }

//+------------------------------------------------------------------+
//| Staircase: EMA(len) of Heikin-Ashi close on a HIGHER timeframe,   |
//| stepped onto the chart's bars using only CLOSED higher-TF bars    |
//| (so it does not repaint).                                         |
//+------------------------------------------------------------------+
bool BuildStaircase(const int n, const datetime &time[])
  {
   MqlRates hr[];
   ArraySetAsSeries(hr, false);
   int need = 0;
   // how many HTF bars do we need to cover the chart's range?
   int secChart = PeriodSeconds(_Period);
   int secHTF   = PeriodSeconds(InpStairTF);
   if(secHTF <= 0 || secChart <= 0) return(false);
   need = (int)((n * (double)secChart) / secHTF) + InpStairLen * 4 + 50;
   int got = CopyRates(_Symbol, InpStairTF, 0, need, hr);
   if(got <= InpStairLen + 2) return(false);

   double ho[], hh[], hl[], hc[], hcl[], em[];
   ArrayResize(ho, got); ArrayResize(hh, got);
   ArrayResize(hl, got); ArrayResize(hc, got); ArrayResize(hcl, got);
   for(int i = 0; i < got; i++)
     {
      hcl[i] = (hr[i].open + hr[i].high + hr[i].low + hr[i].close) / 4.0;
      ho[i]  = (i == 0) ? (hr[0].open + hr[0].close) / 2.0 : (ho[i-1] + hcl[i-1]) / 2.0;
     }
   EmaArr(hcl, got, InpStairLen, em);

   // map: for chart bar i, use the last HTF bar that has CLOSED
   int j = 0;
   for(int i = 0; i < n; i++)
     {
      while(j + 1 < got && hr[j+1].time <= time[i]) j++;
      // hr[j] is the HTF bar containing time[i]; use the previous, closed one
      int use = (hr[j].time <= time[i]) ? j - 1 : j;
      if(use < 0) use = 0;
      BufStair[i] = em[use];
     }
   return(true);
  }

//+------------------------------------------------------------------+
int OnCalculate(const int rates_total, const int prev_calculated,
                const datetime &time[], const double &open[],
                const double &high[], const double &low[],
                const double &close[], const long &tick_volume[],
                const long &volume[], const int &spread[])
  {
   if(rates_total < InpSlow + 5) return(0);

   // MQL5 hands these in as series or not depending on the caller; force natural
   ArraySetAsSeries(time,  false);
   ArraySetAsSeries(open,  false);
   ArraySetAsSeries(high,  false);
   ArraySetAsSeries(low,   false);
   ArraySetAsSeries(close, false);

   BuildHA(rates_total, open, high, low, close);

   double ef[], es[];
   EmaArr(haC, rates_total, InpFast, ef);
   EmaArr(haC, rates_total, InpSlow, es);
   for(int i = 0; i < rates_total; i++) { BufFast[i] = ef[i]; BufSlow[i] = es[i]; }

   if(!BuildStaircase(rates_total, time))
      for(int i = 0; i < rates_total; i++) BufStair[i] = EMPTY_VALUE;

   int start = (prev_calculated > 1) ? prev_calculated - 2 : InpSlow + 2;
   if(start < 1) start = 1;

   for(int i = start; i < rates_total; i++)
     {
      Buf1G[i] = EMPTY_VALUE;
      Buf1R[i] = EMPTY_VALUE;
      if(!InpShow1G) continue;

      bool   bull   = ef[i] > es[i];
      double ribTop = MathMax(ef[i], es[i]);
      double ribBot = MathMin(ef[i], es[i]);
      bool   redBar   = haC[i] <  haO[i];
      bool   greenBar = haC[i] >= haO[i];

      // 1G: bullish ribbon, red HA candle above it whose LOW reaches back and touches
      if(bull && redBar && haC[i] > ribBot && haL[i] <= ribTop)
         Buf1G[i] = low[i] - 0.6 * (high[i] - low[i] + _Point);
      // 1R: mirror
      if(!bull && greenBar && haC[i] < ribTop && haH[i] >= ribBot)
         Buf1R[i] = high[i] + 0.6 * (high[i] - low[i] + _Point);
     }

   // ---- alerts on the last CLOSED bar only ---------------------------------
   if(InpAlerts && rates_total > 2)
     {
      static datetime lastAlert = 0;
      int i = rates_total - 2;
      if(time[i] != lastAlert)
        {
         bool bullNow  = ef[i]   > es[i];
         bool bullPrev = ef[i-1] > es[i-1];
         if(bullNow != bullPrev)
           { Alert(_Symbol, " ", EnumToString(_Period), " MomoRider: ribbon flipped ",
                   bullNow ? "BULLISH" : "BEARISH"); lastAlert = time[i]; }
         else if(Buf1G[i] != EMPTY_VALUE)
           { Alert(_Symbol, " ", EnumToString(_Period), " MomoRider: 1G pullback touch"); lastAlert = time[i]; }
         else if(Buf1R[i] != EMPTY_VALUE)
           { Alert(_Symbol, " ", EnumToString(_Period), " MomoRider: 1R pullback touch"); lastAlert = time[i]; }
        }
     }

   return(rates_total);
  }
//+------------------------------------------------------------------+
