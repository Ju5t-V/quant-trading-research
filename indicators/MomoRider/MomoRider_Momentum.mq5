//+------------------------------------------------------------------+
//|  MomoRider_Momentum.mq5                                          |
//|  Port of 5_JS_MomoRider_Momentum_v2.pine                         |
//|                                                                  |
//|  Separate pane. Draws:                                           |
//|    * the momentum oscillator (0..100, plateaus at both rails)     |
//|    * zone bands: red 0-10, green 90-100  (measured off JS's own   |
//|      pixels: red core 1.05-8.1, green core 91.4-99.9)            |
//|    * HH / HL / LH / LL structure labels                          |
//|    * 4G / 4R signals                                             |
//|                                                                  |
//|  ENGINE - unchanged from the verified Pine defaults:             |
//|    src = (HA high + HA low) / 2                                   |
//|    dt  = src - EMA(src, 39)                                       |
//|    v1  = Stoch(dt, 14)  -> pf  = pf[1]  + 0.72*(v1 - pf[1])       |
//|    v3  = Stoch(pf, 26)  -> osc = osc[1] + 0.67*(v3 - osc[1])      |
//|                                                                  |
//|  The label rule is the part that matters, because the labels ARE  |
//|  the 3G/3R trigger: pivots are found on the OSCILLATOR, forced to |
//|  alternate high/low, then NAMED by comparing PRICE at consecutive |
//|  same-type pivots. Position from momentum, name from price - that |
//|  is what makes it a divergence read.                              |
//|                                                                  |
//|  Verified: on BTCUSDT.P 30m these defaults reproduce Jason's own  |
//|  label sequence LL, HH, HL, HH, HL exactly (5/5, correct types    |
//|  and sides), landing 0-3 bars later than his.                     |
//|                                                                  |
//|  HONEST NOTE: mechanised 4G/4R showed NO significant directional  |
//|  edge over 12 markets / 3,161 signals (see ../strategy/README.md).|
//|  Use this as a charting aid for discretionary reads, which is how |
//|  the original is used - not as an automatic system.               |
//+------------------------------------------------------------------+
#property copyright "MomoRider reconstruction"
#property version   "1.00"
#property indicator_separate_window
#property indicator_minimum -25
#property indicator_maximum 125
#property indicator_buffers 3
#property indicator_plots   3

#property indicator_label1  "Momentum"
#property indicator_type1   DRAW_LINE
#property indicator_color1  clrOrange
#property indicator_width1  2

#property indicator_label2  "4G"
#property indicator_type2   DRAW_ARROW
#property indicator_color2  clrLime
#property indicator_width2  3

#property indicator_label3  "4R"
#property indicator_type3   DRAW_ARROW
#property indicator_color3  clrRed
#property indicator_width3  3

#property indicator_level1  0
#property indicator_level2  10
#property indicator_level3  90
#property indicator_level4  100
#property indicator_levelcolor clrDimGray
#property indicator_levelstyle STYLE_DOT

input int    InpDetrend  = 39;    // Detrend EMA length
input int    InpCyc1     = 14;    // Stochastic length #1
input double InpSm1      = 0.72;  // Smoothing factor #1
input int    InpCyc2     = 26;    // Stochastic length #2
input double InpSm2      = 0.67;  // Smoothing factor #2
input double InpZoneHi   = 90.0;  // Upper zone
input double InpZoneLo   = 10.0;  // Lower zone
input int    InpPivLen   = 3;     // Pivot strength
input int    InpMinSep   = 4;     // Min bars between pivots
input bool   InpShowLbl  = true;  // Show HH/HL/LH/LL labels
input int    InpLookback = 600;   // Bars back to draw labels for
input int    InpRibFast  = 26;    // Ribbon fast EMA (for 4G/4R)
input int    InpRibSlow  = 52;    // Ribbon slow EMA (for 4G/4R)
input int    InpWindow   = 5;     // Setup window (bars)
input bool   InpShowSig  = true;  // Show 4G / 4R
input bool   InpAlerts   = false; // Alert on 4G / 4R

