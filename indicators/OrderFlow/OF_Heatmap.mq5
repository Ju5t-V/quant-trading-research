//+------------------------------------------------------------------+
//|                                                   OF_Heatmap.mq5 |
//|  Traded-volume heatmap + volume profile + HVN/LVN/POC/value area |
//|                                                                  |
//|  WHAT IT DRAWS                                                   |
//|   - A heatmap behind the candles: every visible bar is sliced    |
//|     into price buckets, and each bucket is shaded by how much    |
//|     volume actually traded there.  Bright = heavy trade.  This   |
//|     is where price spent its effort, not just where it went.     |
//|   - A volume profile histogram on the right edge for the chosen  |
//|     scope (today's session, a rolling window, or what you see).  |
//|   - POC (most-traded price), the 70% value area, and automatic   |
//|     HVN / LVN levels extended across the chart.                  |
//|       HVN = shelf of heavy trade   -> price tends to stall and   |
//|             rotate there, good for fades and targets             |
//|       LVN = air pocket             -> price tends to travel      |
//|             through quickly, good for stop placement             |
//|                                                                  |
//|  WHERE THE VOLUME COMES FROM                                     |
//|   Exchange symbols (stocks, futures) carry REAL traded volume.   |
//|   CFDs like XAUUSD do not - they only carry a tick count.  The   |
//|   indicator auto-detects which it has and prints the answer on   |
//|   the chart, so you always know whether you are looking at real  |
//|   contracts or at tick activity standing in for them.            |
//|                                                                  |
//|  Run OF_Probe.mq5 first to see what your feed actually provides. |
//|                                                                  |
//|  The dashboard, the "widest void" highlight, the recency         |
//|  weighting and the bar-data profile mode are adapted from        |
//|  "Liquidity Structure & Order Flow [LuxAlgo]" (Pine v6),         |
//|  (c) LuxAlgo, licensed CC BY-NC-SA 4.0:                          |
//|  https://creativecommons.org/licenses/by-nc-sa/4.0/              |
//|  Those parts, and this file as a whole, carry the same licence:  |
//|  personal use and modification yes, resale no.                   |
//|                                                                  |
//|  One deliberate improvement on the original: LuxAlgo assigns a   |
//|  whole bar's volume to the single bin holding that bar's CLOSE.  |
//|  Bar mode here spreads it across the bar's high-low range, which |
//|  is closer to where the volume actually traded.                  |
//|                                                                  |
//|  v1.10 (2026-09-13) changes - bucket modes, timeframe auto-tune, |
//|  a scope histogram decoupled from zoom/scroll, timeframe-        |
//|  namespaced HVN globals with a freshness timestamp - are         |
//|  released under the same CC BY-NC-SA 4.0 licence as the above.   |
//|                                                                  |
//|  v1.11 (2026-09-18): bar-close countdown docked to the panel.    |
//+------------------------------------------------------------------+
#property copyright "Jerry"
#property version   "1.11"
#property description "Volume heatmap, volume profile, POC/value area and automatic HVN/LVN levels"
#property indicator_chart_window
#property indicator_buffers 0
#property indicator_plots   0

#include <Canvas\Canvas.mqh>

//--- how volume is measured
enum ENUM_VOL_SOURCE
{
   VOL_AUTO       = 0,  // Auto-detect (real volume if the feed has it)
   VOL_REAL       = 1,  // Real traded volume only
   VOL_TICKCOUNT  = 2   // Tick count (every tick counts as 1)
};

//--- which price of a tick to bucket
enum ENUM_PRICE_SOURCE
{
   PRC_AUTO   = 0,  // Auto (last traded price if present, else bid)
   PRC_LAST   = 1,  // Last traded price
   PRC_BID    = 2,  // Bid
   PRC_MID    = 3   // Mid (bid+ask)/2
};

//--- what the profile and the HVN levels are calculated over
enum ENUM_PROFILE_SCOPE
{
   SCOPE_VISIBLE = 0,  // Everything currently visible on screen
   SCOPE_SESSION = 1,  // Today's session (from midnight server time)
   SCOPE_ROLLING = 2,  // A rolling window of N bars
   SCOPE_OFF     = 3   // No profile, heatmap only
};

//--- where the profile gets its numbers
enum ENUM_DATA_SOURCE
{
   DATA_AUTO  = 0,  // Auto - ticks when available, bars when not
   DATA_TICKS = 1,  // Ticks only (most accurate, needs tick history)
   DATA_BARS  = 2   // Bars only (works on any symbol, e.g. QQQ/NVDA)
};

enum ENUM_DASH_CORNER
{
   DASH_TOP_RIGHT    = 0,  // Top right
   DASH_TOP_LEFT     = 1,  // Top left
   DASH_BOTTOM_RIGHT = 2,  // Bottom right
   DASH_BOTTOM_LEFT  = 3   // Bottom left
};

enum ENUM_HEAT_SCHEME
{
   HEAT_FIRE  = 0,  // Fire  (dark red -> orange -> yellow -> white)
   HEAT_ICE   = 1,  // Ice   (navy -> blue -> cyan -> white)
   HEAT_GREEN = 2,  // Green (dark teal -> green -> yellow)
   HEAT_MONO  = 3   // Mono  (grey -> white)
};

//--- how the base price bucket is chosen
enum ENUM_BUCKET_MODE
{
   BUCKET_POINTS = 0,  // Points - use InpBucketPoints (current behaviour)
   BUCKET_PRICE  = 1,  // Price units - use InpBucketPrice
   BUCKET_AUTO   = 2   // Auto - derive from symbol tick size and timeframe
};

input group "=== Heatmap ==="
input bool             InpShowHeatmap   = true;        // Draw the volume heatmap
input double           InpBucketPoints  = 10;          // Price bucket size in POINTS (only $0.10 on a 2-digit gold feed)
input ENUM_BUCKET_MODE InpBucketMode    = BUCKET_POINTS; // How the bucket size is chosen
input double           InpBucketPrice   = 0.10;        // Bucket size in PRICE units (Price mode)
input bool             InpAutoBucket    = true;        // Auto-size the bucket to keep it fast
input ENUM_HEAT_SCHEME InpScheme        = HEAT_FIRE;   // Colour scheme
input int              InpMaxAlpha      = 200;         // Brightness of the hottest cell (0-255)
input bool             InpLogScale      = true;        // Log scaling (recommended: reveals the quiet levels)
input double           InpSaturatePct   = 99.0;        // Saturate colour at this percentile of cell volume
input int              InpMaxBars       = 500;         // Max bars to process (performance guard)

input group "=== Volume profile / HVN ==="
input ENUM_PROFILE_SCOPE InpScope       = SCOPE_SESSION; // What the profile covers
input int              InpRollingBars   = 200;         // Bars used when scope = Rolling
input bool             InpShowProfile   = true;        // Draw the histogram on the right edge
input int              InpProfileWidth  = 140;         // Histogram width in pixels
input color            InpProfileColor  = clrSteelBlue;// Histogram colour
input bool             InpShowPOC       = true;        // Draw the point of control
input color            InpPOCColor      = clrRed;      // POC colour
input bool             InpShowValueArea = true;        // Draw the 70% value area edges
input double           InpValueAreaPct  = 70.0;        // Value area size in percent
input color            InpVAColor       = clrDodgerBlue; // Value area colour
input bool             InpProfileFullScope = true;     // Session/Rolling profile covers the whole scope (off = visible bars only, v1.00)
input int              InpProfileMaxBars = 2000;       // Hard ceiling on bars in the scope histogram
input int              InpProfileMaxRows = 600;        // Rows used for level detection (coarsens wide ranges, never zoom-dependent)
input int              InpMinScopeBars  = 30;          // Bars in scope before HVNs are published (guess - tune it)

input group "=== Widest void ==="
input bool             InpShowVoid      = true;        // Shade the single widest low-volume gap
input double           InpVoidPct       = 15.0;        // A bucket counts as void below this % of the peak
input color            InpVoidColor     = clrDimGray;  // Void shading
input int              InpVoidAlpha     = 55;          // Void opacity

input group "=== Dashboard ==="
input bool             InpShowDash      = true;        // Show the stats panel
input ENUM_DASH_CORNER InpDashCorner    = DASH_TOP_RIGHT; // Panel corner
input color            InpDashText      = clrGainsboro;   // Panel text
input bool             InpShowCountdown = true;           // Show the bar-close countdown
input int              InpCdWarnSecs    = 10;             // Warn when this many seconds are left
input color            InpCdColor       = clrGainsboro;   // Countdown text
input color            InpCdWarnColor   = clrOrange;      // Countdown text near the close

input group "=== HVN / LVN detection ==="
input bool             InpShowHVN       = true;        // Draw high volume nodes
input bool             InpShowLVN       = true;        // Draw low volume nodes (air pockets)
input int              InpSmoothBuckets = 5;           // Smoothing applied before finding peaks
input double           InpHvnMinPct     = 55.0;        // A peak must reach this % of the POC to count
input double           InpLvnMaxPct     = 25.0;        // A trough must be below this % of the POC
input double           InpMinSepPct     = 8.0;         // Min gap between two nodes, % of value-area width
input int              InpMaxNodes      = 8;           // Most nodes to draw per side
input color            InpHVNColor      = clrGoldenrod;// HVN colour
input color            InpLVNColor      = clrSlateGray;// LVN colour
input bool             InpHvnAsZone     = true;        // Highlight each HVN as a shaded band, not just a line
input double           InpHvnZoneEdge   = 70.0;        // Band covers the shelf down to this % of its own peak
input int              InpHvnZoneAlpha  = 35;          // Band opacity (0-255; ~35 is see-through like the session boxes)
input double           InpHvnZoneMaxPct = 25.0;        // Cap a band at this % of value-area width
input int              InpHvnZoneMaxPx  = 10;          // Also cap each band's drawn height in pixels (0 = no cap, v1.00 look)
input bool             InpHvnZoneEdges  = true;        // Thin top/bottom edge on each band
input bool             InpHvnLabels     = true;        // Print "HVN <price>" beside each node

input group "=== General ==="
input ENUM_DATA_SOURCE  InpDataSource   = DATA_AUTO;   // Where the profile gets its numbers
input bool             InpRecencyWeight = false;       // Weight recent bars more heavily (profile only)
input ENUM_VOL_SOURCE   InpVolSource    = VOL_AUTO;    // Volume source
input ENUM_PRICE_SOURCE InpPriceSource  = PRC_AUTO;    // Which tick price to bucket
input bool             InpMatchBarVol   = true;        // Count only ticks that moved the bucketed price
input bool             InpShowStatus    = true;        // Show the data-source status line
input int              InpRefreshMs     = 300;         // Redraw throttle in milliseconds
input bool             InpAutoTune      = true;        // Pick scope / data source / max bars by timeframe
input double           InpMaxHeatmapHours = 48;        // Auto-tune: heatmap span as a time budget, in hours
input int              InpRecencyMaxBars = 300;        // Recency weighting is forced off above this many tick-built scope bars

//--- object naming
#define OF_PREFIX  "OFHM_"
#define OF_CANVAS  OF_PREFIX "canvas"
#define OF_STATUS  OF_PREFIX "status"
#define OF_STATUS2 OF_PREFIX "status2"
#define OF_MAXBARS_DEFAULT 500     // v1.00 default of InpMaxBars - anything else counts as a manual choice

