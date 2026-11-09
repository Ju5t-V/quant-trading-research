//+------------------------------------------------------------------+
//|                                                  OF_Sessions.mq5 |
//|  Asia / London / New York session highlighting                   |
//|                                                                  |
//|  WHY THIS MATTERS FOR ORDERFLOW                                  |
//|   Volume, and therefore everything the other tools measure,      |
//|   is not spread evenly through the day.  The same "heavy         |
//|   volume" bar means something different at 3am Asia than it      |
//|   does at the New York open.  Shading the sessions stops you     |
//|   reading a thin Asian range as if it were real participation.   |
//|                                                                  |
//|   It also draws each session's HIGH and LOW.  Those are the      |
//|   levels the next session trades against: the Asian range is     |
//|   the classic liquidity pool that London runs, and London's      |
//|   extremes are what New York either extends or rejects.          |
//|                                                                  |
//|  TIMES ARE ENTERED IN GMT and converted with InpServerGMT.       |
//|   This broker (MetaQuotes-Demo) runs at GMT+3 - measured from    |
//|   the volume curve, whose peak sits at 17:00 server = 14:00 GMT, |
//|   the New York open.  If you change broker, check this first:    |
//|   every box will be in the wrong place if the offset is wrong.   |
//+------------------------------------------------------------------+
#property copyright "Jerry"
#property version   "1.10"
#property description "Shades the Asia, London and New York sessions and marks each session's range"
#property indicator_chart_window
#property indicator_buffers 0
#property indicator_plots   0

#include <Canvas\Canvas.mqh>

input group "=== Server clock ==="
input int    InpServerGMT     = 3;      // Broker server offset from GMT (MetaQuotes-Demo = 3)

input group "=== Asia ==="
input bool   InpAsiaOn        = true;   // Show Asia
input int    InpAsiaStartGMT  = 0;      // Asia start hour (GMT)
input int    InpAsiaEndGMT    = 9;      // Asia end hour (GMT)
input color  InpAsiaFill      = C'96,130,230';  // Asia fill
input color  InpAsiaBorder    = C'96,130,230';  // Asia border (the high/low edge)

input group "=== London ==="
input bool   InpLondonOn      = true;   // Show London
input int    InpLondonStartGMT= 7;      // London start hour (GMT)
input int    InpLondonEndGMT  = 16;     // London end hour (GMT)
input color  InpLondonFill    = C'74,200,128';  // London fill
input color  InpLondonBorder  = C'74,200,128';  // London border (the high/low edge)

input group "=== New York ==="
input bool   InpNYOn          = true;   // Show New York
input int    InpNYStartGMT    = 12;     // New York start hour (GMT)
input int    InpNYEndGMT      = 21;     // New York end hour (GMT)
input color  InpNYFill        = C'240,118,86';  // New York fill
input color  InpNYBorder      = C'240,118,86';  // New York border (the high/low edge)

input group "=== Display ==="
input int    InpDaysBack      = 15;     // Days of history to draw
input bool   InpShowBox       = true;   // Draw the session box
input bool   InpFillBox       = true;   // Fill it (off = outline only)
input int    InpFillOpacity   = 15;     // Fill opacity % (0 = invisible, 100 = solid)
input int    InpBorderWidth   = 1;      // Thickness of the high/low edge
input bool   InpShowRange     = true;   // Draw each session's high and low
input bool   InpExtendRange   = true;   // Extend those lines to the right
input int    InpExtendBars    = 60;     // How far to extend them
input bool   InpShowLabel     = true;   // Name each session
input bool   InpLabelAtTop    = true;   // Put the name at the top of the box
input color  InpTextColor     = clrSilver; // Label colour

#define SS_PREFIX "OFSS_"
#define SS_CANVAS "OFSSC_canvas"   // deliberately outside SS_PREFIX so Build() does not delete it

struct SessionDef
{
   string name;
   bool   on;
   int    startGmt;
   int    endGmt;
   color  fill;
   color  border;
};

struct FillBox
{
   datetime t1;
   datetime t2;
   double   lo;
   double   hi;
   color    clr;
};

SessionDef g_sess[3];
FillBox    g_boxes[];
datetime   g_lastBuild = 0;
CCanvas    g_canvas;