double BufOsc[], Buf4G[], Buf4R[];
double haO[], haH[], haL[], haC[];
double gOsc[];
string LP = "MRM_";           // label object prefix
int    gWin = -1;

//+------------------------------------------------------------------+
int OnInit()
  {
   SetIndexBuffer(0, BufOsc, INDICATOR_DATA);
   SetIndexBuffer(1, Buf4G,  INDICATOR_DATA);
   SetIndexBuffer(2, Buf4R,  INDICATOR_DATA);
   ArraySetAsSeries(BufOsc, false);
   ArraySetAsSeries(Buf4G,  false);
   ArraySetAsSeries(Buf4R,  false);
   PlotIndexSetInteger(1, PLOT_ARROW, 233);
   PlotIndexSetInteger(2, PLOT_ARROW, 234);
   PlotIndexSetDouble(1, PLOT_EMPTY_VALUE, EMPTY_VALUE);
   PlotIndexSetDouble(2, PLOT_EMPTY_VALUE, EMPTY_VALUE);
   IndicatorSetString(INDICATOR_SHORTNAME, "MomoRider Momentum");
   IndicatorSetInteger(INDICATOR_DIGITS, 1);
   return(INIT_SUCCEEDED);
  }

void OnDeinit(const int reason) { ObjectsDeleteAll(0, LP); }

//+------------------------------------------------------------------+
void BuildHA(const int n, const double &o[], const double &h[],
             const double &l[], const double &c[])
  {
   if(ArraySize(haC) < n)
     { ArrayResize(haO,n); ArrayResize(haH,n); ArrayResize(haL,n); ArrayResize(haC,n); }
   for(int i = 0; i < n; i++)
     {
      haC[i] = (o[i] + h[i] + l[i] + c[i]) / 4.0;
      haO[i] = (i == 0) ? (o[0] + c[0]) / 2.0 : (haO[i-1] + haC[i-1]) / 2.0;
      haH[i] = MathMax(h[i], MathMax(haO[i], haC[i]));
      haL[i] = MathMin(l[i], MathMin(haO[i], haC[i]));
     }
  }

void EmaArr(const double &src[], const int n, const int len, double &dst[])
  {
   if(ArraySize(dst) < n) ArrayResize(dst, n);
   double a = 2.0 / (len + 1.0);
   for(int i = 0; i < n; i++) dst[i] = (i == 0) ? src[0] : a*src[i] + (1.0-a)*dst[i-1];
  }

//--- rolling stochastic, natural order
void StochArr(const double &src[], const int n, const int len, double &dst[])
  {
   if(ArraySize(dst) < n) ArrayResize(dst, n);
   int L = MathMax(2, len);
   for(int i = 0; i < n; i++)
     {
      int j0 = MathMax(0, i - L + 1);
      double hi = src[j0], lo = src[j0];
      for(int j = j0; j <= i; j++) { if(src[j] > hi) hi = src[j]; if(src[j] < lo) lo = src[j]; }
      double rng = hi - lo;
      dst[i] = (rng <= 0.0) ? 50.0 : 100.0 * (src[i] - lo) / rng;
     }
  }

void SmoothArr(const double &src[], const int n, const double f, double &dst[])
  {
   if(ArraySize(dst) < n) ArrayResize(dst, n);
   for(int i = 0; i < n; i++) dst[i] = (i == 0) ? src[0] : dst[i-1] + f * (src[i] - dst[i-1]);
  }

//+------------------------------------------------------------------+
//| Draw one structure label in the indicator subwindow               |
//+------------------------------------------------------------------+
void PutLabel(const datetime t, const double y, const string txt, const bool isHigh)
  {
   if(gWin < 0) return;
   string nm = LP + (string)(long)t;
   if(ObjectFind(0, nm) < 0)
      ObjectCreate(0, nm, OBJ_TEXT, gWin, t, y);
   else
     { ObjectSetInteger(0, nm, OBJPROP_TIME, 0, t); ObjectSetDouble(0, nm, OBJPROP_PRICE, 0, y); }
   ObjectSetString(0, nm, OBJPROP_TEXT, txt);
   ObjectSetString(0, nm, OBJPROP_FONT, "Arial Bold");
   ObjectSetInteger(0, nm, OBJPROP_FONTSIZE, 8);
   ObjectSetInteger(0, nm, OBJPROP_COLOR,
      (txt == "HH" || txt == "HL") ? clrLime : clrRed);
   ObjectSetInteger(0, nm, OBJPROP_ANCHOR, isHigh ? ANCHOR_LOWER : ANCHOR_UPPER);
   ObjectSetInteger(0, nm, OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, nm, OBJPROP_BACK, false);
  }

