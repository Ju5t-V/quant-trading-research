//+------------------------------------------------------------------+
//|                                                OF_Absorption.mq5 |
//|  Absorption detection from tick-level buy/sell pressure          |
//|                                                                  |
//|  WHAT ABSORPTION IS                                              |
//|   A lot of aggressive trade hits one area and price refuses to   |
//|   move.  Sellers keep hitting the bid, but a passive buyer is    |
//|   sitting there soaking up everything they throw - so the bar    |
//|   ends up with heavy volume, a small range, strongly negative    |
//|   delta, and a close back at the top.  That is someone big       |
//|   defending a level, and it often marks the turn.                |
//|                                                                  |
//|  THE TEST APPLIED TO EVERY BAR (all thresholds are inputs)       |
//|   1. volume  >= K x its own recent average       (heavy)         |
//|   2. range   <= R x ATR(14)                      (going nowhere) |
//|   3. delta one-sided                             (real pressure) |
//|   4. the close finishes AGAINST that pressure    (it failed)     |
//|   Thresholds are not guesses: measured on 1000 XAUUSD M5 bars,   |
//|   the shipped defaults fire ~2x per trading day.  Note that      |
//|   tick-rule delta on a CFD is a SMALL number - it almost never   |
//|   exceeds 0.30 - so 0.12 here is selective, not loose.           |
//|   Pass all four and the bar is marked, with a line drawn at the  |
//|   bar's own point of control - the exact price being defended.   |
//|                                                                  |
//|  HONESTY NOTE ON AGGRESSOR SIDE                                  |
//|   On an exchange feed each trade says whether it hit the bid or  |
//|   the ask, so delta is a fact.  On a CFD like XAUUSD there is no |
//|   such flag, so the side is INFERRED with the tick rule.  The    |
//|   status line on the chart always tells you which one you are    |
//|   looking at.  Inferred delta is useful but it is an estimate,   |
//|   and it is worth less on thin, fast moves.                      |
//|                                                                  |
//|  Pairs with OF_Heatmap.mq5, which can publish its HVN levels so  |
//|  absorption can be filtered to only fire at those shelves.       |
//|                                                                  |
//|  v1.10 (2026-09-13): tolerance modes, time-of-day volume         |
//|  baseline, optional timeframe auto-tune (default OFF - guesses), |
//|  timeframe-namespaced HVN source with staleness blocking,        |
//|  distribution log, firing-rate diagnostics, and a CSV log.       |
//+------------------------------------------------------------------+
#property copyright "Jerry"
#property version   "1.10"
#property description "Marks bars where heavy one-sided flow was absorbed and price refused to move"
#property indicator_chart_window
#property indicator_buffers 0
#property indicator_plots   0

#include <Canvas\Canvas.mqh>

enum ENUM_ABS_METHOD
{
   ABSMETH_UNUSUAL = 0,  // Unusual volume only (volume Z-score + RVOL) - LuxAlgo's rule
   ABSMETH_IMPACT  = 1,  // Z-score + price impact (the published absorption definition)
   ABSMETH_CLASSIC = 2   // Volume ratio + range + delta (the first version)
};

enum ENUM_ABS_VOL
{
   AVOL_AUTO      = 0,  // Auto-detect (real volume if the feed has it)
   AVOL_REAL      = 1,  // Real traded volume only
   AVOL_TICKCOUNT = 2   // Tick count (every tick counts as 1)
};

enum ENUM_BASELINE
{
   BASE_ROLLING   = 0,  // Rolling - flat window of recent bars (v1.00)
   BASE_TIMEOFDAY = 1   // Time of day - same intraday slot on previous days
};

enum ENUM_TOL_MODE
{
   TOL_POINTS = 0,  // Points - InpHvnTolPoints / InpStackTolPoints (current behaviour)
   TOL_PRICE  = 1,  // Price units - InpHvnTolPrice / InpStackTolPrice
   TOL_AUTO   = 2   // Auto - derive from symbol tick size and timeframe
};

enum ENUM_HVN_STALE
{
   HVNSTALE_BLOCK = 0,  // Block signals while the HVN set is stale or absent
   HVNSTALE_PASS  = 1   // Let signals through (marked) while stale or absent
};

input group "=== Detection ==="
input ENUM_ABS_METHOD InpMethod = ABSMETH_UNUSUAL; // Detection method
input int    InpLookbackBars   = 400;   // Bars scanned on load
input double InpVolZ           = 2.0;   // Volume Z-score needed (both Z methods)
input int    InpZWindow        = 200;   // Unusual method: bars in the Z-score window
input double InpMinRvol        = 1.5;   // Unusual method: volume / average must exceed this
input double InpLabelMinZ      = 3.0;   // Only print the volume on bubbles above this Z
input double InpMaxImpact      = 0.6;   // Impact method: max move per unit volume vs normal
input int    InpStatWindow     = 100;   // Impact method: bars used for the rolling baseline
input double InpVolMult        = 1.5;   // Classic method: volume x the recent average
input int    InpVolAvgBars     = 50;    // Bars in the volume average
input double InpRangeMult      = 0.8;   // Range must stay under this x ATR(14)
input int    InpAtrPeriod      = 14;    // ATR period
input double InpMinDeltaRatio  = 0.12;  // Delta must be at least this share of the bar's volume
input double InpClosePos       = 0.60;  // Close must finish this far against the pressure (0.5-1.0)
input ENUM_BASELINE InpBaselineMode = BASE_TIMEOFDAY; // Volume baseline for Z-score and impact
input int    InpBaselineDays   = 20;    // Time of day: previous trading days sampled
input int    InpBaselineMinSamples = 10; // Time of day: fewer samples than this -> rolling fallback
input bool   InpAutoTune       = false; // Scale MinDeltaRatio/MaxImpact/RangeMult by timeframe (unmeasured guesses)

input group "=== Filters ==="
input bool   InpRequireHVN     = false; // Only fire at an HVN published by OF_Heatmap
input double InpHvnTolPoints   = 150;   // How close to the HVN, in points
input int    InpStackMin       = 2;     // Bars needed to call it a stacked zone
input double InpStackTolPoints = 200;   // How close two absorptions must be to stack
input int    InpStackWindow    = 30;    // Bars within which stacking counts
input ENUM_TOL_MODE InpTolMode = TOL_POINTS; // How the two tolerances are chosen
input double InpHvnTolPrice    = 1.50;  // HVN tolerance in PRICE units (Price mode)
input double InpStackTolPrice  = 2.00;  // Stack tolerance in PRICE units (Price mode)
input ENUM_TIMEFRAMES InpHvnSource = PERIOD_CURRENT; // Which timeframe's OF_Heatmap HVN set to read
input int    InpHvnMaxAgeSec   = 300;   // HVN set older than this is stale
input ENUM_HVN_STALE InpHvnStaleAction = HVNSTALE_BLOCK; // With RequireHVN: what to do when stale/absent

enum ENUM_ABS_MARKER
{
   ABSM_BUBBLE = 0,  // Volume bubble: size scales with the absorbed volume
   ABSM_CIRCLE = 1,  // Ring drawn around the defended price
   ABSM_DOT    = 2,  // Filled dot above/below the bar
   ABSM_ARROW  = 3   // Arrow above/below the bar
};

input group "=== Display ==="
input ENUM_ABS_MARKER InpMarkerStyle = ABSM_BUBBLE; // How to mark an absorption bar
input double InpCircleBars     = 2.5;   // Ring half-width, in bars
input double InpCircleAtr      = 0.45;  // Ring half-height, x ATR(14)
input double InpBubbleMinBars  = 1.0;   // Bubble: smallest radius, in bars
input double InpBubbleMaxBars  = 4.0;   // Bubble: largest radius, in bars
input double InpBubbleOffsetAtr= 1.2;   // Bubble: distance from the bar, x ATR(14)
input bool   InpBubbleLabel    = true;  // Bubble: print the absorbed volume on it
input bool   InpBubbleStem     = true;  // Bubble: dotted line down to the defended price
input int    InpExtendBars     = 40;    // How far forward to extend an absorption level
input color  InpBullColor      = clrDeepSkyBlue; // Bullish absorption (sellers soaked up)
input color  InpBearColor      = clrOrangeRed;   // Bearish absorption (buyers soaked up)
input color  InpZoneColor      = clrGold;        // Stacked zone
input bool   InpShowArrows     = true;  // Draw the marker on the bars
input bool   InpShowLevels     = true;  // Draw the defended price level
input bool   InpShowStatus     = true;  // Show the data-source status line

input group "=== Alerts ==="
input bool   InpAlertPopup     = false; // Popup alert on a new absorption
input bool   InpAlertPush      = false; // Push notification to the MT5 phone app
input ENUM_ABS_VOL InpVolSource = AVOL_AUTO; // Volume source

input group "=== CSV log ==="
input bool   InpLogCSV         = false; // Append every method-pass bar to MQL5\Files\OF_Absorption_<sym>_<tf>.csv
input int    InpServerGMT      = 3;     // Server offset from GMT, for the session column
input int    InpAsiaStartGMT   = 0;     // Asia start hour (GMT)
input int    InpAsiaEndGMT     = 9;     // Asia end hour (GMT)
input int    InpLondonStartGMT = 7;     // London start hour (GMT)
input int    InpLondonEndGMT   = 16;    // London end hour (GMT)
input int    InpNYStartGMT     = 12;    // New York start hour (GMT)
input int    InpNYEndGMT       = 21;    // New York end hour (GMT)

#define AB_PREFIX  "OFAB_"
#define AB_STATUS  AB_PREFIX "status"
#define AB_STATUS2 AB_PREFIX "status2"
#define AB_STATUS3 AB_PREFIX "status3"

#define HVN_UNKNOWN -1
#define HVN_FRESH    0
#define HVN_STALE    1
#define HVN_ABSENT   2

//--- what we worked out about one bar
struct AbsBar
{
   datetime t;
   double   buyVol;
   double   sellVol;
   double   delta;
   double   total;
   double   poc;      // price inside the bar where most volume traded
   double   barVol;   // the bar's own volume, as the terminal reports it
   double   volZ;
   double   impact;
   double   high;
   double   low;
   double   atr;
   bool     isAbs;
   bool     bullish;
   //--- v1.10 diagnostics, for the CSV
   bool     hvnPassed;
   double   hvnDist;    // -1 = no fresh HVN set
   int      hvnStatus;  // HVN_FRESH / HVN_STALE / HVN_ABSENT
   int      baseN;      // samples behind the Z-score
   bool     baseTod;    // time-of-day baseline actually used (not fallback)
   bool     spansDst;
};