//+------------------------------------------------------------------+
int OnInit()
{
   g_sess[0].name = "ASIA";   g_sess[0].on = InpAsiaOn;
   g_sess[0].startGmt = InpAsiaStartGMT;   g_sess[0].endGmt = InpAsiaEndGMT;
   g_sess[0].fill = InpAsiaFill;           g_sess[0].border = InpAsiaBorder;

   g_sess[1].name = "LONDON"; g_sess[1].on = InpLondonOn;
   g_sess[1].startGmt = InpLondonStartGMT; g_sess[1].endGmt = InpLondonEndGMT;
   g_sess[1].fill = InpLondonFill;         g_sess[1].border = InpLondonBorder;

   g_sess[2].name = "NY";     g_sess[2].on = InpNYOn;
   g_sess[2].startGmt = InpNYStartGMT;     g_sess[2].endGmt = InpNYEndGMT;
   g_sess[2].fill = InpNYFill;             g_sess[2].border = InpNYBorder;

   //--- MT5 rectangle objects can only fill 100% solid.  A see-through
   //--- fill needs an ARGB canvas laid behind the candles instead.
   if(!g_canvas.CreateBitmapLabel(0, 0, SS_CANVAS, 0, 0, 100, 100, COLOR_FORMAT_ARGB_NORMALIZE))
   {
      Print("OF_Sessions: could not create canvas, error ", GetLastError());
      return INIT_FAILED;
   }
   ObjectSetInteger(0, SS_CANVAS, OBJPROP_BACK, true);        // behind the candles
   ObjectSetInteger(0, SS_CANVAS, OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, SS_CANVAS, OBJPROP_HIDDEN, true);
   ObjectSetInteger(0, SS_CANVAS, OBJPROP_CORNER, CORNER_LEFT_UPPER);

   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   g_canvas.Destroy();
   ObjectsDeleteAll(0, SS_PREFIX);
   ChartRedraw();
}

//+------------------------------------------------------------------+
int OnCalculate(const int rates_total, const int prev_calculated,
                const datetime &time[], const double &open[], const double &high[],
                const double &low[], const double &close[], const long &tick_volume[],
                const long &volume[], const int &spread[])
{
   if(rates_total < 10)
      return rates_total;

   //--- rebuild once per bar, not per tick
   if(time[rates_total-1] == g_lastBuild && prev_calculated > 0)
      return rates_total;
   g_lastBuild = time[rates_total-1];

   Build(rates_total, time, high, low);
   DrawFills();
   return rates_total;
}

//+------------------------------------------------------------------+
//| The canvas is in pixels, so it must be repainted whenever the     |
//| chart scrolls, zooms, rescales or is resized.                     |
//+------------------------------------------------------------------+
void OnChartEvent(const int id, const long &lparam, const double &dparam, const string &sparam)
{
   if(id == CHARTEVENT_CHART_CHANGE)
      DrawFills();
}

//+------------------------------------------------------------------+
//| Server time of a given GMT hour on the day that contains dayStart |
//+------------------------------------------------------------------+
datetime GmtHourToServer(datetime dayStartServer, int gmtHour)
{
   return dayStartServer + (datetime)((gmtHour + InpServerGMT) * 3600);
}

//+------------------------------------------------------------------+
void Build(int rates_total, const datetime &time[], const double &high[], const double &low[])
{
   ObjectsDeleteAll(0, SS_PREFIX);
   ArrayResize(g_boxes, 0);

   //--- midnight (server) of the most recent bar
   datetime last = time[rates_total-1];
   MqlDateTime dt;
   TimeToStruct(last, dt);
   dt.hour = 0; dt.min = 0; dt.sec = 0;
   datetime today = StructToTime(dt);

   int periodSec = PeriodSeconds(PERIOD_CURRENT);
   int drawn = 0;

   for(int d = 0; d <= InpDaysBack; d++)
   {
      datetime dayStart = today - (datetime)(d * 86400);

      for(int s = 0; s < 3; s++)
      {
         if(!g_sess[s].on)
            continue;

         datetime t1 = GmtHourToServer(dayStart, g_sess[s].startGmt);
         datetime t2 = GmtHourToServer(dayStart, g_sess[s].endGmt);
         if(t2 <= t1)
            t2 += 86400;              // session wraps past midnight
         if(t1 > last)
            continue;

         //--- the session's own high and low
         double hi = -DBL_MAX, lo = DBL_MAX;
         int    firstIdx = -1, lastIdx = -1;
         for(int i = 0; i < rates_total; i++)
         {
            if(time[i] < t1) continue;
            if(time[i] >= t2) break;
            if(firstIdx < 0) firstIdx = i;
            lastIdx = i;
            if(high[i] > hi) hi = high[i];
            if(low[i]  < lo) lo = low[i];
         }
         if(firstIdx < 0 || hi <= -DBL_MAX)
            continue;

         datetime tEnd = (datetime)MathMin((long)t2, (long)time[lastIdx] + periodSec);
         string id = SS_PREFIX + g_sess[s].name + "_" + IntegerToString(d);

         string tip = g_sess[s].name + "  " + DoubleToString(lo, _Digits) +
                      " - " + DoubleToString(hi, _Digits) +
                      "  (" + DoubleToString((hi - lo) / _Point, 0) + " pts)";

         if(InpShowBox)
         {
            //--- The see-through fill goes on the canvas (DrawFills).  The
            //--- outline stays a normal object on top in a brighter colour,
            //--- because that edge is what actually marks the high and low.
            if(InpFillBox)
            {
               int n = ArraySize(g_boxes);
               ArrayResize(g_boxes, n + 1);
               g_boxes[n].t1  = t1;
               g_boxes[n].t2  = tEnd;
               g_boxes[n].lo  = lo;
               g_boxes[n].hi  = hi;
               g_boxes[n].clr = g_sess[s].fill;
            }

            string be = id + "_edge";
            ObjectCreate(0, be, OBJ_RECTANGLE, 0, t1, lo, tEnd, hi);
            ObjectSetInteger(0, be, OBJPROP_COLOR, g_sess[s].border);
            ObjectSetInteger(0, be, OBJPROP_FILL, false);
            ObjectSetInteger(0, be, OBJPROP_STYLE, STYLE_SOLID);
            ObjectSetInteger(0, be, OBJPROP_WIDTH, (int)MathMax(1, InpBorderWidth));
            ObjectSetInteger(0, be, OBJPROP_BACK, false);
            ObjectSetInteger(0, be, OBJPROP_SELECTABLE, false);
            ObjectSetInteger(0, be, OBJPROP_HIDDEN, true);
            ObjectSetString(0, be, OBJPROP_TOOLTIP, tip);
         }

         if(InpShowRange)
         {
            datetime tRight = InpExtendRange
                              ? tEnd + (datetime)(periodSec * InpExtendBars)
                              : tEnd;
            MakeRangeLine(id + "_h", tEnd, tRight, hi, g_sess[s].border,
                          g_sess[s].name + " high");
            MakeRangeLine(id + "_l", tEnd, tRight, lo, g_sess[s].border,
                          g_sess[s].name + " low");
         }

         if(InpShowLabel)
         {
            string ln = id + "_lab";
            ObjectCreate(0, ln, OBJ_TEXT, 0, t1, InpLabelAtTop ? hi : lo);
            ObjectSetString(0, ln, OBJPROP_TEXT, " " + g_sess[s].name);
            ObjectSetInteger(0, ln, OBJPROP_COLOR,
                             InpTextColor == clrNONE ? g_sess[s].border : InpTextColor);
            ObjectSetInteger(0, ln, OBJPROP_FONTSIZE, 7);
            ObjectSetInteger(0, ln, OBJPROP_ANCHOR,
                             InpLabelAtTop ? ANCHOR_LEFT_LOWER : ANCHOR_LEFT_UPPER);
            ObjectSetInteger(0, ln, OBJPROP_SELECTABLE, false);
            ObjectSetInteger(0, ln, OBJPROP_HIDDEN, true);
         }
         drawn++;
      }
   }
   ChartRedraw();
}