//--- per-bar bucketed volume, cached so we only read ticks once per bar
struct BarVol
{
   datetime t;         // bar open time
   int      minIdx;    // absolute bucket index of vol[0]
   double   vol[];     // volume per bucket
   double   total;
   bool     valid;
};

CCanvas   g_canvas;

#define OF_CDCANVAS OF_PREFIX "cd"

CCanvas  g_cdCanvas;
bool     g_cdReady = false;
int      g_cdX     = -1;
int      g_cdY     = -1;
int      g_cdLastSecs = -999;   // only repaint when the displayed second changes
bool     g_cdDirty    = true;   // ... or when the chart geometry moved

BarVol    g_cache[];          // chronological, one entry per bar
int       g_cacheCount = 0;
double    g_bucketSize = 0.0; // in price terms
bool      g_useRealVol = false;
string    g_volLabel   = "";
string    g_prcLabel   = "";
datetime  g_lastBarTime = 0;
bool      g_dirty       = true;
ulong     g_lastDraw    = 0;
int       g_digits      = 5;
double    g_point       = 0.0;

//--- profile results, reused by the drawing code
double    g_profVol[];
int       g_profMinIdx  = 0;
int       g_profCount   = 0;
double    g_profMax     = 0.0;
double    g_profTotal   = 0.0;
int       g_voidLo      = -1;
int       g_voidHi      = -1;
bool      g_usingBars   = false;   // did we fall back to bar data?
int       g_pocIdx      = -1;
int       g_vahIdx      = -1;
int       g_valIdx      = -1;
double    g_profBucket  = 0.0;     // bucket the profile arrays are expressed in

//--- resolved settings (inputs are only read in OnInit)
double             g_baseBucket = 0.0;
ENUM_PROFILE_SCOPE g_scope      = SCOPE_SESSION;
ENUM_DATA_SOURCE   g_dataSource = DATA_AUTO;
int                g_maxBars    = OF_MAXBARS_DEFAULT;
bool               g_recency    = false;
bool               g_recencyForcedOff = false;
string             g_tfStr      = "";
string             g_gvBase     = "";     // OFHM_<sym>_<tf>_hvn_

//--- scope histogram: one accumulated array for the whole scope, closed bars only
double    g_hist[];
int       g_histMinIdx   = 0;
int       g_histCount    = 0;
datetime  g_histTimes[];            // bars included, chronological (times only, no cells)
int       g_histBars     = 0;
datetime  g_histDay      = 0;       // session start the histogram belongs to
bool      g_histReady    = false;
bool      g_histTruncated= false;
int       g_histFallback = 0;       // bars that had to use bar data
bool      g_histRetry    = false;
bool      g_lastBarFromBars = false;
ulong     g_ticksProcessed = 0;
bool      g_firstCellBuild = true;
int       g_scopeBars    = 0;       // bars behind the current profile

//--- HVN publishing
double    g_pubLevels[];
int       g_pubCount     = -1;
bool      g_hvnLive      = false;
bool      g_warming      = false;

//+------------------------------------------------------------------+
int OnInit()
{
   g_digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   g_point  = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   if(g_point <= 0.0)
      g_point = MathPow(10, -g_digits);

   DetectVolumeSource();
   DetectPriceSource();

   g_tfStr  = TfString((ENUM_TIMEFRAMES)Period());
   g_gvBase = "OFHM_" + _Symbol + "_" + g_tfStr + "_hvn_";
   ResolveAutoTune();
   ResolveBucket();
   ResolveRecency();
   Print("OF_Heatmap ", _Symbol, " ", g_tfStr, ": HVNs publish as ", g_gvBase, "*",
         "  |  InpMinScopeBars = ", InpMinScopeBars,
         "  |  full-scope profile ", (UseFullScope() ? "ON" : "off"));

   if(!g_canvas.CreateBitmapLabel(0, 0, OF_CANVAS, 0, 0, 100, 100, COLOR_FORMAT_ARGB_NORMALIZE))
   {
      Print("OF_Heatmap: could not create canvas, error ", GetLastError());
      return INIT_FAILED;
   }
   ObjectSetInteger(0, OF_CANVAS, OBJPROP_BACK, true);        // behind the candles
   ObjectSetInteger(0, OF_CANVAS, OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, OF_CANVAS, OBJPROP_HIDDEN, true);
   ObjectSetInteger(0, OF_CANVAS, OBJPROP_CORNER, CORNER_LEFT_UPPER);

   if(InpShowCountdown)
   {
      if(!g_cdCanvas.CreateBitmapLabel(0, 0, OF_CDCANVAS, 0, 0, 180, 20, COLOR_FORMAT_ARGB_NORMALIZE))
         Print("OF_Heatmap: could not create countdown canvas, error ", GetLastError());
      else
      {
         ObjectSetInteger(0, OF_CDCANVAS, OBJPROP_BACK,       false);  // in front of the candles
         ObjectSetInteger(0, OF_CDCANVAS, OBJPROP_SELECTABLE, false);
         ObjectSetInteger(0, OF_CDCANVAS, OBJPROP_HIDDEN,     true);
         ObjectSetInteger(0, OF_CDCANVAS, OBJPROP_CORNER,     CORNER_LEFT_UPPER);
         g_cdReady = true;
      }
   }

   //--- the countdown needs a sub-second tick; Redraw() stays throttled by
   //--- InpRefreshMs inside OnTimer, so this does not make the heatmap redraw more
   EventSetMillisecondTimer((int)MathMin(250, MathMax(100, InpRefreshMs)));
   g_dirty = true;
   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   EventKillTimer();
   g_canvas.Destroy();
   g_cdCanvas.Destroy();
   //--- mark this timeframe's HVN set as dead at once (1 = stale, 0 = never published)
   if(g_gvBase != "")
      GlobalVariableSet(g_gvBase + "time", 1.0);
   ObjectsDeleteAll(0, OF_PREFIX);
   ChartRedraw();
}

//+------------------------------------------------------------------+
int OnCalculate(const int rates_total, const int prev_calculated,
                const datetime &time[], const double &open[], const double &high[],
                const double &low[], const double &close[], const long &tick_volume[],
                const long &volume[], const int &spread[])
{
   if(rates_total > 0 && time[rates_total-1] != g_lastBarTime)
   {
      g_lastBarTime = time[rates_total-1];
      g_dirty = true;
   }
   else
      g_dirty = true;   // the forming bar keeps changing

   return rates_total;
}

//+------------------------------------------------------------------+
void OnChartEvent(const int id, const long &lparam, const double &dparam, const string &sparam)
{
   if(id == CHARTEVENT_CHART_CHANGE)
   {
      g_dirty   = true;
      g_cdDirty = true;
   }
}

//+------------------------------------------------------------------+
void OnTimer()
{
   //--- freshness heartbeat, separate from level changes: "this heatmap is alive
   //--- and its published set is current".  Levels themselves only republish on change.
   if(g_hvnLive)
      GlobalVariableSet(g_gvBase + "time", (double)TimeCurrent());

   //--- cheap: repaints a small bitmap of its own, never the heatmap
   DrawCountdown();

   if(!g_dirty)
      return;
   ulong now = GetTickCount64();
   if(now - g_lastDraw < (ulong)InpRefreshMs)
      return;
   g_dirty    = false;
   g_lastDraw = now;
   Redraw();
}

//+------------------------------------------------------------------+
//| "PERIOD_M5" -> "M5".  Same string the absorption CSV uses.        |
//+------------------------------------------------------------------+
string TfString(ENUM_TIMEFRAMES tf)
{
   string s = EnumToString(tf);
   StringReplace(s, "PERIOD_", "");
   return s;
}

//+------------------------------------------------------------------+
bool UseFullScope()
{
   return InpProfileFullScope && (g_scope == SCOPE_SESSION || g_scope == SCOPE_ROLLING);
}

//+------------------------------------------------------------------+
//| AUTO bucket target in basis points of price, by bar length.       |
//| STARTING GUESSES, not measured: M5 0.25bp reproduces the old      |
//| $0.10 on gold near $4000.  In-between periods take the next row.  |
//+------------------------------------------------------------------+
double AutoBucketBp()
{
   int ps = PeriodSeconds(PERIOD_CURRENT);
   if(ps <= 60)    return 0.125;
   if(ps <= 300)   return 0.25;
   if(ps <= 900)   return 0.5;
   if(ps <= 1800)  return 0.75;
   if(ps <= 3600)  return 1.25;
   if(ps <= 14400) return 2.5;
   return 5.0;
}

//+------------------------------------------------------------------+
double TickSize()
{
   double tick = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   return MathMax(tick, g_point);
}

//+------------------------------------------------------------------+
//| Price x bp, rounded to a whole number of ticks, at least one tick |
//+------------------------------------------------------------------+
double AutoBucketPrice()
{
   double tick = TickSize();
   double ref  = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   if(ref <= 0.0)
      ref = iClose(_Symbol, PERIOD_CURRENT, 0);
   double target = ref * AutoBucketBp() / 10000.0;
   long   n = (long)MathRound(target / tick);
   if(n < 1) n = 1;
   return (double)n * tick;
}

//+------------------------------------------------------------------+
void ResolveBucket()
{
   double autoB = AutoBucketPrice();
   string mode  = "POINTS";
   g_baseBucket = InpBucketPoints * g_point;

   if(InpBucketMode == BUCKET_PRICE)
   {
      mode = "PRICE";
      if(InpBucketPrice > 0.0)
         g_baseBucket = InpBucketPrice;
      else
         Print("OF_Heatmap ERROR: Price mode with InpBucketPrice <= 0 - falling back to InpBucketPoints");
   }
   else if(InpBucketMode == BUCKET_AUTO)
   {
      mode = "AUTO";
      g_baseBucket = autoB;
   }
   if(g_baseBucket <= 0.0)
      g_baseBucket = g_point;

   Print(StringFormat("OF_Heatmap %s %s: digits=%d point=%s tick_size=%s | mode=%s | bucket in use %.1f pts = %s price | AUTO would pick %.1f pts = %s price",
                      _Symbol, g_tfStr, g_digits,
                      DoubleToString(g_point, g_digits + 1),
                      DoubleToString(SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE), g_digits + 1),
                      mode,
                      g_baseBucket / g_point, DoubleToString(g_baseBucket, g_digits),
                      autoB / g_point, DoubleToString(autoB, g_digits)));
}