AbsBar   g_bars[];
int      g_barCount   = 0;
bool     g_useRealVol = false;
bool     g_realAggr   = false;
string   g_volLabel   = "";
string   g_aggLabel   = "";
int      g_atrHandle  = INVALID_HANDLE;
double   g_point      = 0.0;
int      g_digits     = 5;
datetime g_lastClosed = 0;
datetime g_lastAlert  = 0;

//--- resolved settings (inputs are only read in OnInit)
double   g_hvnTol        = 0.0;
double   g_stackTol      = 0.0;
double   g_minDeltaRatio = 0.12;
double   g_maxImpact     = 0.6;
double   g_rangeMult     = 0.8;
string   g_tfStr         = "";
string   g_hvnTfStr      = "";

//--- HVN source state
int      g_hvnState      = HVN_UNKNOWN;
int      g_hvnAge        = -1;
int      g_hvnCount      = 0;
double   g_hvnLevels[];
double   g_hvnBucket     = 0.0;
bool     g_hvnLegacy     = false;

//--- diagnostics from the last Rebuild
int      g_baseNewestN   = 0;
int      g_baseMedianN   = 0;
int      g_baseFallback  = 0;
int      g_baseScored    = 0;
int      g_sig24h        = 0;
int      g_scanDays      = 0;
bool     g_statsLogged   = false;

//--- CSV
string   g_csvName       = "";
bool     g_csvOk         = false;
string   g_csvError      = "";
datetime g_csvLastTs     = 0;       // newest bar written or queued
datetime g_attachBar     = 0;       // forming bar when first calculated: only bars from here are "live"
bool     g_csvErrLogged  = false;

//--- status panel: canvas text, because an OBJ_LABEL truncates at 63 characters
#define  AB_CANVAS "OFABC_status"      // outside AB_PREFIX so Rebuild never deletes it
CCanvas  g_status;
string   g_stTxt[3];
color    g_stClr[3];
string   g_stLast        = "";
ulong    g_lastEmptyRetry = 0;

//+------------------------------------------------------------------+
int OnInit()
{
   g_point  = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   g_digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   if(g_point <= 0.0)
      g_point = MathPow(10, -g_digits);

   g_atrHandle = iATR(_Symbol, PERIOD_CURRENT, InpAtrPeriod);
   if(g_atrHandle == INVALID_HANDLE)
   {
      Print("OF_Absorption: could not create ATR handle");
      return INIT_FAILED;
   }

   DetectFeed();

   g_tfStr = TfString((ENUM_TIMEFRAMES)Period());
   ResolveTolerances();
   ResolveAutoTune();
   ResolveHvnSource();
   Print("OF_Absorption ", _Symbol, " ", g_tfStr, ": baseline ",
         (InpBaselineMode == BASE_TIMEOFDAY ? "TIME-OF-DAY" : "ROLLING"),
         " (days=", InpBaselineDays, ", min samples=", InpBaselineMinSamples, ")",
         (InpBaselineMode == BASE_TIMEOFDAY && !UseTod() ? " - not applicable on D1 and above, rolling used" : ""));
   if(InpLogCSV)
      CsvInit();

   if(InpShowStatus)
   {
      if(!g_status.CreateBitmapLabel(0, 0, AB_CANVAS, 6, 46, 400, 48, COLOR_FORMAT_ARGB_NORMALIZE))
         Print("OF_Absorption: could not create status canvas, error ", GetLastError());
      ObjectSetInteger(0, AB_CANVAS, OBJPROP_BACK, false);
      ObjectSetInteger(0, AB_CANVAS, OBJPROP_SELECTABLE, false);
      ObjectSetInteger(0, AB_CANVAS, OBJPROP_HIDDEN, true);
   }

   //--- ticks do not arrive at weekends or in quiet spells, so HVN freshness and
   //--- "no data yet" retries run on a timer instead of waiting for OnCalculate
   EventSetMillisecondTimer(1000);
   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   EventKillTimer();
   g_status.Destroy();
   if(g_atrHandle != INVALID_HANDLE)
      IndicatorRelease(g_atrHandle);
   ObjectsDeleteAll(0, AB_PREFIX);
   ChartRedraw();
}

//+------------------------------------------------------------------+
//| "PERIOD_M5" -> "M5".  Same string OF_Heatmap uses for its globals |
//+------------------------------------------------------------------+
string TfString(ENUM_TIMEFRAMES tf)
{
   string s = EnumToString(tf);
   StringReplace(s, "PERIOD_", "");
   return s;
}

//+------------------------------------------------------------------+
double TickSize()
{
   return MathMax(SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE), g_point);
}

//+------------------------------------------------------------------+
//| AUTO tolerance scaling by bar length, relative to M5.  GUESSES,   |
//| not measured - a longer bar has a wider noise band.               |
//+------------------------------------------------------------------+
double TolTfRatio()
{
   int ps = PeriodSeconds(PERIOD_CURRENT);
   if(ps <= 60)    return 0.5;
   if(ps <= 300)   return 1.0;
   if(ps <= 900)   return 2.0;
   if(ps <= 1800)  return 3.0;
   if(ps <= 3600)  return 5.0;
   if(ps <= 14400) return 10.0;
   return 20.0;
}

//+------------------------------------------------------------------+
//| bpAtM5 x price x timeframe ratio, rounded to whole ticks (>= 1)   |
//+------------------------------------------------------------------+
double AutoTol(double bpAtM5)
{
   double tick = TickSize();
   double ref  = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   if(ref <= 0.0)
      ref = iClose(_Symbol, PERIOD_CURRENT, 0);
   double target = ref * bpAtM5 / 10000.0 * TolTfRatio();
   long n = (long)MathRound(target / tick);
   if(n < 1) n = 1;
   return (double)n * tick;
}

//+------------------------------------------------------------------+
void ResolveTolerances()
{
   //--- the v1.00 defaults on a 2-digit gold feed near $4000:
   //--- 150 pts = $1.50 = 3.75bp, 200 pts = $2.00 = 5bp, at M5
   double autoH = AutoTol(3.75);
   double autoS = AutoTol(5.0);
   string mode  = "POINTS";

   g_hvnTol   = InpHvnTolPoints   * g_point;
   g_stackTol = InpStackTolPoints * g_point;
   if(InpTolMode == TOL_PRICE)
   {
      mode = "PRICE";
      if(InpHvnTolPrice > 0.0)   g_hvnTol   = InpHvnTolPrice;
      else Print("OF_Absorption ERROR: Price mode with InpHvnTolPrice <= 0 - using points");
      if(InpStackTolPrice > 0.0) g_stackTol = InpStackTolPrice;
      else Print("OF_Absorption ERROR: Price mode with InpStackTolPrice <= 0 - using points");
   }
   else if(InpTolMode == TOL_AUTO)
   {
      mode = "AUTO";
      g_hvnTol   = autoH;
      g_stackTol = autoS;
   }

   Print(StringFormat("OF_Absorption %s %s: digits=%d point=%s tick_size=%s | tolerance mode=%s",
                      _Symbol, g_tfStr, g_digits, DoubleToString(g_point, g_digits + 1),
                      DoubleToString(SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE), g_digits + 1), mode));
   Print(StringFormat("OF_Absorption   HVN tol in use %.1f pts = %s price | AUTO would pick %.1f pts = %s price",
                      g_hvnTol / g_point, DoubleToString(g_hvnTol, g_digits),
                      autoH / g_point, DoubleToString(autoH, g_digits)));
   Print(StringFormat("OF_Absorption   stack tol in use %.1f pts = %s price | AUTO would pick %.1f pts = %s price",
                      g_stackTol / g_point, DoubleToString(g_stackTol, g_digits),
                      autoS / g_point, DoubleToString(autoS, g_digits)));
}

//+------------------------------------------------------------------+
//| Timeframe scaling of the three thresholds.  DEFAULT OFF.          |
//| These factors are STARTING GUESSES, NOT MEASURED VALUES.  Delta   |
//| ratio uses sqrt(M5 bar length / this bar length): under           |
//| independent +-1 ticks |delta|/n shrinks like 1/sqrt(n).  That     |
//| rule is unverified on this feed - if the ~0.30 ceiling is a       |
//| property of the tick-rule classifier rather than of M5, the M1    |
//| value (0.27) would silently stop CLASSIC firing.  Impact and range |
//| are already normalised to their own timeframe, so they stay ~1.   |
//| Re-measure them with the distribution log printed on attach.      |
//| Note: DeltaRatio and RangeMult only gate CLASSIC; MaxImpact only  |
//| gates IMPACT; UNUSUAL uses none of the three.                     |
//+------------------------------------------------------------------+
void ResolveAutoTune()
{
   g_minDeltaRatio = InpMinDeltaRatio;
   g_maxImpact     = InpMaxImpact;
   g_rangeMult     = InpRangeMult;

   if(!InpAutoTune)
   {
      Print("OF_Absorption auto-tune off: MinDeltaRatio ", DoubleToString(g_minDeltaRatio, 3),
            ", MaxImpact ", DoubleToString(g_maxImpact, 3), ", RangeMult ", DoubleToString(g_rangeMult, 3),
            " used exactly as given");
      return;
   }

   double fd = 1.0, fi = 1.0, fr = 1.0;
   bool   found = true;
   switch(PeriodSeconds(PERIOD_CURRENT))
   {
      case 60:   fd = 2.24; fi = 1.0; fr = 1.1; break;
      case 300:  fd = 1.00; fi = 1.0; fr = 1.0; break;
      case 900:  fd = 0.58; fi = 1.0; fr = 1.0; break;
      case 1800: fd = 0.41; fi = 1.0; fr = 1.0; break;
      case 3600: fd = 0.29; fi = 1.0; fr = 1.0; break;
      default:   found = false;
   }
   if(!found)
   {
      Print("OF_Absorption auto-tune: no table entry for ", g_tfStr, " - thresholds unscaled");
      return;
   }
   g_minDeltaRatio = InpMinDeltaRatio * fd;
   g_maxImpact     = InpMaxImpact     * fi;
   g_rangeMult     = InpRangeMult     * fr;
   Print(StringFormat("OF_Absorption auto-tune %s (GUESSES): MinDeltaRatio %.3f -> %.3f | MaxImpact %.3f -> %.3f | RangeMult %.3f -> %.3f",
                      g_tfStr, InpMinDeltaRatio, g_minDeltaRatio, InpMaxImpact, g_maxImpact,
                      InpRangeMult, g_rangeMult));
}