//+------------------------------------------------------------------+
//| Paint the translucent session fills onto the canvas              |
//+------------------------------------------------------------------+
void DrawFills()
{
   int w = (int)ChartGetInteger(0, CHART_WIDTH_IN_PIXELS);
   int h = (int)ChartGetInteger(0, CHART_HEIGHT_IN_PIXELS, 0);
   if(w <= 0 || h <= 0)
      return;
   if(g_canvas.Width() != w || g_canvas.Height() != h)
      g_canvas.Resize(w, h);

   g_canvas.Erase(ColorToARGB(clrBlack, 0));

   uchar alpha = (uchar)MathRound(255.0 * MathMax(0, MathMin(100, InpFillOpacity)) / 100.0);
   if(alpha > 0)
   {
      int n = ArraySize(g_boxes);
      for(int i = 0; i < n; i++)
      {
         int x1, y1, x2, y2;
         if(!ChartTimePriceToXY(0, 0, g_boxes[i].t1, g_boxes[i].hi, x1, y1))
            continue;
         if(!ChartTimePriceToXY(0, 0, g_boxes[i].t2, g_boxes[i].lo, x2, y2))
            continue;
         if(x2 < 0 || x1 >= w || y2 < 0 || y1 >= h)
            continue;                 // entirely off screen

         x1 = MathMax(0, x1);   x2 = MathMin(w - 1, x2);
         y1 = MathMax(0, y1);   y2 = MathMin(h - 1, y2);
         if(x2 <= x1 || y2 < y1)
            continue;

         g_canvas.FillRectangle(x1, y1, x2, y2, ColorToARGB(g_boxes[i].clr, alpha));
      }
   }
   g_canvas.Update(false);
   ChartRedraw();
}

//+------------------------------------------------------------------+
void MakeRangeLine(string name, datetime t1, datetime t2, double price, color clr, string tip)
{
   ObjectCreate(0, name, OBJ_TREND, 0, t1, price, t2, price);
   ObjectSetInteger(0, name, OBJPROP_COLOR, clr);
   ObjectSetInteger(0, name, OBJPROP_STYLE, STYLE_DOT);
   ObjectSetInteger(0, name, OBJPROP_WIDTH, 1);
   ObjectSetInteger(0, name, OBJPROP_RAY_RIGHT, false);
   ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, name, OBJPROP_HIDDEN, true);
   ObjectSetInteger(0, name, OBJPROP_BACK, false);
   ObjectSetString(0, name, OBJPROP_TOOLTIP, tip + "  " + DoubleToString(price, _Digits));
}
//+------------------------------------------------------------------+