//+------------------------------------------------------------------+
//| Scope / data source / heatmap span by timeframe.  This is about   |
//| not freezing the terminal (500 hourly bars of CopyTicksRange), so |
//| it defaults on.                                                   |
//+------------------------------------------------------------------+
void ResolveAutoTune()
{
   g_scope      = InpScope;
   g_dataSource = InpDataSource;
   g_maxBars    = InpMaxBars;

   if(InpAutoTune)
   {
      int  ps   = PeriodSeconds(PERIOD_CURRENT);
      bool high = (ps >= 3600);

      //--- an explicit Visible or Off is a deliberate choice - respect it
      if(InpScope == SCOPE_SESSION || InpScope == SCOPE_ROLLING)
         g_scope = high ? SCOPE_ROLLING : SCOPE_SESSION;
      //--- AUTO = ticks where the symbol has them, bars only where it has none (QQQ/NVDA)
      g_dataSource = high ? DATA_BARS : DATA_AUTO;

      if(InpMaxBars == OF_MAXBARS_DEFAULT)
      {
         int b = (int)MathRound(InpMaxHeatmapHours * 3600.0 / (double)ps);
         if(b > OF_MAXBARS_DEFAULT) b = OF_MAXBARS_DEFAULT;
         if(b < 50)                 b = 50;
         g_maxBars = b;
      }
      else
         Print("OF_Heatmap: InpMaxBars=", InpMaxBars, " set manually - auto-tune time budget overridden");
   }

   Print(StringFormat("OF_Heatmap %s auto-tune %s: scope %s -> %s | data %s -> %s | max bars %d -> %d",
                      g_tfStr, (InpAutoTune ? "ON" : "off"),
                      EnumToString(InpScope), EnumToString(g_scope),
                      EnumToString(InpDataSource), EnumToString(g_dataSource),
                      InpMaxBars, g_maxBars));
}

//+------------------------------------------------------------------+
//| Recency weighting forces a full re-accumulation of the scope on   |
//| every closed bar.  With ticks on a big scope that is hundreds of  |
//| CopyTicksRange calls a bar - refuse it rather than hang.          |
//+------------------------------------------------------------------+
void ResolveRecency()
{
   g_recency = InpRecencyWeight;
   g_recencyForcedOff = false;
   if(!InpRecencyWeight || !UseFullScope() || g_dataSource == DATA_BARS)
      return;

   int ps  = PeriodSeconds(PERIOD_CURRENT);
   int est = (g_scope == SCOPE_SESSION) ? 86400 / ps : InpRollingBars;
   if(est > InpProfileMaxBars) est = InpProfileMaxBars;

   if(est > InpRecencyMaxBars)
   {
      g_recency = false;
      g_recencyForcedOff = true;
      Print("OF_Heatmap WARNING *** RECENCY WEIGHTING FORCED OFF *** scope up to ", est,
            " tick-built bars > InpRecencyMaxBars ", InpRecencyMaxBars,
            ". It would re-read every bar's ticks on each new bar and can hang the terminal.");
   }
}

//+------------------------------------------------------------------+
//| Does this feed carry real traded volume, or only tick counts?    |
//+------------------------------------------------------------------+
void DetectVolumeSource()
{
   if(InpVolSource == VOL_REAL)      { g_useRealVol = true;  g_volLabel = "real volume (forced)";  return; }
   if(InpVolSource == VOL_TICKCOUNT) { g_useRealVol = false; g_volLabel = "tick count (forced)";   return; }

   MqlTick ticks[];
   datetime to   = TimeCurrent();
   datetime from = to - 6 * 3600;
   int got = CopyTicksRange(_Symbol, ticks, COPY_TICKS_ALL, (ulong)from * 1000, (ulong)to * 1000);

   int withReal = 0;
   int n = (int)MathMin(got, 20000);
   for(int i = 0; i < n; i++)
      if(ticks[i].volume_real > 0.0)
         withReal++;

   g_useRealVol = (n > 0 && withReal > n / 2);
   g_volLabel   = g_useRealVol ? "REAL traded volume" : "tick count (CFD - no real volume)";
}

//+------------------------------------------------------------------+
void DetectPriceSource()
{
   switch(InpPriceSource)
   {
      case PRC_LAST: g_prcLabel = "last"; return;
      case PRC_BID:  g_prcLabel = "bid";  return;
      case PRC_MID:  g_prcLabel = "mid";  return;
   }
   bool lastMode = (SymbolInfoInteger(_Symbol, SYMBOL_CHART_MODE) == SYMBOL_CHART_MODE_LAST);
   g_prcLabel = lastMode ? "last" : "bid";
}

//+------------------------------------------------------------------+
double TickPrice(const MqlTick &t)
{
   ENUM_PRICE_SOURCE src = InpPriceSource;
   if(src == PRC_AUTO)
      src = (g_prcLabel == "last") ? PRC_LAST : PRC_BID;

   if(src == PRC_LAST && t.last > 0.0) return t.last;
   if(src == PRC_MID   && t.bid > 0.0 && t.ask > 0.0) return (t.bid + t.ask) * 0.5;
   if(t.bid > 0.0) return t.bid;
   if(t.last > 0.0) return t.last;
   return t.ask;
}

//+------------------------------------------------------------------+
//| COPY_TICKS_ALL hands back every quote update, including ones     |
//| where only the ASK moved.  MT5's own bar volume does not count    |
//| those, so including them inflates the heatmap by 40-60% on gold   |
//| versus the volume figures you see everywhere else.  Keep only the |
//| ticks that actually moved the price we are bucketing.             |
//+------------------------------------------------------------------+
bool TickCounts(const MqlTick &t)
{
   if(!InpMatchBarVol)
      return true;

   ENUM_PRICE_SOURCE src = InpPriceSource;
   if(src == PRC_AUTO)
      src = (g_prcLabel == "last") ? PRC_LAST : PRC_BID;

   if(src == PRC_LAST) return ((t.flags & TICK_FLAG_LAST) != 0);
   if(src == PRC_MID)  return ((t.flags & (TICK_FLAG_BID | TICK_FLAG_ASK)) != 0);
   return ((t.flags & TICK_FLAG_BID) != 0);
}

//+------------------------------------------------------------------+
double TickVolume(const MqlTick &t)
{
   if(g_useRealVol)
      return (t.volume_real > 0.0) ? t.volume_real : (double)t.volume;
   return 1.0;
}

//+------------------------------------------------------------------+
int PriceToBucket(double price, double bucket)
{
   return (int)MathFloor(price / bucket);
}

//+------------------------------------------------------------------+
//| Heatmap cells use the zoom-clamped g_bucketSize; the profile uses |
//| g_profBucket, which never depends on zoom in full-scope mode.     |
//+------------------------------------------------------------------+
double CellLowPrice(int idx)
{
   return (double)idx * g_bucketSize;
}

//+------------------------------------------------------------------+
double ProfLowPrice(int idx)
{
   return (double)idx * g_profBucket;
}

//+------------------------------------------------------------------+
//| Cache lookup - bars are chronological so binary search           |
//+------------------------------------------------------------------+
int CacheFind(datetime t)
{
   int lo = 0, hi = g_cacheCount - 1;
   while(lo <= hi)
   {
      int mid = (lo + hi) / 2;
      if(g_cache[mid].t == t) return mid;
      if(g_cache[mid].t <  t) lo = mid + 1;
      else                    hi = mid - 1;
   }
   return -1;
}

//+------------------------------------------------------------------+
void CacheReset()
{
   for(int i = 0; i < ArraySize(g_cache); i++)
      ArrayFree(g_cache[i].vol);
   ArrayFree(g_cache);
   g_cacheCount = 0;
}

//+------------------------------------------------------------------+
//| Bar-data fallback: spread one bar's volume evenly across the     |
//| buckets its range covers.  Less truthful than ticks - volume was |
//| not really uniform across the bar - but it is the only option on |
//| a symbol the server serves no ticks for, and it keeps the        |
//| heatmap two-dimensional, which LuxAlgo's close-only version does |
//| not.                                                             |
//+------------------------------------------------------------------+
bool BuildBarFromBar(datetime barTime, double bucket, BarVol &out)
{
   g_lastBarFromBars = true;
   int shift = iBarShift(_Symbol, PERIOD_CURRENT, barTime, true);
   out.t     = barTime;
   out.total = 0.0;
   out.valid = false;
   if(shift < 0)
   {
      out.minIdx = 0;
      ArrayResize(out.vol, 0);
      return false;
   }

   double hi = iHigh(_Symbol, PERIOD_CURRENT, shift);
   double lo = iLow(_Symbol, PERIOD_CURRENT, shift);
   double vol = 0.0;
   if(g_useRealVol)
      vol = (double)iRealVolume(_Symbol, PERIOD_CURRENT, shift);
   if(vol <= 0.0)
      vol = (double)iTickVolume(_Symbol, PERIOD_CURRENT, shift);
   if(hi <= 0.0 || lo <= 0.0 || vol <= 0.0)
   {
      out.minIdx = 0;
      ArrayResize(out.vol, 0);
      return false;
   }

   int minIdx = PriceToBucket(lo, bucket);
   int maxIdx = PriceToBucket(hi, bucket);
   int n = maxIdx - minIdx + 1;
   if(n < 1) n = 1;

   ArrayResize(out.vol, n);
   ArrayInitialize(out.vol, 0.0);
   out.minIdx = minIdx;

   double share = vol / (double)n;
   for(int b = 0; b < n; b++)
      out.vol[b] = share;
   out.total = vol;
   out.valid = true;
   return true;
}

//+------------------------------------------------------------------+
//| Read the ticks of one bar and bucket them by price               |
//+------------------------------------------------------------------+
bool BuildBar(datetime barTime, int periodSec, double bucket, BarVol &out)
{
   g_lastBarFromBars = false;
   if(g_dataSource == DATA_BARS)
   {
      g_usingBars = true;
      return BuildBarFromBar(barTime, bucket, out);
   }

   MqlTick ticks[];
   ulong from = (ulong)barTime * 1000;
   ulong to   = (ulong)(barTime + periodSec) * 1000 - 1;

   int got = CopyTicksRange(_Symbol, ticks, COPY_TICKS_ALL, from, to);
   if(got > 0)
      g_ticksProcessed += (ulong)got;
   out.t     = barTime;
   out.total = 0.0;
   out.valid = false;
   if(got <= 0)
   {
      //--- no ticks for this bar: on AUTO, quietly use the bar instead
      if(g_dataSource == DATA_AUTO)
      {
         g_usingBars = true;
         return BuildBarFromBar(barTime, bucket, out);
      }
      out.minIdx = 0;
      ArrayResize(out.vol, 0);
      return false;
   }

   int minIdx = INT_MAX, maxIdx = INT_MIN;
   for(int i = 0; i < got; i++)
   {
      if(!TickCounts(ticks[i])) continue;
      double p = TickPrice(ticks[i]);
      if(p <= 0.0) continue;
      int b = PriceToBucket(p, bucket);
      if(b < minIdx) minIdx = b;
      if(b > maxIdx) maxIdx = b;
   }
   if(minIdx > maxIdx)
   {
      out.minIdx = 0;
      ArrayResize(out.vol, 0);
      return false;
   }

   int n = maxIdx - minIdx + 1;
   ArrayResize(out.vol, n);
   ArrayInitialize(out.vol, 0.0);
   out.minIdx = minIdx;

   for(int i = 0; i < got; i++)
   {
      if(!TickCounts(ticks[i])) continue;
      double p = TickPrice(ticks[i]);
      if(p <= 0.0) continue;
      int b = PriceToBucket(p, bucket) - minIdx;
      double v = TickVolume(ticks[i]);
      out.vol[b] += v;
      out.total  += v;
   }
   out.valid = true;
   return true;
}