//+------------------------------------------------------------------+
void ResolveHvnSource()
{
   ENUM_TIMEFRAMES tf = (InpHvnSource == PERIOD_CURRENT) ? (ENUM_TIMEFRAMES)Period() : InpHvnSource;
   g_hvnTfStr = TfString(tf);
   Print("OF_Absorption: HVN source = OF_Heatmap on ", g_hvnTfStr,
         " (reads OFHM_", _Symbol, "_", g_hvnTfStr, "_hvn_*)");
   if(PeriodSeconds(tf) < PeriodSeconds(PERIOD_CURRENT))
      Print("OF_Absorption WARNING: HVN source ", g_hvnTfStr, " is LOWER than the chart (", g_tfStr,
            ") - filtering bars against a finer timeframe's shelves makes no sense");
}

//+------------------------------------------------------------------+
//| Find out whether volume and aggressor side are real or inferred  |
//+------------------------------------------------------------------+
void DetectFeed()
{
   MqlTick ticks[];
   datetime to   = TimeCurrent();
   datetime from = to - 6 * 3600;
   int got = CopyTicksRange(_Symbol, ticks, COPY_TICKS_ALL, (ulong)from * 1000, (ulong)to * 1000);

   int n = (int)MathMin(got, 20000);
   int withReal = 0, withSide = 0;
   for(int i = 0; i < n; i++)
   {
      if(ticks[i].volume_real > 0.0) withReal++;
      if((ticks[i].flags & (TICK_FLAG_BUY | TICK_FLAG_SELL)) != 0) withSide++;
   }

   if(InpVolSource == AVOL_REAL)           g_useRealVol = true;
   else if(InpVolSource == AVOL_TICKCOUNT) g_useRealVol = false;
   else                                    g_useRealVol = (n > 0 && withReal > n / 2);

   g_realAggr = (n > 0 && withSide > n / 10);

   g_volLabel = g_useRealVol ? "REAL volume" : "tick count";
   g_aggLabel = g_realAggr   ? "REAL aggressor side" : "INFERRED side (tick rule)";
}

//+------------------------------------------------------------------+
int OnCalculate(const int rates_total, const int prev_calculated,
                const datetime &time[], const double &open[], const double &high[],
                const double &low[], const double &close[], const long &tick_volume[],
                const long &volume[], const int &spread[])
{
   if(rates_total < InpAtrPeriod + 5)
      return rates_total;

   //--- bars from here on close while attached, so they are "live" for the CSV
   if(g_attachBar == 0)
      g_attachBar = time[rates_total-1];

   //--- HVN freshness is checked every tick (a cheap global read)
   bool hvnChanged = HvnUpdateState();

   //--- only work on closed bars; the forming bar changes under us.
   //--- A new bar and an HVN transition in the same pass give ONE Rebuild.  CSV
   //--- rows are keyed on bar time (> last written, >= attach bar), so however the
   //--- two events are ordered a bar is written exactly once and never skipped.
   datetime newestClosed = iTime(_Symbol, PERIOD_CURRENT, 1);
   if(newestClosed == g_lastClosed && prev_calculated > 0 && !hvnChanged)
   {
      DrawStatus();       // keeps the HVN age current between bars
      return rates_total;
   }
   g_lastClosed = newestClosed;

   Rebuild(rates_total, time, open, high, low, close);
   return rates_total;
}

//+------------------------------------------------------------------+
//| Once a second: re-read HVN freshness (no ticks needed), and while |
//| the last scan found no analysable bars - ticks still downloading  |
//| after attach - retry every 15 s instead of waiting for a new bar. |
//+------------------------------------------------------------------+
void OnTimer()
{
   if(g_attachBar == 0)
      return;                 // not calculated yet: a rebuild now could log history to the CSV

   bool  changed = HvnUpdateState();
   bool  empty   = (g_baseScored == 0);
   ulong now     = GetTickCount64();

   if(changed || (empty && now - g_lastEmptyRetry >= 15000))
   {
      if(empty)
         g_lastEmptyRetry = now;
      RebuildFromTimer();
   }
   else
      DrawStatus();
}

//+------------------------------------------------------------------+
//| Rebuild needs the OnCalculate price arrays; copy just enough bars |
//| (chronological, oldest first - the same layout OnCalculate gives) |
//+------------------------------------------------------------------+
void RebuildFromTimer()
{
   int total = Bars(_Symbol, PERIOD_CURRENT);
   int m = (int)MathMin(total, InpLookbackBars + InpVolAvgBars + 10);
   if(m < InpAtrPeriod + 5)
      return;

   datetime t[];
   double   o[], hi[], lo[], c[];
   if(CopyTime(_Symbol, PERIOD_CURRENT, 0, m, t)   != m) return;
   if(CopyOpen(_Symbol, PERIOD_CURRENT, 0, m, o)   != m) return;
   if(CopyHigh(_Symbol, PERIOD_CURRENT, 0, m, hi)  != m) return;
   if(CopyLow(_Symbol, PERIOD_CURRENT, 0, m, lo)   != m) return;
   if(CopyClose(_Symbol, PERIOD_CURRENT, 0, m, c)  != m) return;
   Rebuild(m, t, o, hi, lo, c);
}

//+------------------------------------------------------------------+
//| Split one bar's ticks into aggressive buying and selling         |
//+------------------------------------------------------------------+
bool AnalyseBar(datetime barTime, int periodSec, AbsBar &out)
{
   MqlTick ticks[];
   ulong from = (ulong)barTime * 1000;
   ulong to   = (ulong)(barTime + periodSec) * 1000 - 1;
   int got = CopyTicksRange(_Symbol, ticks, COPY_TICKS_ALL, from, to);

   out.t       = barTime;
   out.buyVol  = 0.0;
   out.sellVol = 0.0;
   out.delta   = 0.0;
   out.total   = 0.0;
   out.poc     = 0.0;
   out.isAbs   = false;
   out.bullish = false;
   if(got <= 0)
      return false;

   //--- bar point of control, on a fine grid
   double grid = g_point * 10.0;
   double pocPrices[];
   double pocVols[];
   int    pocN = 0;

   double prevBid = 0.0;
   int    prevDir = 0;   // +1 buy, -1 sell

   for(int i = 0; i < got; i++)
   {
      //--- COPY_TICKS_ALL also returns ask-only quote updates.  Those are not
      //--- trades and carry no pressure, so counting them would pad both sides
      //--- of the delta with noise.  Keep the ticks that moved the price.
      uint pf = ticks[i].flags;
      if(g_realAggr || ticks[i].last > 0.0)
      {
         if((pf & TICK_FLAG_LAST) == 0) continue;
      }
      else if((pf & TICK_FLAG_BID) == 0)
         continue;

      double vol = 1.0;
      if(g_useRealVol)
         vol = (ticks[i].volume_real > 0.0) ? ticks[i].volume_real : (double)ticks[i].volume;

      //--- which side was the aggressor?
      int dir = 0;
      uint f = ticks[i].flags;
      if(g_realAggr && (f & TICK_FLAG_BUY) != 0)
         dir = 1;
      else if(g_realAggr && (f & TICK_FLAG_SELL) != 0)
         dir = -1;
      else if(ticks[i].last > 0.0 && ticks[i].ask > 0.0 && ticks[i].bid > 0.0)
      {
         // a real trade print: did it lift the offer or hit the bid?
         if(ticks[i].last >= ticks[i].ask)      dir = 1;
         else if(ticks[i].last <= ticks[i].bid) dir = -1;
         else                                   dir = prevDir;
      }
      else if(ticks[i].bid > 0.0)
      {
         // quote-only CFD feed: fall back on the tick rule
         if(prevBid > 0.0)
         {
            if(ticks[i].bid > prevBid)      dir = 1;
            else if(ticks[i].bid < prevBid) dir = -1;
            else                            dir = prevDir;
         }
         prevBid = ticks[i].bid;
      }
      if(dir == 0)
         dir = prevDir;
      if(dir == 0)
         continue;
      prevDir = dir;

      if(dir > 0) out.buyVol  += vol;
      else        out.sellVol += vol;
      out.total += vol;

      //--- accumulate for the bar POC
      double p = (ticks[i].last > 0.0) ? ticks[i].last : ticks[i].bid;
      if(p <= 0.0)
         continue;
      double cell = MathFloor(p / grid) * grid;
      int found = -1;
      for(int k = 0; k < pocN; k++)
         if(MathAbs(pocPrices[k] - cell) < grid * 0.5) { found = k; break; }
      if(found < 0)
      {
         ArrayResize(pocPrices, pocN + 1, 512);
         ArrayResize(pocVols,   pocN + 1, 512);
         pocPrices[pocN] = cell;
         pocVols[pocN]   = vol;
         pocN++;
      }
      else
         pocVols[found] += vol;
   }

   out.delta = out.buyVol - out.sellVol;

   double best = -1.0;
   for(int k = 0; k < pocN; k++)
      if(pocVols[k] > best) { best = pocVols[k]; out.poc = pocPrices[k] + grid * 0.5; }

   return (out.total > 0.0);
}

//+------------------------------------------------------------------+
//| Bar volume as the terminal reports it: real contracts where the  |
//| feed carries them, otherwise the tick count                      |
//+------------------------------------------------------------------+
double BarVolume(int shift)
{
   if(g_useRealVol)
   {
      double rv = (double)iRealVolume(_Symbol, PERIOD_CURRENT, shift);
      if(rv > 0.0)
         return rv;
   }
   return (double)iTickVolume(_Symbol, PERIOD_CURRENT, shift);
}

//+------------------------------------------------------------------+
//| How unusual is this bar's participation?  A Z-score normalises by |
//| the spread of recent volume, which a plain ratio-to-mean does not.|
//+------------------------------------------------------------------+
double VolumeZ(int shift, int window)
{
   int w = window;
   if(Bars(_Symbol, PERIOD_CURRENT) < shift + w + 2)
      return 0.0;

   double sum = 0.0, sum2 = 0.0;
   for(int k = shift + 1; k <= shift + w; k++)
   {
      double x = BarVolume(k);
      sum  += x;
      sum2 += x * x;
   }
   double mean = sum / w;
   double var  = sum2 / w - mean * mean;
   if(var <= 0.0)
      return 0.0;
   return (BarVolume(shift) - mean) / MathSqrt(var);
}