//+------------------------------------------------------------------+
int OnCalculate(const int rates_total, const int prev_calculated,
                const datetime &time[], const double &open[],
                const double &high[], const double &low[],
                const double &close[], const long &tick_volume[],
                const long &volume[], const int &spread[])
  {
   int need = InpDetrend + InpCyc1 + InpCyc2 + InpRibSlow + 20;
   if(rates_total < need) return(0);

   ArraySetAsSeries(time,  false); ArraySetAsSeries(open,  false);
   ArraySetAsSeries(high,  false); ArraySetAsSeries(low,   false);
   ArraySetAsSeries(close, false);

   gWin = ChartWindowFind();

   BuildHA(rates_total, open, high, low, close);

   //---- oscillator -------------------------------------------------------
   double src[], em[], det[], v1[], pf[], v3[];
   ArrayResize(src, rates_total); ArrayResize(det, rates_total);
   for(int i = 0; i < rates_total; i++) src[i] = (haH[i] + haL[i]) / 2.0;
   EmaArr(src, rates_total, InpDetrend, em);
   for(int i = 0; i < rates_total; i++) det[i] = src[i] - em[i];
   StochArr(det, rates_total, InpCyc1, v1);
   SmoothArr(v1, rates_total, InpSm1, pf);
   StochArr(pf, rates_total, InpCyc2, v3);
   SmoothArr(v3, rates_total, InpSm2, gOsc);
   for(int i = 0; i < rates_total; i++) { BufOsc[i] = gOsc[i]; Buf4G[i] = EMPTY_VALUE; Buf4R[i] = EMPTY_VALUE; }

   //---- ribbon for the 4G/4R stack --------------------------------------
   double ef[], es[];
   EmaArr(haC, rates_total, InpRibFast, ef);
   EmaArr(haC, rates_total, InpRibSlow, es);

   //---- zig-zag structure on the oscillator ------------------------------
   int scanFrom = MathMax(need, rates_total - (InpLookback + 400));
   int drawFrom = MathMax(need, rates_total - InpLookback);
   if(InpShowLbl) ObjectsDeleteAll(0, LP);

   int    lastType = 0, lastBar = -1000000;
   double lastOsc = 0.0;
   double curHi = 0, refHi = 0, curLo = 0, refLo = 0;
   bool   haveHi = false, haveLo = false, haveRefHi = false, haveRefLo = false;
   datetime lastLblTime = 0;

   // bullStruct/bearStruct per bar, plus the oscillator value at that pivot
   static int    sBull[];  static int sBear[];  static double sOscAt[];
   ArrayResize(sBull, rates_total); ArrayResize(sBear, rates_total); ArrayResize(sOscAt, rates_total);
   ArrayInitialize(sBull, 0); ArrayInitialize(sBear, 0);
   for(int i = 0; i < rates_total; i++) sOscAt[i] = EMPTY_VALUE;

   int P = InpPivLen;
   for(int i = scanFrom; i < rates_total - P; i++)
     {
      // confirmed pivot on the oscillator at bar i (P bars either side)
      bool isHi = true, isLo = true;
      for(int k = i - P; k <= i + P; k++)
        {
         if(k < 0 || k >= rates_total) { isHi = false; isLo = false; break; }
         if(k == i) continue;
         if(gOsc[k] >= gOsc[i]) isHi = false;
         if(gOsc[k] <= gOsc[i]) isLo = false;
        }
      if(!isHi && !isLo) continue;

      bool sameType = (lastType == (isHi ? 1 : -1));
      bool better   = sameType && (isHi ? gOsc[i] > lastOsc : gOsc[i] < lastOsc);
      bool farEnough= (lastBar < 0) || ((i - lastBar) >= InpMinSep);
      if(!((!sameType && farEnough) || better)) continue;

      if(better && lastLblTime != 0)
         ObjectDelete(0, LP + (string)(long)lastLblTime);   // replaced by a better swing

      string txt;
      if(isHi)
        {
         if(!better) { refHi = curHi; haveRefHi = haveHi; }
         txt = (!haveRefHi || haC[i] >= refHi) ? "HH" : "LH";
         curHi = haC[i]; haveHi = true;
        }
      else
        {
         if(!better) { refLo = curLo; haveRefLo = haveLo; }
         txt = (!haveRefLo || haC[i] >= refLo) ? "HL" : "LL";
         curLo = haC[i]; haveLo = true;
        }

      if(InpShowLbl && i >= drawFrom)
        {
         double y = isHi ? gOsc[i] + 6.0 : gOsc[i] - 6.0;
         PutLabel(time[i], y, txt, isHi);
         lastLblTime = time[i];
        }

      // the pivot is only KNOWN P bars later - that is where it can be acted on
      int cb = i + P;
      if(cb < rates_total)
        {
         if(txt == "HH" || txt == "HL") sBull[cb] = 1; else sBear[cb] = 1;
         sOscAt[cb] = gOsc[i];
        }
      lastType = isHi ? 1 : -1; lastBar = i; lastOsc = gOsc[i];
     }

   //---- 4G / 4R ----------------------------------------------------------
   if(InpShowSig)
     {
      for(int i = MathMax(drawFrom, need + InpWindow + 1); i < rates_total; i++)
        {
         bool   bull   = ef[i] > es[i];
         double ribTop = MathMax(ef[i], es[i]);
         double ribBot = MathMin(ef[i], es[i]);
         bool   red    = haC[i] <  haO[i];
         bool   green  = haC[i] >= haO[i];

         // 1G on the PREVIOUS bar, this bar closes the other way
         int p = i - 1;
         bool bullP = ef[p] > es[p];
         double rTopP = MathMax(ef[p], es[p]), rBotP = MathMin(ef[p], es[p]);
         bool oneG = bullP  && (haC[p] <  haO[p]) && haC[p] > rBotP && haL[p] <= rTopP;
         bool oneR = !bullP && (haC[p] >= haO[p]) && haC[p] < rTopP && haH[p] >= rBotP;

         if(oneG && green)
           {
            bool z = false, s = false;
            for(int k = MathMax(0, i - InpWindow); k <= i; k++)
              {
               if(gOsc[k] <= InpZoneLo) z = true;
               if(sBull[k] == 1 && sOscAt[k] != EMPTY_VALUE && sOscAt[k] <= InpZoneLo + 15.0) s = true;
              }
            if(z && s) Buf4G[i] = 50.0;
           }
         if(oneR && red)
           {
            bool z = false, s = false;
            for(int k = MathMax(0, i - InpWindow); k <= i; k++)
              {
               if(gOsc[k] >= InpZoneHi) z = true;
               if(sBear[k] == 1 && sOscAt[k] != EMPTY_VALUE && sOscAt[k] >= InpZoneHi - 15.0) s = true;
              }
            if(z && s) Buf4R[i] = 50.0;
           }
        }
     }

   //---- alerts on the last closed bar ------------------------------------
   if(InpAlerts && rates_total > 2)
     {
      static datetime lastA = 0;
      int i = rates_total - 2;
      if(time[i] != lastA)
        {
         if(Buf4G[i] != EMPTY_VALUE)
           { Alert(_Symbol," ",EnumToString(_Period)," MomoRider 4G LONG  momentum=",
                   DoubleToString(gOsc[i],1)); lastA = time[i]; }
         else if(Buf4R[i] != EMPTY_VALUE)
           { Alert(_Symbol," ",EnumToString(_Period)," MomoRider 4R SHORT momentum=",
                   DoubleToString(gOsc[i],1)); lastA = time[i]; }
        }
     }

   return(rates_total);
  }
//+------------------------------------------------------------------+