//+------------------------------------------------------------------+
//| Pick a bucket size that keeps the number of rows sane            |
//+------------------------------------------------------------------+
void ChooseBucketSize(double priceRange, int heightPx)
{
   double want = g_baseBucket;
   if(want <= 0.0)
      want = g_point;

   if(InpAutoBucket && priceRange > 0.0 && heightPx > 0)
   {
      // never finer than one screen pixel - it would be invisible anyway
      double minUseful = priceRange / (double)heightPx;
      if(want < minUseful)
         want = minUseful;
      // and never so many rows that a redraw crawls
      double maxRows = 1200.0;
      if(priceRange / want > maxRows)
         want = priceRange / maxRows;
   }

   if(MathAbs(want - g_bucketSize) > g_bucketSize * 0.001)
   {
      g_bucketSize = want;
      CacheReset();   // bucket indices are absolute, so they must be rebuilt
   }
}

//+------------------------------------------------------------------+
void Redraw()
{
   //--- the scope histogram depends on closed bars only - update it before any
   //--- chart-geometry early return, so zoom/scroll state can never affect it
   if(g_scope != SCOPE_OFF && UseFullScope())
      UpdateScopeHistogram();

   int w = (int)ChartGetInteger(0, CHART_WIDTH_IN_PIXELS);
   int h = (int)ChartGetInteger(0, CHART_HEIGHT_IN_PIXELS, 0);
   if(w <= 0 || h <= 0)
      return;

   if(g_canvas.Width() != w || g_canvas.Height() != h)
   {
      g_canvas.Resize(w, h);
      ObjectSetInteger(0, OF_CANVAS, OBJPROP_XDISTANCE, 0);
      ObjectSetInteger(0, OF_CANVAS, OBJPROP_YDISTANCE, 0);
   }
   g_canvas.Erase(ColorToARGB(clrBlack, 0));

   double priceMax = ChartGetDouble(0, CHART_PRICE_MAX, 0);
   double priceMin = ChartGetDouble(0, CHART_PRICE_MIN, 0);
   double priceRange = priceMax - priceMin;
   if(priceRange <= 0.0)
   {
      g_canvas.Update();
      return;
   }

   ChooseBucketSize(priceRange, h);

   int firstVisible = (int)ChartGetInteger(0, CHART_FIRST_VISIBLE_BAR);
   int visibleBars  = (int)ChartGetInteger(0, CHART_VISIBLE_BARS);
   int total        = Bars(_Symbol, PERIOD_CURRENT);
   if(total <= 0 || visibleBars <= 0)
   {
      g_canvas.Update();
      return;
   }

   // series index of the oldest and newest visible bar
   int newestShift = 0;
   int oldestShift = (int)MathMin(firstVisible, total - 1);
   int barCount    = (int)MathMin(oldestShift - newestShift + 1, g_maxBars);
   if(barCount <= 0)
   {
      g_canvas.Update();
      return;
   }
   oldestShift = newestShift + barCount - 1;

   int periodSec = PeriodSeconds(PERIOD_CURRENT);

   //--- times of the bars we will draw
   datetime times[];
   ArrayResize(times, barCount);
   for(int i = 0; i < barCount; i++)
      times[i] = iTime(_Symbol, PERIOD_CURRENT, oldestShift - i);   // chronological

   //--- pixel geometry
   int xs[];
   ArrayResize(xs, barCount);

   for(int i = 0; i < barCount; i++)
   {
      int x = 0, y = 0;
      if(!ChartTimePriceToXY(0, 0, times[i], priceMax, x, y))
         x = -10000;
      xs[i] = x;
   }
   double barW = (barCount > 1) ? (double)(xs[barCount-1] - xs[0]) / (double)(barCount - 1) : 8.0;
   if(barW < 1.0) barW = 1.0;

   //--- make sure every visible bar is in the cache
   ulong cellT0  = GetTickCount64();
   ulong cellTk0 = g_ticksProcessed;
   EnsureCache(times, barCount, periodSec);
   if(g_firstCellBuild)
   {
      g_firstCellBuild = false;
      ulong ms = GetTickCount64() - cellT0;
      Print("OF_Heatmap ", g_tfStr, " first heatmap build: ", barCount, " bars, ",
            IntegerToString((long)(g_ticksProcessed - cellTk0)), " ticks, ",
            IntegerToString((long)ms), " ms");
      if(ms > 3000)
         Print("OF_Heatmap WARNING: first heatmap build took ", IntegerToString((long)ms),
               " ms - lower InpMaxHeatmapHours (or InpMaxBars)");
   }

   //--- heatmap
   if(InpShowHeatmap)
      DrawHeatmap(times, xs, barCount, barW, priceMin, priceMax, h, w);

   //--- profile + levels
   if(g_scope != SCOPE_OFF)
   {
      if(UseFullScope())
         BinHistogramToProfile();                    // whole scope, zoom-independent
      else
         BuildProfile(times, barCount, periodSec);   // v1.00: visible bars in scope
      if(InpShowProfile)
         DrawProfile(priceMin, priceMax, h, w);
      DrawLevels(priceMin, priceMax, h, w);
   }
   else
   {
      ObjectsDeleteAll(0, OF_PREFIX "lvl_");
      g_hvnLive = false;
   }

   DrawDashboard(w, h);
   DrawStatus();              // painted on the canvas, so before Update
   g_canvas.Update();
   ChartRedraw();
}

//+------------------------------------------------------------------+
//| SCOPE HISTOGRAM                                                   |
//| The profile, POC, value area, void, HVN/LVN and dashboard read    |
//| from ONE accumulated bucket->volume array covering the whole      |
//| scope (closed bars only).  It does not need per-bar cells, is     |
//| built at g_baseBucket (never the zoom-clamped cell bucket), and   |
//| zoom/scroll never touch it - so those numbers only change when a  |
//| bar closes or the session resets.  SCOPE_VISIBLE keeps the old    |
//| coupled path, because visible bars is what it means.              |
//+------------------------------------------------------------------+
int g_histVersion = 0;
int g_binVersion  = -1;

void HistReset()
{
   ArrayFree(g_hist);
   ArrayFree(g_histTimes);
   g_histCount     = 0;
   g_histMinIdx    = 0;
   g_histBars      = 0;
   g_histTruncated = false;
   g_histFallback  = 0;
}

//+------------------------------------------------------------------+
//| Grow the histogram so absolute buckets lo..hi exist               |
//+------------------------------------------------------------------+
void HistEnsure(int lo, int hi)
{
   if(g_histCount <= 0)
   {
      g_histMinIdx = lo;
      g_histCount  = hi - lo + 1;
      ArrayResize(g_hist, g_histCount);
      ArrayInitialize(g_hist, 0.0);
      return;
   }
   int curHi = g_histMinIdx + g_histCount - 1;
   int newLo = (lo < g_histMinIdx) ? lo : g_histMinIdx;
   int newHi = (hi > curHi) ? hi : curHi;
   if(newLo == g_histMinIdx && newHi == curHi)
      return;

   int newCount = newHi - newLo + 1;
   double tmp[];
   ArrayResize(tmp, newCount);
   ArrayInitialize(tmp, 0.0);
   int off = g_histMinIdx - newLo;
   for(int i = 0; i < g_histCount; i++)
      tmp[off + i] = g_hist[i];

   ArrayResize(g_hist, newCount);
   ArrayCopy(g_hist, tmp);
   g_histMinIdx = newLo;
   g_histCount  = newCount;
}

//+------------------------------------------------------------------+
//| Add (sign +1) or remove (sign -1) one closed bar's volume.        |
//| Closed bars never change, so removal re-reads the same numbers.   |
//+------------------------------------------------------------------+
void HistAddBar(datetime t, double weight, int sign)
{
   BarVol b;
   if(!BuildBar(t, PeriodSeconds(PERIOD_CURRENT), g_baseBucket, b))
   {
      ArrayFree(b.vol);
      return;
   }
   if(sign > 0 && g_lastBarFromBars)
      g_histFallback++;

   int m = ArraySize(b.vol);
   if(m > 0)
   {
      HistEnsure(b.minIdx, b.minIdx + m - 1);
      for(int k = 0; k < m; k++)
      {
         int j = b.minIdx + k - g_histMinIdx;
         g_hist[j] += (double)sign * weight * b.vol[k];
         if(g_hist[j] < 1e-9)
            g_hist[j] = 0.0;       // clamp float residue from add/remove
      }
   }
   ArrayFree(b.vol);
}

//+------------------------------------------------------------------+
//| Closed bars in scope, chronological.  Capped at InpProfileMaxBars |
//| (most recent kept) - truncation is reported, never silent.        |
//+------------------------------------------------------------------+
int CollectScopeTimes(datetime &out[], datetime &sessionStart, bool &truncated)
{
   int total = Bars(_Symbol, PERIOD_CURRENT);
   int n = 0;
   sessionStart = 0;
   truncated = false;

   if(g_scope == SCOPE_SESSION)
   {
      MqlDateTime dt;
      TimeToStruct(iTime(_Symbol, PERIOD_CURRENT, 0), dt);
      dt.hour = 0; dt.min = 0; dt.sec = 0;
      sessionStart = StructToTime(dt);
      int s = 1;
      while(s < total && iTime(_Symbol, PERIOD_CURRENT, s) >= sessionStart)
         s++;
      n = s - 1;
   }
   else
      n = (int)MathMin(InpRollingBars, total - 1);

   if(n > InpProfileMaxBars)
   {
      n = InpProfileMaxBars;
      truncated = true;
   }
   if(n < 0) n = 0;

   ArrayResize(out, n);
   for(int j = 0; j < n; j++)
      out[j] = iTime(_Symbol, PERIOD_CURRENT, n - j);   // shift n = oldest, 1 = newest
   return n;
}

//+------------------------------------------------------------------+
void HistFullBuild(string reason, bool allowRetry)
{
   ulong t0  = GetTickCount64();
   ulong tk0 = g_ticksProcessed;

   HistReset();
   datetime times[];
   datetime day;
   bool     trunc;
   int n = CollectScopeTimes(times, day, trunc);
   g_histDay       = day;
   g_histTruncated = trunc;

   for(int j = 0; j < n; j++)
   {
      //--- recency: newest bar 1.0, oldest ~0, by position inside the scope
      double w = g_recency ? 1.0 - (double)(n - 1 - j) / (double)n : 1.0;
      HistAddBar(times[j], w, +1);
   }
   ArrayResize(g_histTimes, n);
   for(int j = 0; j < n; j++)
      g_histTimes[j] = times[j];
   g_histBars  = n;
   g_histReady = true;
   g_histRetry = (allowRetry && g_histFallback > 0 && g_dataSource != DATA_BARS);
   g_histVersion++;

   ulong ms = GetTickCount64() - t0;
   Print("OF_Heatmap ", g_tfStr, " scope histogram (", reason, "): ", n, " bars, ",
         IntegerToString((long)(g_ticksProcessed - tk0)), " ticks, ",
         IntegerToString((long)ms), " ms, ", g_histFallback, " bars from bar data",
         (g_histRetry ? " - will rebuild once at the next closed bar" : ""));
   if(trunc)
      Print("OF_Heatmap WARNING: PROFILE TRUNCATED to the most recent ", InpProfileMaxBars,
            " bars (InpProfileMaxBars)");
   if(ms > 5000)
      Print("OF_Heatmap WARNING: scope histogram took ", ms,
            " ms - consider Rolling scope, bar data, or a smaller InpProfileMaxBars");
}