//+------------------------------------------------------------------+
//| Relative price impact: how far price actually travelled, against  |
//| how far this much volume normally moves it.  Cont/Kukanov/Stoikov |
//| show price change is roughly linear in order flow with a slope    |
//| inversely proportional to depth - so a LOW ratio here is the      |
//| signature of depth soaking the flow up, which is absorption.      |
//+------------------------------------------------------------------+
double ImpactRatio(int shift)
{
   int w = InpStatWindow;
   if(Bars(_Symbol, PERIOD_CURRENT) < shift + w + 2)
      return -1.0;

   double ratios[];
   ArrayResize(ratios, w);
   int cnt = 0;
   for(int k = shift + 1; k <= shift + w; k++)
   {
      double vol = BarVolume(k);
      if(vol <= 0.0) continue;
      double mv = MathAbs(iClose(_Symbol, PERIOD_CURRENT, k) - iOpen(_Symbol, PERIOD_CURRENT, k));
      ratios[cnt++] = mv / vol;
   }
   if(cnt < 20)
      return -1.0;
   ArrayResize(ratios, cnt);
   ArraySort(ratios);
   double baseline = ratios[cnt / 2];          // median move per unit volume
   if(baseline <= 0.0)
      return -1.0;

   double vNow = BarVolume(shift);
   if(vNow <= 0.0)
      return -1.0;
   double expected = baseline * vNow;
   if(expected <= 0.0)
      return -1.0;
   double actual = MathAbs(iClose(_Symbol, PERIOD_CURRENT, shift) - iOpen(_Symbol, PERIOD_CURRENT, shift));
   return actual / expected;
}

//+------------------------------------------------------------------+
//| TIME-OF-DAY BASELINE                                              |
//| A bar starting at T is scored against the SAME intraday slot on   |
//| previous trading days, not against last night's thin Asian tape.  |
//|                                                                  |
//| DST: the slot key is the SERVER clock.  If the server's GMT offset |
//| changes, or US and EU clocks change on different dates (EU ends   |
//| 25 Oct 2026, US 1 Nov 2026), the real-world session sits one slot |
//| away for that stretch, and a 20-day window mixes samples from    |
//| both sides of a change for up to ~a month.  This is NOT solved -  |
//| the CSV flags affected rows in baseline_spans_dst instead.        |
//+------------------------------------------------------------------+
bool UseTod()
{
   return (InpBaselineMode == BASE_TIMEOFDAY && PeriodSeconds(PERIOD_CURRENT) < 86400);
}

//+------------------------------------------------------------------+
//| Shifts of the same slot on up to InpBaselineDays previous days.   |
//| Weekends, holidays and bars not in history are ABSENT - skipped,  |
//| never counted as zero volume.                                     |
//+------------------------------------------------------------------+
int SlotSamples(int shift, int &shifts[])
{
   datetime T = iTime(_Symbol, PERIOD_CURRENT, shift);
   int n = 0;
   int maxDays = 2 * InpBaselineDays + 7;
   ArrayResize(shifts, 0);
   for(int d = 1; d <= maxDays && n < InpBaselineDays; d++)
   {
      int k = iBarShift(_Symbol, PERIOD_CURRENT, T - (datetime)(d * 86400), true);
      if(k < 0)
         continue;
      ArrayResize(shifts, n + 1, 32);
      shifts[n++] = k;
   }
   return n;
}

//+------------------------------------------------------------------+
double VolumeZTod(int shift, const int &sh[], int n)
{
   if(n <= 0)
      return 0.0;
   double sum = 0.0, sum2 = 0.0;
   for(int i = 0; i < n; i++)
   {
      double x = BarVolume(sh[i]);
      sum  += x;
      sum2 += x * x;
   }
   double mean = sum / n;
   double var  = sum2 / n - mean * mean;      // population variance, as VolumeZ
   if(var <= 0.0)
      return 0.0;
   return (BarVolume(shift) - mean) / MathSqrt(var);
}

//+------------------------------------------------------------------+
double ImpactRatioTod(int shift, const int &sh[], int n)
{
   double ratios[];
   ArrayResize(ratios, n);
   int cnt = 0;
   for(int i = 0; i < n; i++)
   {
      double vol = BarVolume(sh[i]);
      if(vol <= 0.0) continue;
      double mv = MathAbs(iClose(_Symbol, PERIOD_CURRENT, sh[i]) - iOpen(_Symbol, PERIOD_CURRENT, sh[i]));
      ratios[cnt++] = mv / vol;
   }
   if(cnt < InpBaselineMinSamples)
      return -1.0;
   ArrayResize(ratios, cnt);
   ArraySort(ratios);
   double baseline = ratios[cnt / 2];
   if(baseline <= 0.0)
      return -1.0;

   double vNow = BarVolume(shift);
   if(vNow <= 0.0)
      return -1.0;
   double actual = MathAbs(iClose(_Symbol, PERIOD_CURRENT, shift) - iOpen(_Symbol, PERIOD_CURRENT, shift));
   return actual / (baseline * vNow);
}

//+------------------------------------------------------------------+
//| nth Sunday of a month (nth = -1 for the last).  Weekday from the  |
//| epoch: 1970-01-01 was a Thursday.                                 |
//+------------------------------------------------------------------+
datetime NthSunday(int year, int mon, int nth)
{
   MqlDateTime dt;
   dt.year = year; dt.mon = mon; dt.day = 1;
   dt.hour = 0; dt.min = 0; dt.sec = 0;
   datetime first = StructToTime(dt);
   int dow = (int)((((long)first / 86400) + 4) % 7);     // 0 = Sunday
   int day = 1 + (7 - dow) % 7;

   if(nth > 0)
      day += 7 * (nth - 1);
   else
   {
      MqlDateTime nx = dt;
      if(mon == 12) { nx.year = year + 1; nx.mon = 1; }
      else          { nx.mon = mon + 1; }
      int daysInMonth = (int)(((long)StructToTime(nx) - (long)first) / 86400);
      while(day + 7 <= daysInMonth)
         day += 7;
   }
   return first + (datetime)((day - 1) * 86400);
}

//+------------------------------------------------------------------+
//| Does (from, to] contain a EU or US DST change?  Day precision -   |
//| the hours between UTC switch time and server midnight are ignored.|
//+------------------------------------------------------------------+
bool SpansDst(datetime from, datetime to)
{
   if(from <= 0 || to <= from)
      return false;
   MqlDateTime a, b;
   TimeToStruct(from, a);
   TimeToStruct(to, b);
   for(int y = a.year; y <= b.year; y++)
   {
      datetime d[4];
      d[0] = NthSunday(y, 3, -1);   // EU starts: last Sunday of March
      d[1] = NthSunday(y, 10, -1);  // EU ends: last Sunday of October
      d[2] = NthSunday(y, 3, 2);    // US starts: second Sunday of March
      d[3] = NthSunday(y, 11, 1);   // US ends: first Sunday of November
      for(int i = 0; i < 4; i++)
         if(d[i] > from && d[i] <= to)
            return true;
   }
   return false;
}

//+------------------------------------------------------------------+
bool InGmtHours(int h, int startH, int endH)
{
   if(startH < endH) return (h >= startH && h < endH);
   return (h >= startH || h < endH);     // wraps midnight
}

//+------------------------------------------------------------------+
//| Asia / London / NY / off-hours.  Overlaps go to the session that  |
//| opened most recently: NY > London > Asia.                         |
//+------------------------------------------------------------------+
string SessionLabel(datetime serverTime)
{
   MqlDateTime dt;
   TimeToStruct(serverTime - (datetime)(InpServerGMT * 3600), dt);
   if(InGmtHours(dt.hour, InpNYStartGMT, InpNYEndGMT))         return "NY";
   if(InGmtHours(dt.hour, InpLondonStartGMT, InpLondonEndGMT)) return "London";
   if(InGmtHours(dt.hour, InpAsiaStartGMT, InpAsiaEndGMT))     return "Asia";
   return "off-hours";
}

//+------------------------------------------------------------------+
void Rebuild(int rates_total, const datetime &time[], const double &open[],
             const double &high[], const double &low[], const double &close[])
{
   ObjectsDeleteAll(0, AB_PREFIX "m_");

   int periodSec = PeriodSeconds(PERIOD_CURRENT);
   int want = (int)MathMin(InpLookbackBars, rates_total - InpVolAvgBars - 2);
   if(want <= 0)
      return;

   double atr[];
   if(CopyBuffer(g_atrHandle, 0, 0, want + 2, atr) <= 0)
      return;
   ArraySetAsSeries(atr, true);

   ArrayResize(g_bars, want);
   g_barCount = 0;

   //--- diagnostics for this scan
   g_baseFallback = 0;
   g_baseScored   = 0;
   g_baseNewestN  = 0;
   int    nList[];   int nCount = 0;
   double dr[];      int nDr = 0;      // |delta| / classified total
   double im[];      int nIm = 0;      // price impact
   double ra[];      int nRa = 0;      // range / ATR
   AbsBar logBars[]; int nLog = 0;     // CSV candidates
   long   lastDayKey = -1;
   int    dayCount   = 0;

   //--- shift 1 is the newest closed bar
   for(int s = want; s >= 1; s--)
   {
      int idx = rates_total - 1 - s;
      if(s + InpVolAvgBars >= rates_total)
         continue;

      AbsBar b;
      if(!AnalyseBar(time[idx], periodSec, b))
         continue;
      b.hvnPassed = false;
      b.hvnDist   = -1.0;
      b.hvnStatus = HVN_ABSENT;
      b.spansDst  = false;

      long dayKey = (long)time[idx] / 86400;
      if(dayKey != lastDayKey)
      {
         dayCount++;
         lastDayKey = dayKey;
      }

      //--- 1. heavy volume, measured against this bar's own recent normal.
      //---    Uses the bar volume the terminal reports (real volume where the
      //---    feed has it), which is steadier than our own tick classification.
      double avg = 0.0;
      int    cnt = 0;
      for(int k = s + 1; k <= s + InpVolAvgBars; k++)
      {
         double bv = BarVolume(k);
         if(bv <= 0.0) continue;
         avg += bv;
         cnt++;
      }
      if(cnt == 0)
         continue;
      avg /= cnt;

      double barVol = BarVolume(s);
      bool heavy = (avg > 0.0 && barVol >= avg * InpVolMult);

      //--- 2. small range
      double atrVal = (s < ArraySize(atr)) ? atr[s] : 0.0;
      double range  = high[idx] - low[idx];
      bool   tight  = (atrVal > 0.0 && range <= atrVal * g_rangeMult);

      //--- 3. one-sided pressure
      bool oneSided = (b.total > 0.0 && MathAbs(b.delta) >= b.total * g_minDeltaRatio);

      //--- 4. the close went against that pressure
      double closePos = (range > 0.0) ? (close[idx] - low[idx]) / range : 0.5;
      bool bullAbs, bearAbs, pass;

      b.barVol = barVol;

      //--- baseline: same intraday slot on previous days, or the v1.00 rolling
      //--- window.  Too few slot samples falls back to rolling, and is counted.
      int zWin = (InpMethod == ABSMETH_UNUSUAL) ? InpZWindow : InpStatWindow;
      b.baseTod = false;
      b.baseN   = zWin;
      datetime baseOldest = iTime(_Symbol, PERIOD_CURRENT, (int)MathMin(s + zWin, Bars(_Symbol, PERIOD_CURRENT) - 1));
      if(UseTod())
      {
         int sh[];
         int nSlot = SlotSamples(s, sh);
         if(nSlot >= InpBaselineMinSamples)
         {
            b.baseTod  = true;
            b.baseN    = nSlot;
            b.volZ     = VolumeZTod(s, sh, nSlot);
            b.impact   = ImpactRatioTod(s, sh, nSlot);
            baseOldest = iTime(_Symbol, PERIOD_CURRENT, sh[nSlot - 1]);
         }
         else
            g_baseFallback++;
      }
      if(!b.baseTod)
      {
         b.volZ   = VolumeZ(s, zWin);
         b.impact = ImpactRatio(s);
      }
      b.spansDst = SpansDst(baseOldest, time[idx]);
      g_baseScored++;
      ArrayResize(nList, nCount + 1, 512);
      nList[nCount++] = b.baseN;
      if(s == 1)
         g_baseNewestN = b.baseN;

      //--- distributions for the attach-time measurement log
      if(!g_statsLogged)
      {
         if(b.total > 0.0) { ArrayResize(dr, nDr + 1, 512); dr[nDr++] = MathAbs(b.delta) / b.total; }
         if(b.impact > 0.0){ ArrayResize(im, nIm + 1, 512); im[nIm++] = b.impact; }
         if(atrVal > 0.0)  { ArrayResize(ra, nRa + 1, 512); ra[nRa++] = range / atrVal; }
      }

      if(InpMethod == ABSMETH_UNUSUAL)
      {
         //--- LuxAlgo's test: a statistically unusual volume spike, with an RVOL
         //--- floor so quiet instruments do not throw false positives.  Note this
         //--- says nothing about whether price moved - it marks participation,
         //--- not absorption.  Direction is simply the candle's own direction.
         double rvol = (avg > 0.0) ? barVol / avg : 0.0;
         bool spike  = (b.volZ >= InpVolZ) && (rvol > InpMinRvol);
         bullAbs = (close[idx] > open[idx]);
         bearAbs = !bullAbs;
         pass = spike;
      }
      else if(InpMethod == ABSMETH_IMPACT)
      {
         //--- The published definition: unusually heavy participation that moves
         //--- price far less than that much participation normally moves it.
         //--- Direction comes from which end of the bar the close rejected, NOT
         //--- from delta - on a quote-only CFD feed delta is near worthless
         //--- (measured: it explains 1.7% of the bar's price change).
         bool heavyZ = (b.volZ >= InpVolZ);
         bool soaked = (b.impact > 0.0 && b.impact <= g_maxImpact);
         bullAbs = (closePos >= InpClosePos);
         bearAbs = (closePos <= 1.0 - InpClosePos);
         pass = heavyZ && soaked && (bullAbs || bearAbs);
      }
      else
      {
         bullAbs = (b.delta < 0 && closePos >= InpClosePos);
         bearAbs = (b.delta > 0 && closePos <= 1.0 - InpClosePos);
         pass = heavy && tight && oneSided && (bullAbs || bearAbs);
      }

      if(pass)
      {
         b.isAbs   = true;
         b.bullish = bullAbs;
         if(b.poc <= 0.0)
            b.poc = (high[idx] + low[idx]) * 0.5;
         b.high = high[idx];
         b.low  = low[idx];
         b.atr  = atrVal;

         //--- HVN state is the one read on this tick.  hvn_filter_passed is only
         //--- ever true against a FRESH set - never for a stale-but-let-through bar.
         b.hvnStatus = (g_hvnState == HVN_UNKNOWN) ? HVN_ABSENT : g_hvnState;
         b.hvnDist   = (b.hvnStatus == HVN_FRESH) ? NearestHvnDist(b.poc) : -1.0;
         b.hvnPassed = (b.hvnStatus == HVN_FRESH && b.hvnDist >= 0.0 && b.hvnDist <= g_hvnTol);

         if(InpRequireHVN)
         {
            if(b.hvnStatus == HVN_FRESH)
               b.isAbs = b.hvnPassed;
            else
               b.isAbs = (InpHvnStaleAction == HVNSTALE_PASS);
         }

         //--- CSV candidate: every METHOD-PASS bar (before the HVN filter) that
         //--- closed while attached and is newer than anything already written
         if(InpLogCSV && g_csvOk && time[idx] >= g_attachBar && time[idx] > g_csvLastTs)
         {
            ArrayResize(logBars, nLog + 1, 16);
            logBars[nLog++] = b;
         }
      }

      if(b.isAbs)
         g_bars[g_barCount++] = b;
   }

   //--- scan diagnostics
   g_scanDays = dayCount;
   g_baseMedianN = 0;
   if(nCount > 0)
   {
      ArraySort(nList);
      g_baseMedianN = nList[nCount / 2];
   }
   g_sig24h = 0;
   datetime dayAgo = TimeCurrent() - 86400;
   for(int i = 0; i < g_barCount; i++)
      if(g_bars[i].t >= dayAgo)
         g_sig24h++;

   if(!g_statsLogged && (nDr > 0 || nIm > 0 || nRa > 0))
   {
      LogDistribution(dr, nDr, im, nIm, ra, nRa);
      g_statsLogged = true;
   }

   DrawAllMarkers();
   MarkStacks();

   for(int i = 0; i < nLog; i++)
      CsvQueue(logBars[i], IsStacked(logBars[i]));
   if(InpLogCSV && g_csvOk)
      CsvFlush();

   DrawStatus();
   ChartRedraw();
   MaybeAlert();
}

//+------------------------------------------------------------------+
//| HVN levels published by OF_Heatmap through global variables      |
//+------------------------------------------------------------------+
//|  OFHM_<sym>_<tf>_hvn_count / _<i> / _time / _bucket               |
//|  time 0/missing = never published, 1 = heatmap removed,           |
//|  count 0 with a fresh time = warming or no nodes -> ABSENT.        |
//+------------------------------------------------------------------+
string HvnStateName(int st)
{
   if(st == HVN_FRESH)  return "FRESH";
   if(st == HVN_STALE)  return "STALE";
   if(st == HVN_ABSENT) return "ABSENT";
   return "UNKNOWN";
}

//+------------------------------------------------------------------+
void LoadHvnLevels(string base, int n)
{
   ArrayResize(g_hvnLevels, (n > 0) ? n : 0);
   g_hvnCount = 0;
   for(int i = 0; i < n; i++)
   {
      double lvl = GlobalVariableGet(base + IntegerToString(i));
      if(lvl > 0.0)
         g_hvnLevels[g_hvnCount++] = lvl;
   }
}

//+------------------------------------------------------------------+
int HvnRead()
{
   string base = "OFHM_" + _Symbol + "_" + g_hvnTfStr + "_hvn_";
   double tm   = GlobalVariableGet(base + "time");
   g_hvnLegacy = false;
   g_hvnCount  = 0;

   if(tm <= 0.0)
   {
      //--- one-version fallback: v1.00 heatmaps wrote OFHM_<sym>_hvn_* with no
      //--- timeframe and no timestamp.  Readable, but its age is unknowable, so
      //--- it can never count as fresh.
      string lb = "OFHM_" + _Symbol + "_hvn_";
      if((int)GlobalVariableGet(lb + "count") > 0)
      {
         g_hvnLegacy = true;
         g_hvnAge    = -1;
         return HVN_STALE;
      }
      g_hvnAge = -1;
      return HVN_ABSENT;
   }

   long age = (long)TimeCurrent() - (long)tm;
   if(age < 0) age = 0;
   g_hvnAge    = (int)MathMin(age, 2000000000);
   g_hvnBucket = GlobalVariableGet(base + "bucket");
   if(tm <= 1.0 || age > InpHvnMaxAgeSec)
      return HVN_STALE;

   int cnt = (int)GlobalVariableGet(base + "count");
   if(cnt <= 0)
      return HVN_ABSENT;
   LoadHvnLevels(base, cnt);
   return (g_hvnCount > 0) ? HVN_FRESH : HVN_ABSENT;
}

//+------------------------------------------------------------------+
//| Re-read the HVN source; report transitions once each.  Returns    |
//| true when a known state changed (the caller rebuilds).            |
//+------------------------------------------------------------------+
bool HvnUpdateState()
{
   int st = HvnRead();
   if(st == g_hvnState)
      return false;

   bool wasKnown = (g_hvnState != HVN_UNKNOWN);
   string src = _Symbol + " " + g_hvnTfStr;
   if(!wasKnown)
      Print("OF_Absorption: initial HVN state for ", src, " = ", HvnStateName(st));
   else if(st == HVN_FRESH)
      Print("OF_Absorption: HVN set for ", src, " RECOVERED (fresh, ", g_hvnCount, " levels)");
   else
      Print("OF_Absorption: HVN set for ", src, " is now ", HvnStateName(st),
            (InpRequireHVN ? (InpHvnStaleAction == HVNSTALE_BLOCK ? " - SIGNALS BLOCKED" : " - filter bypassed") : ""));
   if(g_hvnLegacy)
      Print("OF_Absorption: reading LEGACY un-namespaced OFHM_", _Symbol,
            "_hvn_* (v1.00 heatmap, no timestamp) - treated as stale");

   //--- one alert on going stale, if alerts are how Jerry watches this
   if(wasKnown && st == HVN_STALE && g_hvnState == HVN_FRESH && InpRequireHVN &&
      (InpAlertPopup || InpAlertPush))
   {
      string msg = StringFormat("%s %s: OF_Absorption HVN set (%s) went STALE - %s",
                                _Symbol, g_tfStr, g_hvnTfStr,
                                InpHvnStaleAction == HVNSTALE_BLOCK ? "signals blocked" : "filter bypassed");
      if(InpAlertPopup) Alert(msg);
      if(InpAlertPush)  SendNotification(msg);
   }

   g_hvnState = st;
   return wasKnown;
}