//+------------------------------------------------------------------+
//| Bring the histogram up to the newest closed bar                   |
//+------------------------------------------------------------------+
void UpdateScopeHistogram()
{
   if(iTime(_Symbol, PERIOD_CURRENT, 1) <= 0)
      return;
   if(!g_histReady)
   {
      HistFullBuild("initial", true);
      return;
   }

   //--- SESSION resets at the session boundary rather than rebuilding
   if(g_scope == SCOPE_SESSION)
   {
      MqlDateTime dt;
      TimeToStruct(iTime(_Symbol, PERIOD_CURRENT, 0), dt);
      dt.hour = 0; dt.min = 0; dt.sec = 0;
      if(StructToTime(dt) != g_histDay)
      {
         HistFullBuild("new session", false);
         return;
      }
   }

   //--- any closed bars newer than the last one included?
   datetime lastIn = (g_histBars > 0) ? g_histTimes[g_histBars - 1] : 0;
   int total = Bars(_Symbol, PERIOD_CURRENT);
   int s = 1;
   while(s < total)
   {
      datetime ts = iTime(_Symbol, PERIOD_CURRENT, s);
      if(ts <= lastIn) break;
      if(g_scope == SCOPE_SESSION && ts < g_histDay) break;
      s++;
   }
   int newBars = s - 1;
   if(newBars <= 0)
      return;

   if(g_recency || g_histRetry)
   {
      bool wasRetry = g_histRetry;
      g_histRetry = false;
      HistFullBuild(wasRetry ? "retry after bar-data fallback" : "recency re-weight", false);
      return;
   }

   for(int k = newBars; k >= 1; k--)
   {
      datetime t = iTime(_Symbol, PERIOD_CURRENT, k);
      HistAddBar(t, 1.0, +1);
      ArrayResize(g_histTimes, g_histBars + 1, 256);
      g_histTimes[g_histBars++] = t;
   }

   int limit = (g_scope == SCOPE_ROLLING) ? (int)MathMin(InpRollingBars, InpProfileMaxBars)
                                          : InpProfileMaxBars;
   int drop = g_histBars - limit;
   if(drop > 0)
   {
      for(int i = 0; i < drop; i++)
         HistAddBar(g_histTimes[i], 1.0, -1);
      for(int i = 0; i + drop < g_histBars; i++)
         g_histTimes[i] = g_histTimes[i + drop];
      g_histBars -= drop;
      ArrayResize(g_histTimes, g_histBars);
      if(g_scope == SCOPE_SESSION)
         g_histTruncated = true;
   }
   g_histVersion++;
}

//+------------------------------------------------------------------+
//| Fill the profile arrays from the histogram.  Rows are coarsened   |
//| by an integer factor chosen from the scope's own price range, so  |
//| detection resolution depends on the data, never on zoom.          |
//+------------------------------------------------------------------+
void BinHistogramToProfile()
{
   if(g_binVersion == g_histVersion)
      return;
   g_binVersion = g_histVersion;

   g_scopeBars = g_histBars;
   g_profCount = 0;
   g_pocIdx = g_vahIdx = g_valIdx = -1;
   g_profMax = 0.0;
   g_profTotal = 0.0;
   g_profBucket = g_baseBucket;
   if(g_histCount <= 0)
   {
      ArrayFree(g_profVol);
      return;
   }

   int maxRows = (int)MathMax(10, InpProfileMaxRows);
   int k = (g_histCount + maxRows - 1) / maxRows;      // integer ceiling
   if(k < 1) k = 1;
   g_profBucket = g_baseBucket * k;

   //--- prices are positive, so bucket indices are too and / is a true floor
   g_profMinIdx = g_histMinIdx / k;
   int profHi   = (g_histMinIdx + g_histCount - 1) / k;
   g_profCount  = profHi - g_profMinIdx + 1;
   ArrayResize(g_profVol, g_profCount);
   ArrayInitialize(g_profVol, 0.0);

   double totalVol = 0.0;
   for(int i = 0; i < g_histCount; i++)
   {
      int p = (g_histMinIdx + i) / k - g_profMinIdx;
      g_profVol[p] += g_hist[i];
      totalVol     += g_hist[i];
   }
   g_profTotal = totalVol;

   for(int p = 0; p < g_profCount; p++)
      if(g_profVol[p] > g_profMax)
      {
         g_profMax = g_profVol[p];
         g_pocIdx  = p;
      }
   ComputeValueArea(totalVol);
}

//+------------------------------------------------------------------+
//| Rebuild the cache so it holds exactly the bars we need           |
//+------------------------------------------------------------------+
void EnsureCache(const datetime &times[], int barCount, int periodSec)
{
   BarVol fresh[];
   ArrayResize(fresh, barCount);

   datetime lastBar = iTime(_Symbol, PERIOD_CURRENT, 0);

   for(int i = 0; i < barCount; i++)
   {
      int idx = CacheFind(times[i]);
      bool needBuild = true;

      if(idx >= 0 && g_cache[idx].valid && times[i] != lastBar)
      {
         // a closed bar never changes - reuse it
         fresh[i].t      = g_cache[idx].t;
         fresh[i].minIdx = g_cache[idx].minIdx;
         fresh[i].total  = g_cache[idx].total;
         fresh[i].valid  = true;
         ArrayResize(fresh[i].vol, ArraySize(g_cache[idx].vol));
         ArrayCopy(fresh[i].vol, g_cache[idx].vol);
         needBuild = false;
      }

      if(needBuild)
         BuildBar(times[i], periodSec, g_bucketSize, fresh[i]);
   }

   CacheReset();
   ArrayResize(g_cache, barCount);
   for(int i = 0; i < barCount; i++)
   {
      g_cache[i].t      = fresh[i].t;
      g_cache[i].minIdx = fresh[i].minIdx;
      g_cache[i].total  = fresh[i].total;
      g_cache[i].valid  = fresh[i].valid;
      ArrayResize(g_cache[i].vol, ArraySize(fresh[i].vol));
      ArrayCopy(g_cache[i].vol, fresh[i].vol);
      ArrayFree(fresh[i].vol);
   }
   g_cacheCount = barCount;
}

//+------------------------------------------------------------------+
//| Colour ramp: t in 0..1                                           |
//+------------------------------------------------------------------+
uint HeatColor(double t)
{
   if(t < 0.0) t = 0.0;
   if(t > 1.0) t = 1.0;

   double r = 0, g = 0, b = 0;
   switch(InpScheme)
   {
      case HEAT_ICE:
         if(t < 0.5) { double u = t / 0.5;        r = 0;             g = 40 * u;         b = 90 + 165 * u; }
         else        { double u = (t-0.5) / 0.5;  r = 255 * u * u;   g = 40 + 215 * u;   b = 255; }
         break;
      case HEAT_GREEN:
         if(t < 0.5) { double u = t / 0.5;        r = 0;             g = 80 + 175 * u;   b = 90 - 70 * u; }
         else        { double u = (t-0.5) / 0.5;  r = 255 * u;       g = 255;            b = 20 * (1-u); }
         break;
      case HEAT_MONO:
         r = 120 + 135 * t; g = 120 + 135 * t; b = 120 + 135 * t;
         break;
      default: // HEAT_FIRE
         if(t < 0.4)      { double u = t / 0.4;         r = 90 + 165 * u;  g = 0;              b = 20 * (1-u); }
         else if(t < 0.75){ double u = (t-0.4) / 0.35;  r = 255;           g = 165 * u;        b = 0; }
         else             { double u = (t-0.75) / 0.25; r = 255;           g = 165 + 90 * u;   b = 255 * u; }
         break;
   }

   int alpha = (int)(InpMaxAlpha * MathPow(t, 0.55));
   if(alpha < 0)   alpha = 0;
   if(alpha > 255) alpha = 255;

   color c = (color)((int)b << 16 | (int)g << 8 | (int)r);
   return ColorToARGB(c, (uchar)alpha);
}

//+------------------------------------------------------------------+
//| Percentile of all non-zero cells, so one monster print does not  |
//| wash the whole picture out                                       |
//+------------------------------------------------------------------+
double SaturationLevel()
{
   double all[];
   int n = 0;
   for(int i = 0; i < g_cacheCount; i++)
   {
      int m = ArraySize(g_cache[i].vol);
      for(int b = 0; b < m; b++)
         if(g_cache[i].vol[b] > 0.0)
         {
            ArrayResize(all, n + 1, 4096);
            all[n++] = g_cache[i].vol[b];
         }
   }
   if(n == 0)
      return 0.0;
   ArraySort(all);
   double pct = InpSaturatePct;
   if(pct < 50.0)  pct = 50.0;
   if(pct > 100.0) pct = 100.0;
   int k = (int)MathFloor((pct / 100.0) * (n - 1));
   if(k < 0)  k = 0;
   if(k >= n) k = n - 1;
   double v = all[k];
   return (v > 0.0) ? v : all[n-1];
}

//+------------------------------------------------------------------+
void DrawHeatmap(const datetime &times[], const int &xs[], int barCount, double barW,
                 double priceMin, double priceMax, int h, int w)
{
   double sat = SaturationLevel();
   if(sat <= 0.0)
      return;

   double range = priceMax - priceMin;
   double logSat = MathLog(1.0 + sat);

   for(int i = 0; i < barCount; i++)
   {
      if(!g_cache[i].valid)
         continue;
      int x1 = (int)MathRound(xs[i] - barW * 0.5);
      int x2 = (int)MathRound(xs[i] + barW * 0.5);
      if(x2 < 0 || x1 > w)
         continue;
      if(x2 <= x1) x2 = x1 + 1;

      int m = ArraySize(g_cache[i].vol);
      for(int b = 0; b < m; b++)
      {
         double v = g_cache[i].vol[b];
         if(v <= 0.0)
            continue;

         double t;
         if(InpLogScale)
            t = (logSat > 0.0) ? MathLog(1.0 + v) / logSat : 0.0;
         else
            t = v / sat;
         if(t > 1.0) t = 1.0;

         double pLow  = CellLowPrice(g_cache[i].minIdx + b);
         double pHigh = pLow + g_bucketSize;

         int yTop = (int)MathRound((priceMax - pHigh) / range * h);
         int yBot = (int)MathRound((priceMax - pLow)  / range * h);
         if(yBot < 0 || yTop > h)
            continue;
         if(yBot <= yTop) yBot = yTop + 1;

         g_canvas.FillRectangle(x1, yTop, x2 - 1, yBot - 1, HeatColor(t));
      }
   }
}