//+------------------------------------------------------------------+
//| Distance from price to the nearest fresh HVN, -1 if none          |
//+------------------------------------------------------------------+
double NearestHvnDist(double price)
{
   double best = -1.0;
   for(int i = 0; i < g_hvnCount; i++)
   {
      double d = MathAbs(g_hvnLevels[i] - price);
      if(best < 0.0 || d < best)
         best = d;
   }
   return best;
}

//+------------------------------------------------------------------+
//| 38890 -> "38.89K".  Matches how every orderflow tool prints size. |
//+------------------------------------------------------------------+
string FormatVol(double v)
{
   if(v >= 1000000.0) return DoubleToString(v / 1000000.0, 2) + "M";
   if(v >= 1000.0)    return DoubleToString(v / 1000.0, 2) + "K";
   return DoubleToString(v, 0);
}

//+------------------------------------------------------------------+
//| Bubbles are sized RELATIVE to each other, so the scan has to      |
//| finish before anything can be drawn.                              |
//+------------------------------------------------------------------+
void DrawAllMarkers()
{
   if(g_barCount <= 0)
      return;

   double vMin = g_bars[0].barVol, vMax = g_bars[0].barVol;
   for(int i = 1; i < g_barCount; i++)
   {
      if(g_bars[i].barVol < vMin) vMin = g_bars[i].barVol;
      if(g_bars[i].barVol > vMax) vMax = g_bars[i].barVol;
   }

   for(int i = 0; i < g_barCount; i++)
   {
      double frac = (vMax > vMin) ? (g_bars[i].barVol - vMin) / (vMax - vMin) : 0.5;
      DrawMarker(g_bars[i], g_bars[i].t, g_bars[i].high, g_bars[i].low, g_bars[i].atr, frac);
   }
}

//+------------------------------------------------------------------+
void DrawMarker(const AbsBar &b, datetime t, double high, double low, double atrVal, double frac)
{
   color  c   = b.bullish ? InpBullColor : InpBearColor;
   string sid = IntegerToString((long)t);

   string tip = StringFormat("%s absorption\nprice %s\nbuy %.0f  sell %.0f  delta %.0f (%.0f%% of %.0f)",
                             (b.bullish ? "Bullish" : "Bearish"),
                             DoubleToString(b.poc, g_digits),
                             b.buyVol, b.sellVol, b.delta,
                             (b.total > 0.0 ? 100.0 * MathAbs(b.delta) / b.total : 0.0),
                             b.total);

   if(InpShowArrows)
   {
      string an = AB_PREFIX "m_a" + sid;

      if(InpMarkerStyle == ABSM_BUBBLE)
      {
         //--- A bubble whose SIZE is the absorbed volume, parked off the bar
         //--- in clear space with a stem pointing at the defended price.
         double atrUse = (atrVal > 0.0) ? atrVal : (high - low);
         if(atrUse <= 0.0)
            atrUse = 100 * g_point;

         double rBars = InpBubbleMinBars + (InpBubbleMaxBars - InpBubbleMinBars) * frac;
         int    halfSec = (int)MathRound(PeriodSeconds(PERIOD_CURRENT) * rBars);
         //--- keep it round-ish: tie the vertical radius to the same fraction
         double rPrice = atrUse * InpCircleAtr * (rBars / MathMax(0.01, InpBubbleMaxBars)) * 2.0;
         if(rPrice <= 0.0)
            rPrice = atrUse * 0.2;

         //--- bullish absorption sits under the bar, bearish above it
         double centre = b.bullish ? low - atrUse * InpBubbleOffsetAtr - rPrice
                                   : high + atrUse * InpBubbleOffsetAtr + rPrice;

         ObjectCreate(0, an, OBJ_ELLIPSE, 0, t - (datetime)halfSec, centre,
                                            t + (datetime)halfSec, centre,
                                            t, centre + rPrice);
         ObjectSetInteger(0, an, OBJPROP_COLOR, c);
         ObjectSetInteger(0, an, OBJPROP_WIDTH, 1);
         ObjectSetInteger(0, an, OBJPROP_FILL, true);
         ObjectSetInteger(0, an, OBJPROP_BACK, true);   // candles stay readable

         if(InpBubbleStem)
         {
            string sn = AB_PREFIX "m_s" + sid;
            double stemEnd = b.bullish ? centre + rPrice : centre - rPrice;
            ObjectCreate(0, sn, OBJ_TREND, 0, t, stemEnd, t, b.poc);
            ObjectSetInteger(0, sn, OBJPROP_COLOR, c);
            ObjectSetInteger(0, sn, OBJPROP_STYLE, STYLE_DOT);
            ObjectSetInteger(0, sn, OBJPROP_WIDTH, 1);
            ObjectSetInteger(0, sn, OBJPROP_RAY_RIGHT, false);
            ObjectSetInteger(0, sn, OBJPROP_SELECTABLE, false);
            ObjectSetInteger(0, sn, OBJPROP_HIDDEN, true);
            ObjectSetInteger(0, sn, OBJPROP_BACK, true);
         }

         if(InpBubbleLabel && b.volZ >= InpLabelMinZ)
         {
            string tn = AB_PREFIX "m_t" + sid;
            ObjectCreate(0, tn, OBJ_TEXT, 0, t, centre);
            ObjectSetString(0, tn, OBJPROP_TEXT, FormatVol(b.barVol));
            ObjectSetString(0, tn, OBJPROP_FONT, "Arial Bold");
            ObjectSetInteger(0, tn, OBJPROP_FONTSIZE, 8);
            ObjectSetInteger(0, tn, OBJPROP_COLOR, clrWhite);
            ObjectSetInteger(0, tn, OBJPROP_ANCHOR, ANCHOR_CENTER);
            ObjectSetInteger(0, tn, OBJPROP_SELECTABLE, false);
            ObjectSetInteger(0, tn, OBJPROP_HIDDEN, true);
            ObjectSetString(0, tn, OBJPROP_TOOLTIP, tip);
         }
      }
      else if(InpMarkerStyle == ABSM_CIRCLE)
      {
         //--- A ring around the level being defended, the way you would circle
         //--- it by hand.  OBJ_ELLIPSE takes three anchors: the first two are
         //--- the ends of the horizontal axis, the third sets the height.
         double halfPrice = (atrVal > 0.0) ? atrVal * InpCircleAtr : (high - low);
         if(halfPrice <= 0.0)
            halfPrice = (high - low) * 0.75;
         if(halfPrice <= 0.0)
            halfPrice = 10 * g_point;

         int      halfSec = (int)MathRound(PeriodSeconds(PERIOD_CURRENT) * InpCircleBars);
         datetime t1 = t - (datetime)halfSec;
         datetime t2 = t + (datetime)halfSec;

         ObjectCreate(0, an, OBJ_ELLIPSE, 0, t1, b.poc, t2, b.poc, t, b.poc + halfPrice);
         ObjectSetInteger(0, an, OBJPROP_COLOR, c);
         ObjectSetInteger(0, an, OBJPROP_WIDTH, 2);
         ObjectSetInteger(0, an, OBJPROP_FILL, false);   // a ring, so the candle stays visible
         ObjectSetInteger(0, an, OBJPROP_BACK, false);
      }
      else
      {
         double at = b.bullish ? low - (high - low) * 0.4 : high + (high - low) * 0.4;
         ObjectCreate(0, an, OBJ_ARROW, 0, t, at);
         //--- Wingdings 108 is a filled circle; 233/234 are the up/down arrows
         int code = (InpMarkerStyle == ABSM_DOT) ? 108 : (b.bullish ? 233 : 234);
         ObjectSetInteger(0, an, OBJPROP_ARROWCODE, code);
         ObjectSetInteger(0, an, OBJPROP_COLOR, c);
         ObjectSetInteger(0, an, OBJPROP_WIDTH, 2);
      }

      ObjectSetInteger(0, an, OBJPROP_SELECTABLE, false);
      ObjectSetInteger(0, an, OBJPROP_HIDDEN, true);
      ObjectSetString(0, an, OBJPROP_TOOLTIP, tip);
   }

   if(InpShowLevels)
   {
      string ln = AB_PREFIX "m_l" + sid;
      datetime t2 = t + (datetime)(PeriodSeconds(PERIOD_CURRENT) * InpExtendBars);
      ObjectCreate(0, ln, OBJ_TREND, 0, t, b.poc, t2, b.poc);
      ObjectSetInteger(0, ln, OBJPROP_COLOR, c);
      ObjectSetInteger(0, ln, OBJPROP_STYLE, STYLE_SOLID);
      ObjectSetInteger(0, ln, OBJPROP_WIDTH, 1);
      ObjectSetInteger(0, ln, OBJPROP_RAY_RIGHT, false);
      ObjectSetInteger(0, ln, OBJPROP_SELECTABLE, false);
      ObjectSetInteger(0, ln, OBJPROP_HIDDEN, true);
      ObjectSetInteger(0, ln, OBJPROP_BACK, true);
      ObjectSetString(0, ln, OBJPROP_TOOLTIP, tip);
   }
}

//+------------------------------------------------------------------+
//| Several absorptions at the same price is the strong version -    |
//| somebody keeps refilling the same order                          |
//+------------------------------------------------------------------+
void MarkStacks()
{
   ObjectsDeleteAll(0, AB_PREFIX "m_z");
   if(g_barCount < InpStackMin)
      return;

   double tol   = g_stackTol;
   int    winSec = PeriodSeconds(PERIOD_CURRENT) * InpStackWindow;
   int    zone  = 0;

   for(int i = 0; i < g_barCount; i++)
   {
      int    members = 1;
      double lo = g_bars[i].poc, hi = g_bars[i].poc;
      datetime tEnd = g_bars[i].t;

      for(int j = i + 1; j < g_barCount; j++)
      {
         if(g_bars[j].t - g_bars[i].t > winSec)
            break;
         if(MathAbs(g_bars[j].poc - g_bars[i].poc) <= tol)
         {
            members++;
            tEnd = g_bars[j].t;
            if(g_bars[j].poc < lo) lo = g_bars[j].poc;
            if(g_bars[j].poc > hi) hi = g_bars[j].poc;
         }
      }

      if(members >= InpStackMin)
      {
         string zn = AB_PREFIX "m_z" + IntegerToString(zone++);
         datetime t2 = tEnd + (datetime)(PeriodSeconds(PERIOD_CURRENT) * InpExtendBars);
         double pad = (hi - lo < tol * 0.25) ? tol * 0.25 : 0.0;
         ObjectCreate(0, zn, OBJ_RECTANGLE, 0, g_bars[i].t, lo - pad, t2, hi + pad);
         ObjectSetInteger(0, zn, OBJPROP_COLOR, InpZoneColor);
         ObjectSetInteger(0, zn, OBJPROP_FILL, true);
         ObjectSetInteger(0, zn, OBJPROP_BACK, true);
         ObjectSetInteger(0, zn, OBJPROP_SELECTABLE, false);
         ObjectSetInteger(0, zn, OBJPROP_HIDDEN, true);
         ObjectSetString(0, zn, OBJPROP_TOOLTIP,
                         StringFormat("Stacked absorption x%d\n%s - %s", members,
                                      DoubleToString(lo, g_digits), DoubleToString(hi, g_digits)));
         i += members - 1;   // do not re-report the same cluster
      }
   }
}

//+------------------------------------------------------------------+
//| Attach-time measurement: where do the three thresholds actually   |
//| sit in this chart's own distribution?  Set them from this instead |
//| of guessing.                                                      |
//+------------------------------------------------------------------+
double Pctl(const double &sorted[], int n, double p)
{
   if(n <= 0) return 0.0;
   int k = (int)MathFloor(p * (n - 1));
   return sorted[k];
}

//+------------------------------------------------------------------+
string DistLine(string name, double &arr[], int n, string cmp, double thr, bool below, string gates)
{
   if(n <= 0)
      return name + ": no data";
   ArrayResize(arr, n);
   ArraySort(arr);
   int clear = 0;
   for(int i = 0; i < n; i++)
      if(below ? (arr[i] <= thr) : (arr[i] >= thr))
         clear++;
   return StringFormat("%s (n=%d): p50 %.4f  p90 %.4f  p95 %.4f  p99 %.4f  |  %s %.4f cleared by %.1f%% of bars  [%s]",
                       name, n, Pctl(arr, n, 0.50), Pctl(arr, n, 0.90), Pctl(arr, n, 0.95), Pctl(arr, n, 0.99),
                       cmp, thr, 100.0 * clear / n, gates);
}

//+------------------------------------------------------------------+
void LogDistribution(double &dr[], int nDr, double &im[], int nIm, double &ra[], int nRa)
{
   Print("OF_Absorption ", _Symbol, " ", g_tfStr, " distribution over the last ", InpLookbackBars,
         " bars (baseline ", (UseTod() ? "time-of-day" : "rolling"), "):");
   Print("  ", DistLine("delta_ratio |delta|/total", dr, nDr, ">= MinDeltaRatio", g_minDeltaRatio, false, "gates CLASSIC only"));
   Print("  ", DistLine("price_impact", im, nIm, "<= MaxImpact", g_maxImpact, true, "gates IMPACT only"));
   Print("  ", DistLine("range/ATR", ra, nRa, "<= RangeMult", g_rangeMult, true, "gates CLASSIC only"));
}

//+------------------------------------------------------------------+
//| stacked = at least InpStackMin absorptions INCLUDING this bar,    |
//| among displayed signals inside InpStackWindow bars and stack tol  |
//+------------------------------------------------------------------+
bool IsStacked(const AbsBar &x)
{
   int members = 1;
   int winSec  = PeriodSeconds(PERIOD_CURRENT) * InpStackWindow;
   for(int j = 0; j < g_barCount; j++)
   {
      if(g_bars[j].t >= x.t) continue;
      if(x.t - g_bars[j].t <= winSec && MathAbs(g_bars[j].poc - x.poc) <= g_stackTol)
         members++;
   }
   return (members >= InpStackMin);
}

//+------------------------------------------------------------------+
//| CSV LOG                                                           |
//|                                                                  |
//| Every bar that passes the detection method gets a row, with       |
//| hvn_filter_passed 0 or 1.  That is the whole point of the log - I |
//| cannot learn whether the HVN filter pays for itself if the        |
//| rejected bars are never recorded.  A log of only the signals I    |
//| already act on answers no question I actually have.               |
//|                                                                  |
//| No backfill.  Historical bars would be scored against today's HVN |
//| set, which did not exist at the time.  That is lookahead, and one |
//| contaminated column is enough to make the whole file              |
//| untrustworthy later when I have forgotten which rows came from    |
//| where.  Blank columns are not a fix: two populations in one file  |
//| and no reliable way to separate them.                             |
//|                                                                  |
//| `live` is 1 on every row, so if backfill is ever added the        |
//| distinction is already in the schema, not inferred from a         |
//| timestamp.  Do not "improve" this without reading the above.      |
//+------------------------------------------------------------------+
#define CSV_COLS 25

struct CsvRow
{
   string f[CSV_COLS];
};

string g_csvCols[CSV_COLS];
CsvRow g_csvQueue[];

//+------------------------------------------------------------------+
string CsvHeaderJoined()
{
   string s = "";
   for(int i = 0; i < CSV_COLS; i++)
      s += (i > 0 ? "," : "") + g_csvCols[i];
   return s;
}

//+------------------------------------------------------------------+
//| Name the file, and read the newest timestamp already in it so a   |
//| reinitialise (TF change, recompile, restart) never rewrites rows. |
//+------------------------------------------------------------------+
void CsvInit()
{
   string sym = _Symbol;
   StringReplace(sym, "\\", "_"); StringReplace(sym, "/", "_"); StringReplace(sym, ":", "_");
   StringReplace(sym, "*", "_");  StringReplace(sym, "?", "_"); StringReplace(sym, "\"", "_");
   StringReplace(sym, "<", "_");  StringReplace(sym, ">", "_"); StringReplace(sym, "|", "_");
   g_csvName = "OF_Absorption_" + sym + "_" + g_tfStr + ".csv";

   g_csvCols[0]  = "timestamp";       g_csvCols[1]  = "symbol";          g_csvCols[2]  = "period";
   g_csvCols[3]  = "direction";       g_csvCols[4]  = "defended_price";  g_csvCols[5]  = "bar_high";
   g_csvCols[6]  = "bar_low";         g_csvCols[7]  = "volume";          g_csvCols[8]  = "buy_volume";
   g_csvCols[9]  = "sell_volume";     g_csvCols[10] = "delta";           g_csvCols[11] = "delta_ratio";
   g_csvCols[12] = "volume_z";        g_csvCols[13] = "price_impact";
   g_csvCols[14] = "atr_" + IntegerToString(InpAtrPeriod);
   g_csvCols[15] = "method";          g_csvCols[16] = "hvn_filter_passed"; g_csvCols[17] = "hvn_distance";
   g_csvCols[18] = "stacked";         g_csvCols[19] = "session";         g_csvCols[20] = "live";
   g_csvCols[21] = "hvn_status";      g_csvCols[22] = "baseline_mode";   g_csvCols[23] = "baseline_n";
   g_csvCols[24] = "baseline_spans_dst";

   g_csvOk     = true;
   g_csvError  = "";
   g_csvLastTs = 0;

   int h = FileOpen(g_csvName, FILE_READ | FILE_CSV | FILE_ANSI | FILE_SHARE_READ, ',');
   if(h == INVALID_HANDLE)
   {
      Print("OF_Absorption CSV: ", g_csvName, " not found yet - created on the first live method-pass bar");
      return;
   }

   //--- header must match this version's schema exactly, or nothing is appended
   string hdr = "";
   int    nf  = 0;
   if(!FileIsEnding(h))
   {
      do
      {
         string f = FileReadString(h);
         hdr += (nf > 0 ? "," : "") + f;
         nf++;
      }
      while(!FileIsLineEnding(h) && !FileIsEnding(h));
   }
   if(StringLen(hdr) > 0 && hdr != CsvHeaderJoined())
   {
      FileClose(h);
      g_csvOk    = false;
      g_csvError = "SCHEMA MISMATCH - logging disabled";
      Print("OF_Absorption CSV ERROR: header of ", g_csvName, " does not match this version. Found: ", hdr,
            "  Expected: ", CsvHeaderJoined(), "  - rename the old file; nothing will be appended.");
      return;
   }

   while(!FileIsEnding(h))
   {
      string ts = FileReadString(h);
      while(!FileIsLineEnding(h) && !FileIsEnding(h))
         FileReadString(h);
      if(StringLen(ts) == 0)
         continue;
      datetime t = StringToTime(ts);
      if(t > g_csvLastTs)
         g_csvLastTs = t;
   }
   FileClose(h);
   Print("OF_Absorption CSV: appending to ", g_csvName, ", newest existing row ",
         (g_csvLastTs > 0 ? TimeToString(g_csvLastTs, TIME_DATE | TIME_MINUTES) : "none"),
         " - only newer bars are written");
}

//+------------------------------------------------------------------+
void CsvQueue(const AbsBar &x, bool stacked)
{
   CsvRow r;
   string method = "UNUSUAL";
   if(InpMethod == ABSMETH_IMPACT)  method = "IMPACT";
   if(InpMethod == ABSMETH_CLASSIC) method = "CLASSIC";
   string status = "absent";
   if(x.hvnStatus == HVN_FRESH) status = "fresh";
   if(x.hvnStatus == HVN_STALE) status = "stale";
   string bmode = x.baseTod ? "timeofday" : (UseTod() ? "rolling_fallback" : "rolling");

   r.f[0]  = TimeToString(x.t, TIME_DATE | TIME_MINUTES);    // bar open, server time
   r.f[1]  = _Symbol;
   r.f[2]  = g_tfStr;
   r.f[3]  = x.bullish ? "bull" : "bear";
   r.f[4]  = DoubleToString(x.poc,  g_digits);
   r.f[5]  = DoubleToString(x.high, g_digits);
   r.f[6]  = DoubleToString(x.low,  g_digits);
   r.f[7]  = DoubleToString(x.barVol,  2);                    // terminal bar volume
   r.f[8]  = DoubleToString(x.buyVol,  2);                    // tick-classified
   r.f[9]  = DoubleToString(x.sellVol, 2);
   r.f[10] = DoubleToString(x.delta,   2);
   r.f[11] = DoubleToString(x.total > 0.0 ? x.delta / x.total : 0.0, 4);   // signed, vs classified total
   r.f[12] = DoubleToString(x.volZ, 3);
   r.f[13] = (x.impact > 0.0) ? DoubleToString(x.impact, 4) : "";
   r.f[14] = DoubleToString(x.atr, g_digits + 1);
   r.f[15] = method;
   r.f[16] = x.hvnPassed ? "1" : "0";
   r.f[17] = (x.hvnDist >= 0.0) ? DoubleToString(x.hvnDist, g_digits) : "";
   r.f[18] = stacked ? "1" : "0";
   r.f[19] = SessionLabel(x.t);
   r.f[20] = "1";
   r.f[21] = status;
   r.f[22] = bmode;
   r.f[23] = IntegerToString(x.baseN);
   r.f[24] = x.spansDst ? "1" : "0";

   int n = ArraySize(g_csvQueue);
   ArrayResize(g_csvQueue, n + 1);
   g_csvQueue[n] = r;
   if(x.t > g_csvLastTs)
      g_csvLastTs = x.t;
}