//+------------------------------------------------------------------+
//| Sum the per-bar buckets over the chosen scope                    |
//+------------------------------------------------------------------+
void BuildProfile(const datetime &times[], int barCount, int periodSec)
{
   g_profBucket = g_bucketSize;     // v1.00 coupled path: profile shares the cell bucket
   datetime scopeFrom = 0;
   if(g_scope == SCOPE_SESSION)
   {
      MqlDateTime dt;
      TimeToStruct(TimeCurrent(), dt);
      dt.hour = 0; dt.min = 0; dt.sec = 0;
      scopeFrom = StructToTime(dt);
   }
   else if(g_scope == SCOPE_ROLLING)
   {
      int shift = (int)MathMax(0, InpRollingBars - 1);
      scopeFrom = iTime(_Symbol, PERIOD_CURRENT, (int)MathMin(shift, Bars(_Symbol, PERIOD_CURRENT) - 1));
   }
   // SCOPE_VISIBLE leaves scopeFrom at 0 -> everything cached (which is what is visible)

   int minIdx = INT_MAX, maxIdx = INT_MIN;
   g_scopeBars = 0;
   for(int i = 0; i < g_cacheCount; i++)
   {
      if(!g_cache[i].valid || g_cache[i].t < scopeFrom)
         continue;
      g_scopeBars++;
      int m = ArraySize(g_cache[i].vol);
      if(m <= 0) continue;
      if(g_cache[i].minIdx < minIdx)         minIdx = g_cache[i].minIdx;
      if(g_cache[i].minIdx + m - 1 > maxIdx) maxIdx = g_cache[i].minIdx + m - 1;
   }

   g_profCount = 0;
   g_pocIdx = g_vahIdx = g_valIdx = -1;
   g_profMax = 0.0;
   if(minIdx > maxIdx)
   {
      ArrayFree(g_profVol);
      return;
   }

   g_profMinIdx = minIdx;
   g_profCount  = maxIdx - minIdx + 1;
   ArrayResize(g_profVol, g_profCount);
   ArrayInitialize(g_profVol, 0.0);

   double totalVol = 0.0;
   for(int i = 0; i < g_cacheCount; i++)
   {
      if(!g_cache[i].valid || g_cache[i].t < scopeFrom)
         continue;

      //--- optional recency weighting: the newest bar counts 1.0, the oldest
      //--- in the window counts ~0.  Profile only - the heatmap cells stay raw
      //--- so the picture itself is never distorted.
      double w = 1.0;
      if(g_recency && g_cacheCount > 1)
         w = 1.0 - ((double)(g_cacheCount - 1 - i) / (double)g_cacheCount);

      int m = ArraySize(g_cache[i].vol);
      for(int b = 0; b < m; b++)
      {
         int k = g_cache[i].minIdx + b - minIdx;
         if(k < 0 || k >= g_profCount) continue;
         g_profVol[k] += g_cache[i].vol[b] * w;
         totalVol     += g_cache[i].vol[b] * w;
      }
   }
   g_profTotal = totalVol;

   for(int k = 0; k < g_profCount; k++)
   {
      if(g_profVol[k] > g_profMax)
      {
         g_profMax = g_profVol[k];
         g_pocIdx  = k;
      }
   }

   ComputeValueArea(totalVol);
}

//+------------------------------------------------------------------+
//| Standard value area: grow out from the POC, always taking the    |
//| heavier of the two neighbouring rows, until 70% is enclosed      |
//+------------------------------------------------------------------+
void ComputeValueArea(double totalVol)
{
   if(g_pocIdx < 0 || totalVol <= 0.0)
      return;

   double target = totalVol * (InpValueAreaPct / 100.0);
   double acc    = g_profVol[g_pocIdx];
   int lo = g_pocIdx, hi = g_pocIdx;

   while(acc < target && (lo > 0 || hi < g_profCount - 1))
   {
      double below = (lo > 0)                ? g_profVol[lo-1] : -1.0;
      double above = (hi < g_profCount - 1)  ? g_profVol[hi+1] : -1.0;
      if(above >= below) { hi++; acc += g_profVol[hi]; }
      else               { lo--; acc += g_profVol[lo]; }
   }
   g_valIdx = lo;
   g_vahIdx = hi;
}

//+------------------------------------------------------------------+
void DrawProfile(double priceMin, double priceMax, int h, int w)
{
   if(g_profCount <= 0 || g_profMax <= 0.0)
      return;

   double range = priceMax - priceMin;
   int x0 = w - InpProfileWidth;
   if(x0 < 0) x0 = 0;

   for(int k = 0; k < g_profCount; k++)
   {
      double v = g_profVol[k];
      if(v <= 0.0) continue;

      double pLow  = ProfLowPrice(g_profMinIdx + k);
      double pHigh = pLow + g_profBucket;
      int yTop = (int)MathRound((priceMax - pHigh) / range * h);
      int yBot = (int)MathRound((priceMax - pLow)  / range * h);
      if(yBot < 0 || yTop > h) continue;
      if(yBot <= yTop) yBot = yTop + 1;

      int len = (int)MathRound((v / g_profMax) * InpProfileWidth);
      if(len < 1) len = 1;

      bool inVA = (g_valIdx >= 0 && k >= g_valIdx && k <= g_vahIdx);
      color c   = (k == g_pocIdx) ? InpPOCColor : (inVA ? InpVAColor : InpProfileColor);
      uchar a   = (k == g_pocIdx) ? 220 : (inVA ? 150 : 90);

      g_canvas.FillRectangle(w - len, yTop, w - 1, yBot - 1, ColorToARGB(c, a));
   }
}

//+------------------------------------------------------------------+
//| POC / value area / HVN / LVN as real chart lines, so the prices  |
//| show up on the scale and can be used for reference               |
//+------------------------------------------------------------------+
void DrawLevels(double priceMin, double priceMax, int h, int w)
{
   ObjectsDeleteAll(0, OF_PREFIX "lvl_");
   bool detect = (InpShowHVN || InpShowLVN);
   int  noHvn[];
   if(g_profCount <= 0 || g_pocIdx < 0)
   {
      //--- no profile: say so (count 0, fresh time) rather than leave old levels live
      if(detect) PublishHvn(noHvn, 0); else g_hvnLive = false;
      return;
   }

   if(InpShowPOC)
      MakeLine("lvl_poc", BucketCenter(g_pocIdx), InpPOCColor, STYLE_SOLID, 2, "POC");

   if(InpShowValueArea && g_vahIdx >= 0 && g_valIdx >= 0)
   {
      MakeLine("lvl_vah", BucketCenter(g_vahIdx), InpVAColor, STYLE_DASH, 1, "VAH");
      MakeLine("lvl_val", BucketCenter(g_valIdx), InpVAColor, STYLE_DASH, 1, "VAL");
   }

   //--- smooth the profile before hunting for peaks, otherwise every
   //--- little jitter counts as a node
   double sm[];
   ArrayResize(sm, g_profCount);
   int r = (int)MathMax(0, InpSmoothBuckets / 2);
   for(int k = 0; k < g_profCount; k++)
   {
      double s = 0.0; int c = 0;
      for(int j = k - r; j <= k + r; j++)
         if(j >= 0 && j < g_profCount) { s += g_profVol[j]; c++; }
      sm[k] = (c > 0) ? s / c : 0.0;
   }

   double smMax = 0.0;
   for(int k = 0; k < g_profCount; k++)
      if(sm[k] > smMax) smMax = sm[k];
   if(smMax <= 0.0)
   {
      if(detect) PublishHvn(noHvn, 0); else g_hvnLive = false;
      return;
   }

   //--- a node is only a distinct level if it is a sensible distance from the
   //--- next one.  A fixed bucket count cannot know that: 8 buckets is $0.80 on
   //--- gold, which splits one shelf into four "separate" HVNs.  Scale the gap
   //--- to the width of the value area instead, so it works on any instrument.
   int vaWidth = (g_vahIdx >= 0 && g_valIdx >= 0) ? (g_vahIdx - g_valIdx + 1) : g_profCount;
   int minSep  = (int)MathRound(vaWidth * InpMinSepPct / 100.0);
   if(minSep < 2) minSep = 2;

   int hvnIdx[];
   int nHvn = 0;
   if(InpShowHVN || InpShowLVN)
      nHvn = MarkNodes(sm, smMax, true, InpHvnMinPct, InpHVNColor, "hvn", "HVN",
                       minSep, InpShowHVN, 0, g_profCount - 1, hvnIdx);
   if(detect) PublishHvn(hvnIdx, nHvn); else g_hvnLive = false;

   //--- A node is a shelf, not a hairline.  Grow out from each peak while the
   //--- profile stays fat, and shade that whole band - that is the area price
   //--- has to chew through, which is what you actually trade against.
   if(InpShowHVN && InpHvnAsZone && nHvn > 0)
   {
      int maxHalf = (int)MathMax(2, MathRound(vaWidth * InpHvnZoneMaxPct / 100.0) / 2);
      double range = priceMax - priceMin;
      int yTop[], yBot[];
      ArrayResize(yTop, nHvn);
      ArrayResize(yBot, nHvn);

      for(int i = 0; i < nHvn; i++)
      {
         int k = hvnIdx[i];
         double edge = sm[k] * InpHvnZoneEdge / 100.0;
         int lo = k, hi = k;
         while(lo > 0 && sm[lo-1] >= edge && (k - lo) < maxHalf) lo--;
         while(hi < g_profCount-1 && sm[hi+1] >= edge && (hi - k) < maxHalf) hi++;

         //--- to pixels.  On a zoomed-in chart a shelf that is a few dollars
         //--- tall can fill the whole screen and hide the heatmap, so the DRAWN
         //--- height is capped around the node's own price.  Drawing only - the
         //--- level itself and what is published to OF_Absorption do not change.
         double pLow  = ProfLowPrice(g_profMinIdx + lo);
         double pHigh = ProfLowPrice(g_profMinIdx + hi) + g_profBucket;
         yTop[i] = (int)MathRound((priceMax - pHigh) / range * h);
         yBot[i] = (int)MathRound((priceMax - pLow)  / range * h);
         if(InpHvnZoneMaxPx > 0 && yBot[i] - yTop[i] > InpHvnZoneMaxPx)
         {
            int yc = (int)MathRound((priceMax - BucketCenter(k)) / range * h);
            yTop[i] = yc - InpHvnZoneMaxPx / 2;
            yBot[i] = yTop[i] + InpHvnZoneMaxPx;
         }
         if(yBot[i] <= yTop[i]) yBot[i] = yTop[i] + 1;
      }

      //--- sort by top edge, then fuse any that touch ON SCREEN.  Overlapping
      //--- shading would stack and make the darkest patch an artefact.
      for(int i = 0; i < nHvn - 1; i++)
         for(int j = i + 1; j < nHvn; j++)
            if(yTop[j] < yTop[i])
            {
               int t1 = yTop[i]; yTop[i] = yTop[j]; yTop[j] = t1;
               int t2 = yBot[i]; yBot[i] = yBot[j]; yBot[j] = t2;
            }

      int curTop = yTop[0], curBot = yBot[0];
      for(int i = 1; i < nHvn; i++)
      {
         if(yTop[i] <= curBot)
         {
            if(yBot[i] > curBot) curBot = yBot[i];
         }
         else
         {
            ShadeBandPx(curTop, curBot, InpHVNColor, (uchar)InpHvnZoneAlpha, h, w);
            curTop = yTop[i];
            curBot = yBot[i];
         }
      }
      ShadeBandPx(curTop, curBot, InpHVNColor, (uchar)InpHvnZoneAlpha, h, w);
   }

   //--- name each node on the chart, so an HVN line cannot be mistaken for
   //--- the POC, value area or void lines
   if(InpShowHVN && InpHvnLabels && nHvn > 0)
   {
      double range = priceMax - priceMin;
      g_canvas.FontSet("Consolas", 11);
      int x = w - InpProfileWidth - 110;
      if(x < 4) x = 4;
      for(int i = 0; i < nHvn; i++)
      {
         double p = BucketCenter(hvnIdx[i]);
         int y = (int)MathRound((priceMax - p) / range * h);
         if(y < 0 || y > h) continue;
         g_canvas.TextOut(x, y - 12, "HVN " + DoubleToString(p, g_digits), ColorToARGB(InpHVNColor, 255));
      }
   }

   //--- An LVN only means something BETWEEN two shelves - that is what an air
   //--- pocket is.  Troughs out in the tails of the range are just the edge of
   //--- the distribution, not a level, so bound the search by the outer HVNs.
   //--- the single widest run of near-empty buckets.  Price crosses this fast,
   //--- so it is a bad target and a good place to hide a stop behind.
   g_voidLo = -1; g_voidHi = -1;
   if(InpShowVoid)
   {
      double vThres = smMax * InpVoidPct / 100.0;
      int runStart = -1, bestLen = 0;
      for(int k = 0; k < g_profCount; k++)
      {
         if(sm[k] < vThres)
         {
            if(runStart < 0) runStart = k;
            int len = k - runStart + 1;
            if(len > bestLen) { bestLen = len; g_voidLo = runStart; g_voidHi = k; }
         }
         else
            runStart = -1;
      }
      if(g_voidLo >= 0 && bestLen >= 2)
      {
         ShadeBand(g_voidLo, g_voidHi, InpVoidColor, (uchar)InpVoidAlpha,
                   priceMin, priceMax, h, w);
         MakeLine("lvl_voidT", BucketCenter(g_voidHi), InpVoidColor, STYLE_DOT, 1, "Void top");
         MakeLine("lvl_voidB", BucketCenter(g_voidLo), InpVoidColor, STYLE_DOT, 1, "Void bottom");
      }
   }

   if(InpShowLVN && nHvn >= 2)
   {
      int loB = hvnIdx[0], hiB = hvnIdx[0];
      for(int i = 1; i < nHvn; i++)
      {
         if(hvnIdx[i] < loB) loB = hvnIdx[i];
         if(hvnIdx[i] > hiB) hiB = hvnIdx[i];
      }
      int dummy[];
      MarkNodes(sm, smMax, false, InpLvnMaxPct, InpLVNColor, "lvn", "LVN",
                minSep, true, loB, hiB, dummy);
   }
}

//+------------------------------------------------------------------+
//| Publish this timeframe's HVN set for OF_Absorption.               |
//|  OFHM_<sym>_<tf>_hvn_count / _<i> / _bucket - only when the set   |
//|  actually changes, so readers are not chasing churn               |
//|  OFHM_<sym>_<tf>_hvn_time - on every call (and the OnTimer        |
//|  heartbeat): freshness, separate from the levels                  |
//| While the scope holds fewer than InpMinScopeBars bars the profile |
//| is noise (first bars of a session), so count 0 is published and   |
//| OF_Absorption treats the set as absent.                           |
//+------------------------------------------------------------------+
double g_pubBucket = 0.0;

void PublishHvn(const int &idx[], int n)
{
   g_hvnLive = true;
   g_warming = (g_scopeBars < InpMinScopeBars);
   int c = g_warming ? 0 : n;

   bool changed = (c != g_pubCount) || (g_profBucket != g_pubBucket);
   for(int i = 0; i < c && !changed; i++)
      if(BucketCenter(idx[i]) != g_pubLevels[i])
         changed = true;

   if(changed)
   {
      ArrayResize(g_pubLevels, c);
      for(int i = 0; i < c; i++)
      {
         g_pubLevels[i] = BucketCenter(idx[i]);
         GlobalVariableSet(g_gvBase + IntegerToString(i), g_pubLevels[i]);
      }
      GlobalVariableSet(g_gvBase + "bucket", g_profBucket);
      GlobalVariableSet(g_gvBase + "count", (double)c);
      g_pubCount  = c;
      g_pubBucket = g_profBucket;
   }
   GlobalVariableSet(g_gvBase + "time", (double)TimeCurrent());
}

//+------------------------------------------------------------------+
//| Find local maxima (HVN) or minima (LVN) in the smoothed profile  |
//+------------------------------------------------------------------+
int MarkNodes(const double &sm[], double smMax, bool peaks, double pctLimit,
              color clr, string tag, string label,
              int minSep, bool draw, int kFrom, int kTo, int &outIdx[])
{
   //--- collect candidates
   int    idxs[];
   double vals[];
   int n = 0;

   int kLo = (int)MathMax(1, kFrom);
   int kHi = (int)MathMin(g_profCount - 2, kTo);
   for(int k = kLo; k <= kHi; k++)
   {
      bool isPeak   = (sm[k] >= sm[k-1] && sm[k] >= sm[k+1] && sm[k] > sm[k-1] * 1.0001);
      bool isTrough = (sm[k] <= sm[k-1] && sm[k] <= sm[k+1] && sm[k] > 0.0);

      if(peaks)
      {
         if(!isPeak) continue;
         if(sm[k] < smMax * (pctLimit / 100.0)) continue;
      }
      else
      {
         if(!isTrough) continue;
         if(sm[k] > smMax * (pctLimit / 100.0)) continue;
      }
      ArrayResize(idxs, n + 1);
      ArrayResize(vals, n + 1);
      idxs[n] = k;
      vals[n] = sm[k];
      n++;
   }
   if(n == 0)
      return 0;

   //--- strongest (or emptiest) first, then enforce a minimum spacing
   for(int i = 0; i < n - 1; i++)
      for(int j = i + 1; j < n; j++)
      {
         bool swap = peaks ? (vals[j] > vals[i]) : (vals[j] < vals[i]);
         if(swap)
         {
            double tv = vals[i]; vals[i] = vals[j]; vals[j] = tv;
            int    ti = idxs[i]; idxs[i] = idxs[j]; idxs[j] = ti;
         }
      }

   int chosen[];
   int c = 0;
   for(int i = 0; i < n && c < InpMaxNodes; i++)
   {
      bool tooClose = false;
      for(int j = 0; j < c; j++)
         if(MathAbs(idxs[i] - chosen[j]) < minSep)
         {
            tooClose = true;
            break;
         }
      if(tooClose) continue;
      ArrayResize(chosen, c + 1);
      chosen[c++] = idxs[i];
   }

   if(draw)
      for(int i = 0; i < c; i++)
         MakeLine(tag + "_" + IntegerToString(i), BucketCenter(chosen[i]), clr,
                  peaks ? STYLE_SOLID : STYLE_DOT, 1, label);

   //--- hand the caller what we picked
   ArrayResize(outIdx, c);
   for(int i = 0; i < c; i++)
      outIdx[i] = chosen[i];

   //--- publishing moved to PublishHvn(): it must also happen when there are
   //--- no peaks at all, which the early return above used to skip
   return c;
}

//+------------------------------------------------------------------+
//| Stats panel, painted straight onto the heatmap canvas.  Dozens   |
//| of OBJ_LABELs would do the same job far more slowly.             |
//+------------------------------------------------------------------+
string FmtVol(double v)
{
   if(v >= 1000000.0) return DoubleToString(v / 1000000.0, 2) + "M";
   if(v >= 1000.0)    return DoubleToString(v / 1000.0, 2) + "K";
   return DoubleToString(v, 0);
}

//--- where the stats panel sits.  Shared with the countdown chip so the
//--- two always line up, whichever corner the panel is parked in.
bool DashIsTop()  { return (InpDashCorner == DASH_TOP_LEFT  || InpDashCorner == DASH_TOP_RIGHT); }
bool DashIsLeft() { return (InpDashCorner == DASH_TOP_LEFT  || InpDashCorner == DASH_BOTTOM_LEFT); }

void DashBoxRect(int w, int h, int &x0, int &y0, int &boxW, int &boxH)
{
   int pad = 6, lineH = 13;
   boxW = 178;
   boxH = pad * 2 + lineH * 9;
   switch(InpDashCorner)
   {
      case DASH_TOP_LEFT:     x0 = 8;            y0 = 48;           break;
      case DASH_BOTTOM_RIGHT: x0 = w - boxW - 8; y0 = h - boxH - 8; break;
      case DASH_BOTTOM_LEFT:  x0 = 8;            y0 = h - boxH - 8; break;
      default:                x0 = w - boxW - 8; y0 = 8;            break;
   }
   if(x0 < 0) x0 = 0;
   if(y0 < 0) y0 = 0;
}

//+------------------------------------------------------------------+
//| ================= BAR-CLOSE COUNTDOWN ========================== |
//| How long the forming candle still has to run, drawn as one more  |
//| row docked to the stats panel.                                   |
//|                                                                  |
//| It gets its OWN small canvas rather than a line in DrawDashboard |
//| because the panel lives on the main canvas, and the only way to  |
//| repaint that is Redraw() - which rebuilds the scope histogram,   |
//| the per-bar tick cells and the whole heatmap.  Running that once |
//| a second would be ruinous; repainting a 180x20 bitmap is free.   |
//+------------------------------------------------------------------+
//--- "PERIOD_M15" -> "M15"
string CdTfName()
{
   return StringSubstr(EnumToString((ENUM_TIMEFRAMES)Period()), 7);
}

//--- seconds until the current bar closes, -1 if it cannot be worked out.
//--- TimeTradeServer() runs off the local clock, so it keeps counting down
//--- through a dead session or a weekend; TimeCurrent() only moves on ticks.
int BarSecondsLeft()
{
   int      per = PeriodSeconds(PERIOD_CURRENT);
   datetime t0  = iTime(_Symbol, PERIOD_CURRENT, 0);
   if(per <= 0 || t0 == 0)
      return -1;

   datetime now = TimeTradeServer();
   if(now == 0) now = TimeCurrent();
   if(now == 0) return -1;

   long left = (long)t0 + (long)per - (long)now;
   if(left < 0)         left = 0;
   if(left > (long)per) left = per;
   return (int)left;
}

string CdClock(int s)
{
   if(s < 0)
      return "--:--";
   int h = s / 3600, m = (s % 3600) / 60, sec = s % 60;
   if(h > 0)
      return StringFormat("%d:%02d:%02d", h, m, sec);
   return StringFormat("%02d:%02d", m, sec);
}

string BarCountdownText()
{
   return CdTfName() + " close  " + CdClock(BarSecondsLeft());
}