//+------------------------------------------------------------------+
//| Open-append-flush-close per flush.  If the file is locked (Excel) |
//| rows stay queued in memory and are retried on the next bar.       |
//+------------------------------------------------------------------+
void CsvFlush()
{
   int n = ArraySize(g_csvQueue);
   if(n == 0)
      return;

   int h = FileOpen(g_csvName, FILE_READ | FILE_WRITE | FILE_CSV | FILE_ANSI | FILE_SHARE_READ, ',');
   if(h == INVALID_HANDLE)
   {
      if(!g_csvErrLogged)
         Print("OF_Absorption CSV ERROR: cannot open ", g_csvName, " (error ", GetLastError(),
               ") - ", n, " row(s) kept in memory, retrying on the next bar");
      g_csvErrLogged = true;
      g_csvError = "WRITE PENDING (" + IntegerToString(n) + " rows)";
      return;
   }
   g_csvErrLogged = false;
   g_csvError     = "";

   if(FileSize(h) == 0)
      FileWrite(h, g_csvCols[0], g_csvCols[1], g_csvCols[2], g_csvCols[3], g_csvCols[4],
                   g_csvCols[5], g_csvCols[6], g_csvCols[7], g_csvCols[8], g_csvCols[9],
                   g_csvCols[10], g_csvCols[11], g_csvCols[12], g_csvCols[13], g_csvCols[14],
                   g_csvCols[15], g_csvCols[16], g_csvCols[17], g_csvCols[18], g_csvCols[19],
                   g_csvCols[20], g_csvCols[21], g_csvCols[22], g_csvCols[23], g_csvCols[24]);
   FileSeek(h, 0, SEEK_END);

   for(int i = 0; i < n; i++)
   {
      FileWrite(h, g_csvQueue[i].f[0], g_csvQueue[i].f[1], g_csvQueue[i].f[2], g_csvQueue[i].f[3],
                   g_csvQueue[i].f[4], g_csvQueue[i].f[5], g_csvQueue[i].f[6], g_csvQueue[i].f[7],
                   g_csvQueue[i].f[8], g_csvQueue[i].f[9], g_csvQueue[i].f[10], g_csvQueue[i].f[11],
                   g_csvQueue[i].f[12], g_csvQueue[i].f[13], g_csvQueue[i].f[14], g_csvQueue[i].f[15],
                   g_csvQueue[i].f[16], g_csvQueue[i].f[17], g_csvQueue[i].f[18], g_csvQueue[i].f[19],
                   g_csvQueue[i].f[20], g_csvQueue[i].f[21], g_csvQueue[i].f[22], g_csvQueue[i].f[23],
                   g_csvQueue[i].f[24]);
      FileFlush(h);
   }
   FileClose(h);
   ArrayResize(g_csvQueue, 0);
}

//+------------------------------------------------------------------+
void MaybeAlert()
{
   if(!InpAlertPopup && !InpAlertPush)
      return;
   if(g_barCount <= 0)
      return;

   AbsBar last = g_bars[g_barCount - 1];
   if(last.t <= g_lastAlert)
      return;
   //--- only shout about the bar that just closed
   if(last.t != iTime(_Symbol, PERIOD_CURRENT, 1))
      return;
   g_lastAlert = last.t;

   string msg = StringFormat("%s %s: %s absorption at %s (delta %.0f of %.0f)",
                             _Symbol, EnumToString((ENUM_TIMEFRAMES)Period()),
                             (last.bullish ? "BULLISH" : "BEARISH"),
                             DoubleToString(last.poc, g_digits), last.delta, last.total);
   if(InpAlertPopup) Alert(msg);
   if(InpAlertPush)  SendNotification(msg);
}

//+------------------------------------------------------------------+
void DrawStatus()
{
   if(!InpShowStatus)
   {
      ObjectDelete(0, AB_STATUS);
      ObjectDelete(0, AB_STATUS2);
      ObjectDelete(0, AB_STATUS3);
      return;
   }

   string method = "unusual volume (Z+RVOL)";
   if(InpMethod == ABSMETH_IMPACT)  method = "Z-score + price impact";
   if(InpMethod == ABSMETH_CLASSIC) method = "classic (vol/range/delta)";

   //--- line 1: warnings first, then the firing rate
   string warn = "";
   if(InpRequireHVN && g_hvnState != HVN_FRESH && g_hvnState != HVN_UNKNOWN)
      warn = (g_hvnState == HVN_ABSENT ? "HVN ABSENT" : "HVN STALE")
           + (InpHvnStaleAction == HVNSTALE_BLOCK ? " - SIGNALS BLOCKED" : " - FILTER BYPASSED") + "  |  ";
   if(InpLogCSV && g_csvError != "")
      warn += "CSV " + g_csvError + "  |  ";

   double perDay = (g_scanDays > 0) ? (double)g_barCount / (double)g_scanDays : 0.0;
   string txt = warn + method + ": " + IntegerToString(g_barCount) + " in last "
              + IntegerToString(InpLookbackBars) + " bars = " + DoubleToString(perDay, 1)
              + "/day over " + IntegerToString(g_scanDays) + " days  |  last 24h: "
              + IntegerToString(g_sig24h) + "  |  " + g_volLabel + "  |  " + g_aggLabel;
   StatusLabel(AB_STATUS, 46, (warn != "") ? clrOrangeRed : (g_realAggr ? clrLimeGreen : clrOrange), txt);

   //--- line 2: baseline and thresholds
   string base = UseTod() ? "TIME-OF-DAY"
                          : (InpBaselineMode == BASE_TIMEOFDAY ? "ROLLING (time-of-day n/a on this TF)" : "ROLLING");
   string txt2 = "Baseline " + base + ": newest n=" + IntegerToString(g_baseNewestN)
               + ", median n=" + IntegerToString(g_baseMedianN)
               + (UseTod() ? "  |  rolling fallback on " + IntegerToString(g_baseFallback) + "/" + IntegerToString(g_baseScored) + " bars" : "")
               + "  |  delta>=" + DoubleToString(g_minDeltaRatio, 3)
               + " impact<=" + DoubleToString(g_maxImpact, 3)
               + " range<=" + DoubleToString(g_rangeMult, 3) + "xATR"
               + (InpAutoTune ? " (auto-tuned)" : "");
   StatusLabel(AB_STATUS2, 60, (UseTod() && g_baseFallback > 0) ? clrOrange : clrSilver, txt2);

   //--- line 3: HVN source and the resolved tolerances in price
   string st = "not read yet";
   if(g_hvnState == HVN_FRESH)
      st = "fresh, " + IntegerToString(g_hvnCount) + " levels, " + IntegerToString(g_hvnAge) + "s old";
   else if(g_hvnState == HVN_STALE)
      st = g_hvnLegacy ? "LEGACY v1.00 globals (no timestamp) - stale"
                       : "STALE (" + IntegerToString(g_hvnAge) + "s old)";
   else if(g_hvnState == HVN_ABSENT)
      st = "absent (no heatmap, warming, or no nodes)";

   string txt3 = "HVN source " + g_hvnTfStr + " (chart " + g_tfStr + "): " + st
               + "  |  HVN tol " + DoubleToString(g_hvnTol, g_digits)
               + "  stack tol " + DoubleToString(g_stackTol, g_digits)
               + (g_hvnBucket > 0.0 ? "  |  heatmap bucket " + DoubleToString(g_hvnBucket, g_digits) : "")
               + (InpLogCSV ? "  |  CSV " + (g_csvOk ? "on" : "OFF") : "");
   StatusLabel(AB_STATUS3, 74, (g_hvnState == HVN_FRESH) ? clrSilver : clrOrange, txt3);
}

//+------------------------------------------------------------------+
void StatusLabel(string name, int y, color clr, string txt)
{
   //--- queue the line; the third one triggers the paint
   int r = (name == AB_STATUS) ? 0 : ((name == AB_STATUS2) ? 1 : 2);
   g_stTxt[r] = txt;
   g_stClr[r] = clr;
   ObjectDelete(0, name);              // clear any old truncating OBJ_LABEL
   if(r == 2)
      RenderStatus();
}

//+------------------------------------------------------------------+
//| Paint the three lines on the status canvas, on a dark translucent |
//| backing so every colour reads on light and dark charts alike.     |
//| Skipped when nothing changed, so the per-tick call costs nothing. |
//+------------------------------------------------------------------+
void RenderStatus()
{
   string key = g_stTxt[0] + (string)(int)g_stClr[0] + g_stTxt[1] + (string)(int)g_stClr[1]
              + g_stTxt[2] + (string)(int)g_stClr[2];
   if(key == g_stLast)
      return;
   g_stLast = key;

   int maxLen = 0;
   for(int i = 0; i < 3; i++)
      maxLen = (int)MathMax(maxLen, StringLen(g_stTxt[i]));
   int w = (int)MathMax(50, MathMin((int)ChartGetInteger(0, CHART_WIDTH_IN_PIXELS) - 12, maxLen * 7 + 12));
   int h = 3 * 15 + 4;
   if(g_status.Width() != w || g_status.Height() != h)
      g_status.Resize(w, h);

   g_status.Erase(ColorToARGB(clrBlack, 0));
   g_status.FillRectangle(0, 0, w - 1, h - 1, ColorToARGB(clrBlack, 150));
   g_status.FontSet("Arial", 12);
   for(int i = 0; i < 3; i++)
      g_status.TextOut(4, 2 + i * 15, g_stTxt[i], ColorToARGB(g_stClr[i], 255));
   g_status.Update();
}
//+------------------------------------------------------------------+