//+------------------------------------------------------------------+
//| Repaint the chip and dock it to the stats panel: under it at the |
//| top corners, above it at the bottom ones.  With the panel off it |
//| simply takes the panel's slot.                                   |
//+------------------------------------------------------------------+
void DrawCountdown()
{
   if(!InpShowCountdown || !g_cdReady)
      return;

   int w = (int)ChartGetInteger(0, CHART_WIDTH_IN_PIXELS);
   int h = (int)ChartGetInteger(0, CHART_HEIGHT_IN_PIXELS, 0);
   if(w <= 0 || h <= 0)
      return;

   int left = BarSecondsLeft();
   if(left == g_cdLastSecs && !g_cdDirty)
      return;                               // nothing has changed since the last paint
   g_cdLastSecs = left;
   g_cdDirty    = false;

   string txt = BarCountdownText();

   g_cdCanvas.FontSet("Consolas", 12);
   int pad   = 6;
   int chipW = g_cdCanvas.TextWidth(txt)  + pad * 2;
   int chipH = g_cdCanvas.TextHeight(txt) + pad;
   if(chipW < 40) chipW = 40;
   if(chipH < 18) chipH = 18;

   //--- where the panel is (or would be), so the chip lines up with it
   int x0, y0, boxW, boxH;
   DashBoxRect(w, h, x0, y0, boxW, boxH);

   int x = DashIsLeft() ? x0 : x0 + boxW - chipW;   // right-align under a right-hand panel
   int y;
   if(DashIsTop())
      y = InpShowDash ? y0 + boxH + 4 : y0;
   else
      y = InpShowDash ? y0 - chipH - 4 : y0 + boxH - chipH;
   if(x < 0) x = 0;
   if(y < 0) y = 0;

   if(g_cdCanvas.Width() != chipW || g_cdCanvas.Height() != chipH)
      g_cdCanvas.Resize(chipW, chipH);
   if(x != g_cdX || y != g_cdY)
   {
      g_cdX = x;
      g_cdY = y;
      ObjectSetInteger(0, OF_CDCANVAS, OBJPROP_XDISTANCE, x);
      ObjectSetInteger(0, OF_CDCANVAS, OBJPROP_YDISTANCE, y);
   }

   //--- same fill, border and font as DrawDashboard, so it reads as one panel
   g_cdCanvas.Erase(ColorToARGB(clrBlack, 0));
   g_cdCanvas.FillRectangle(0, 0, chipW - 1, chipH - 1, ColorToARGB(C'22,22,22', 220));
   g_cdCanvas.Rectangle(0, 0, chipW - 1, chipH - 1, ColorToARGB(C'46,46,46', 255));
   color c = (left >= 0 && left <= InpCdWarnSecs) ? InpCdWarnColor : InpCdColor;
   g_cdCanvas.TextOut(pad, pad / 2, txt, ColorToARGB(c, 255));
   g_cdCanvas.Update();
}

//+------------------------------------------------------------------+
void DrawDashboard(int w, int h)
{
   if(!InpShowDash || g_profCount <= 0 || g_pocIdx < 0 || g_profTotal <= 0.0)
      return;

   double poc = BucketCenter(g_pocIdx);
   double vah = (g_vahIdx >= 0) ? BucketCenter(g_vahIdx) : 0.0;
   double val = (g_valIdx >= 0) ? BucketCenter(g_valIdx) : 0.0;

   double last = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   if(last <= 0.0) last = poc;

   //--- how the volume splits above and below the midpoint of the profile
   double pTop = ProfLowPrice(g_profMinIdx + g_profCount - 1) + g_profBucket;
   double pBot = ProfLowPrice(g_profMinIdx);
   double mid  = (pTop + pBot) * 0.5;
   double upper = 0.0, lower = 0.0;
   for(int k = 0; k < g_profCount; k++)
   {
      if(BucketCenter(k) >= mid) upper += g_profVol[k];
      else                       lower += g_profVol[k];
   }
   double upperPct = 100.0 * upper / g_profTotal;
   double lowerPct = 100.0 * lower / g_profTotal;
   double skew     = upper / MathMax(0.0001, lower);
   double distPoc  = (last - poc) / MathMax(0.0001, last) * 100.0;
   double rangeLoc = (pTop > pBot) ? (last - pBot) / (pTop - pBot) * 100.0 : 50.0;

   string rows[9];
   rows[0] = "LIQUIDITY DEPTH";
   rows[1] = "POC          " + DoubleToString(poc, g_digits);
   rows[2] = "Dist to POC  " + DoubleToString(distPoc, 2) + "%";
   rows[3] = "VA range     " + DoubleToString(val, g_digits) + " - " + DoubleToString(vah, g_digits);
   rows[4] = "Upper mass   " + DoubleToString(upperPct, 1) + "%";
   rows[5] = "Lower mass   " + DoubleToString(lowerPct, 1) + "%";
   rows[6] = "Mass skew    " + DoubleToString(skew, 2) + "x";
   rows[7] = "Range loc    " + DoubleToString(rangeLoc, 1) + "%";
   rows[8] = "Total vol    " + FmtVol(g_profTotal) + (g_useRealVol ? "" : " (ticks)");

   int pad = 6, lineH = 13;
   int x0, y0, boxW, boxH;
   DashBoxRect(w, h, x0, y0, boxW, boxH);

   g_canvas.FillRectangle(x0, y0, x0 + boxW, y0 + boxH, ColorToARGB(C'22,22,22', 220));
   g_canvas.Rectangle(x0, y0, x0 + boxW, y0 + boxH, ColorToARGB(C'46,46,46', 255));

   g_canvas.FontSet("Consolas", 12);
   for(int r = 0; r < 9; r++)
   {
      color c = (r == 0) ? clrWhite : InpDashText;
      g_canvas.TextOut(x0 + pad, y0 + pad + r * lineH, rows[r], ColorToARGB(c, 255));
   }
}

//+------------------------------------------------------------------+
//| Shade a price band right across the chart, on the same canvas as |
//| the heatmap so it sits behind the candles with real transparency |
//+------------------------------------------------------------------+
void ShadeBand(int kLo, int kHi, color clr, uchar alpha,
               double priceMin, double priceMax, int h, int w)
{
   double range = priceMax - priceMin;
   if(range <= 0.0)
      return;

   double pLow  = ProfLowPrice(g_profMinIdx + kLo);
   double pHigh = ProfLowPrice(g_profMinIdx + kHi) + g_profBucket;

   int yTop = (int)MathRound((priceMax - pHigh) / range * h);
   int yBot = (int)MathRound((priceMax - pLow)  / range * h);
   if(yBot < 0 || yTop > h)
      return;
   if(yTop < 0)  yTop = 0;
   if(yBot > h)  yBot = h;
   if(yBot <= yTop) yBot = yTop + 1;

   g_canvas.FillRectangle(0, yTop, w - 1, yBot - 1, ColorToARGB(clr, alpha));
}

//+------------------------------------------------------------------+
//| HVN band in pixel rows: faint see-through fill across the chart, |
//| plus a thin stronger top/bottom edge like the session boxes      |
//+------------------------------------------------------------------+
void ShadeBandPx(int yTop, int yBot, color clr, uchar alpha, int h, int w)
{
   if(yBot < 0 || yTop > h)
      return;
   if(yTop < 0) yTop = 0;
   if(yBot > h) yBot = h;
   if(yBot <= yTop) yBot = yTop + 1;

   g_canvas.FillRectangle(0, yTop, w - 1, yBot - 1, ColorToARGB(clr, alpha));
   if(InpHvnZoneEdges)
   {
      uchar edgeA = (uchar)MathMin(255, 3 * (int)alpha + 40);
      g_canvas.FillRectangle(0, yTop, w - 1, yTop, ColorToARGB(clr, edgeA));
      g_canvas.FillRectangle(0, yBot - 1, w - 1, yBot - 1, ColorToARGB(clr, edgeA));
   }
}

//+------------------------------------------------------------------+
double BucketCenter(int k)
{
   return ProfLowPrice(g_profMinIdx + k) + g_profBucket * 0.5;
}

//+------------------------------------------------------------------+
void MakeLine(string suffix, double price, color clr, ENUM_LINE_STYLE style, int width, string label)
{
   string name = OF_PREFIX + suffix;
   if(ObjectFind(0, name) < 0)
      ObjectCreate(0, name, OBJ_HLINE, 0, 0, price);
   ObjectSetDouble(0, name, OBJPROP_PRICE, price);
   ObjectSetInteger(0, name, OBJPROP_COLOR, clr);
   ObjectSetInteger(0, name, OBJPROP_STYLE, style);
   ObjectSetInteger(0, name, OBJPROP_WIDTH, width);
   ObjectSetInteger(0, name, OBJPROP_BACK, false);
   ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, name, OBJPROP_HIDDEN, true);
   ObjectSetString(0, name, OBJPROP_TOOLTIP, label + "  " + DoubleToString(price, g_digits));
}

//+------------------------------------------------------------------+
//| Always state on the chart what the volume actually is            |
//+------------------------------------------------------------------+
void DrawStatus()
{
   if(!InpShowStatus)
   {
      ObjectDelete(0, OF_STATUS);
      ObjectDelete(0, OF_STATUS2);
      return;
   }

   string scope = "visible";
   if(g_scope == SCOPE_SESSION) scope = "session";
   if(g_scope == SCOPE_ROLLING) scope = "rolling " + IntegerToString(InpRollingBars);
   if(g_scope == SCOPE_OFF)     scope = "off";

   string txt = "Heatmap " + g_tfStr + ": " + (g_usingBars ? "BAR data (no ticks)" : "tick data")
              + " / " + g_volLabel
              + "  |  price=" + g_prcLabel
              + "  |  cells=" + DoubleToString(g_bucketSize / g_point, 1) + "pts ("
              + DoubleToString(g_bucketSize, g_digits) + ")"
              + "  |  max " + IntegerToString(g_maxBars) + " bars";

   //--- line 2: the profile, and every warning that would otherwise be silent
   string warn = "";
   if(UseFullScope() && g_histTruncated) warn += "  |  PROFILE TRUNCATED";
   if(g_scope != SCOPE_OFF && g_warming)
      warn += "  |  PROFILE WARMING (" + IntegerToString(g_scopeBars) + "/" + IntegerToString(InpMinScopeBars) + ")";
   if(g_recencyForcedOff) warn += "  |  RECENCY OFF - SCOPE TOO LARGE";

   string txt2 = "Profile: " + scope + " " + IntegerToString(g_scopeBars) + " bars"
               + (UseFullScope() ? " (full scope)" : " (visible bars)")
               + ", bucket " + DoubleToString(g_profBucket, g_digits)
               + (UseFullScope() && g_histFallback > 0 ? ", " + IntegerToString(g_histFallback) + " from bar data" : "")
               + "  |  HVN " + (g_hvnLive ? "published " + g_tfStr + " n=" + IntegerToString(g_pubCount) : "not published")
               + warn;

   //--- canvas text: an OBJ_LABEL silently truncates at 63 characters
   ObjectDelete(0, OF_STATUS);
   ObjectDelete(0, OF_STATUS2);
   int len  = (int)MathMax(StringLen(txt), StringLen(txt2));
   int boxW = len * 7 + 10;
   g_canvas.FillRectangle(2, 16, 2 + boxW, 16 + 2 * 15 + 3, ColorToARGB(clrBlack, 150));
   g_canvas.FontSet("Arial", 12);
   g_canvas.TextOut(6, 18, txt,  ColorToARGB(g_useRealVol ? clrLimeGreen : clrOrange, 255));
   g_canvas.TextOut(6, 33, txt2, ColorToARGB((warn != "") ? clrOrangeRed : clrSilver, 255));
}
//+------------------------------------------------------------------+
