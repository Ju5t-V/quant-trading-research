//+------------------------------------------------------------------+
//|                                  Fibonacci_BOS_Setup_ZigZag.mq5  |
//|   Faithful MQL5 port of the Pine Script v6 indicator             |
//|   "Fibonacci BOS Setup (ZigZag - Entry Zone - TP1-3 - SL)"       |
//|                                                                  |
//|   Visual analysis only - places no trades.                       |
//|   Non-repainting by construction (confirmed pivots only).        |
//|                                                                  |
//|   ADDED ON TOP OF THE ORIGINAL BASE VERSION:                     |
//|     - Trial / Expiration system (Section 7)                      |
//|     - Configurable Information Panel (Section 8)                 |
//|     - Bar-close countdown row in the panel (v1.11)               |
//|     - ZigZag rendering rebuild: continuous polyline via a        |
//|       provisional leg, + optional live leg (v1.12)               |
//|   No existing trading logic was changed.                         |
//+------------------------------------------------------------------+
#property copyright "523 - MDC"
#property version   "1.12"
#property indicator_chart_window
#property indicator_buffers 0
#property indicator_plots   0

//+------------------------------------------------------------------+
//| ENUMS                                                            |
//+------------------------------------------------------------------+
enum ENUM_TXTSIZE
  {
   TS_TINY   = 0,  // Tiny
   TS_SMALL  = 1,  // Small
   TS_NORMAL = 2,  // Normal
   TS_LARGE  = 3   // Large
  };

enum ENUM_LSTYLE
  {
   LS_SOLID  = 0,  // Solid
   LS_DASHED = 1,  // Dashed
   LS_DOTTED = 2   // Dotted
  };

enum ENUM_PTSRC
  {
   PT_AUTO   = 0,  // Auto (symbol tick size)
   PT_CUSTOM = 1   // Custom
  };

enum ENUM_PANELCORNER
  {
   PC_TOPLEFT  = 0,  // Top Left
   PC_TOPRIGHT = 1,  // Top Right
   PC_BOTLEFT  = 2,  // Bottom Left
   PC_BOTRIGHT = 3   // Bottom Right
  };

//+------------------------------------------------------------------+
//| 1 - ZIGZAG SETTINGS                                              |
//+------------------------------------------------------------------+
input group "1 - ZigZag Settings"
input int     InpDepth        = 12;                  // Depth
input int     InpDeviation    = 5;                   // Deviation (points)
input int     InpBackstep     = 3;                   // Backstep (bars)
input bool    InpShowZZ       = true;                // Draw ZigZag line
input int     InpZZSegments   = 30;                  // Max ZigZag segments
input color   InpZZColor      = clrGray;             // ZigZag colour
input bool    InpZZLiveLeg    = false;               // Draw live (repainting) leg

//+------------------------------------------------------------------+
//| 2 - FIBONACCI LEVELS                                             |
//+------------------------------------------------------------------+
input group "2 - Fibonacci Levels"
input double  InpZ1Hi         =  1.200;              // Zone 1 - Upper
input double  InpZ1Mid        =  1.150;              // Zone 1 - Midpoint
input double  InpZ1Lo         =  1.100;              // Zone 1 - Lower
input double  InpEnHi         =  0.805;              // Entry - Upper lvl
input double  InpEnMid        =  0.755;              // Entry - Midpoint
input double  InpEnLo         =  0.705;              // Entry - Lower lvl
input double  InpTP1          =  0.500;              // TP 1
input double  InpTP2          =  0.205;              // TP 2
input double  InpTP3          = -0.265;              // TP 3

//+------------------------------------------------------------------+
//| 3 - RISK MANAGEMENT                                              |
//+------------------------------------------------------------------+
input group "3 - Risk Management"
input int         InpSLPoints = 300;                 // SL distance (points)
input ENUM_PTSRC  InpPtMode   = PT_AUTO;             // Point size source
input double      InpPtCustom = 0.01;                // Custom point size

//+------------------------------------------------------------------+
//| 4 - VISUAL SETTINGS                                              |
//+------------------------------------------------------------------+
input group "4 - Visual Settings"
input bool         InpShowFib      = false;          // Show Fibonacci levels
input bool         InpShowZone1    = true;           // Show Zone 1 (1.1-1.2)
input bool         InpShowEntryBox = true;           // Show Entry Box
input bool         InpShowTP       = true;           // Show TP levels
input bool         InpShowSL       = false;          // Show SL
input bool         InpShowSwingLab = true;           // Show Swing labels
input bool         InpShowPriceLab = true;           // Show Price labels
input bool         InpShowHistory  = false;          // Show Historical Setups
input int          InpMaxHistory   = 5;              // Maximum Historical Setups
input int          InpRightExt     = 25;             // Extend right (bars)
input int          InpPricePrec    = 2;              // Price decimals
input int          InpBoxTransp    = 85;             // Entry Box transparency
input bool         InpBoxBorder    = true;           // Entry Box border
input int          InpBoxBorderW   = 2;              // Entry Box border width
input bool         InpBoxText      = true;           // Entry Box text
input ENUM_TXTSIZE InpBoxTextSize  = TS_NORMAL;      // Entry Box text size
input int          InpTPWidth      = 2;              // TP line width
input ENUM_LSTYLE  InpTPStyle      = LS_SOLID;       // TP line style
input bool         InpTPLabShow    = true;           // TP labels
input ENUM_TXTSIZE InpTPLabSize    = TS_SMALL;       // TP / SL label size
input ENUM_TXTSIZE InpFibLabSize   = TS_TINY;        // Fib label size
input color        InpColBull      = C'38,166,154';  // Bullish zone colour
input color        InpColBear      = C'239,83,80';   // Bearish zone colour
input color        InpColZone1     = C'255,215,0';   // Zone 1 colour
input color        InpColTP        = C'0,188,212';   // TP colour
input color        InpColSL        = C'242,54,69';   // SL colour
input color        InpColFib       = C'178,181,190'; // Fibonacci colour
input color        InpColSwing     = C'120,123,134'; // Swing label colour
input color        InpColTxt       = clrWhite;       // Label text colour

//+------------------------------------------------------------------+
//| 5 - ALERTS                                                       |
//+------------------------------------------------------------------+
input group "5 - Alerts"
input bool   InpAlertBullSetup = true;   // Alert - New Bullish Setup
input bool   InpAlertBearSetup = true;   // Alert - New Bearish Setup
input bool   InpAlertBullZone  = true;   // Alert - Bullish Entry Zone
input bool   InpAlertBearZone  = true;   // Alert - Bearish Entry Zone
input bool   InpAlertTP1       = true;   // Alert - TP 1 reached
input bool   InpAlertTP2       = true;   // Alert - TP 2 reached
input bool   InpAlertTP3       = true;   // Alert - TP 3 reached
input bool   InpAlertSL        = true;   // Alert - SL reached
input bool   InpGateAfterEntry = true;   // TP/SL alerts only after Entry Zone touched

input group "6 - Notification Methods"
input bool   InpUsePopup       = true;             // Enable Popup Alerts
input bool   InpUsePush        = false;            // Enable Push Notifications
input bool   InpUseSound       = true;             // Enable Sound Alerts
input string InpSoundFile      = "alert.wav";      // Sound file
input bool   InpUseEmail       = false;            // Enable Email Alerts

//+------------------------------------------------------------------+
//| 7 - TRIAL / LICENSE                                               |
//+------------------------------------------------------------------+
input group "7 - TRIAL / LICENSE"
input bool     InpEnableExpiry   = true;                    // Enable Expiration
input datetime InpExpiryDate     = D'2026.12.31 23:59';     // Expiration Date
input bool     InpShowExpiryWarn = true;                    // Show Expiration Warning
input int      InpWarnDays       = 7;                       // Warning Days Before Expiry
input bool     InpWarnAlert      = false;                   // Alert on Warning Threshold (popup/push/sound)

//+------------------------------------------------------------------+
//| 8 - INFORMATION PANEL                                            |
//+------------------------------------------------------------------+
input group "8 - Information Panel"
input bool             InpShowPanel   = true;         // Show Panel
input ENUM_PANELCORNER InpPanelPos    = PC_TOPLEFT;    // Panel Position
input int               InpPanelWidth  = 230;           // Panel Width
input int               InpPanelHeight = 0;             // Panel Height (0 = auto)
input int               InpPanelX      = 10;            // Panel X Offset
input int               InpPanelY      = 20;            // Panel Y Offset
input color              InpPanelBg     = C'20,20,24';   // Panel Background colour
input int                InpPanelTransp = 15;            // Panel Background transparency (0-100)
input color              InpPanelBorder = C'90,90,100';  // Panel Border colour
input color              InpPanelTitleC = clrWhite;      // Panel Title colour
input color              InpPanelHeadC  = C'0,188,212';  // Panel Section-header colour
input color              InpPanelTxtC   = C'220,220,225';// Panel Text colour
input color              InpPanelDimC   = C'140,140,148';// Panel Dim/placeholder colour
input color              InpPanelBullC  = C'38,166,154'; // Panel Bullish colour
input color              InpPanelBearC  = C'239,83,80';  // Panel Bearish colour
input color              InpPanelWarnC  = C'255,193,7';  // Panel Warning colour
input color              InpPanelExpC   = C'242,54,69';  // Panel Expired colour

input group "8a - Panel Content"
input bool   InpPnlSymbol   = true;   // Show Symbol
input bool   InpPnlTF       = true;   // Show Timeframe
input bool   InpPnlCountdown = true;  // Show Bar Countdown
input int    InpPnlCdWarnSecs = 10;   // Countdown warning colour under N seconds
input bool   InpPnlStatus   = true;   // Show Status
input bool   InpPnlZZ       = true;   // Show ZigZag Settings
input bool   InpPnlStruct   = true;   // Show Current Structure
input bool   InpPnlBOS      = true;   // Show BOS Status
input bool   InpPnlEntry    = true;   // Show Entry Price
input bool   InpPnlTP       = true;   // Show TP Levels
input bool   InpPnlSL       = true;   // Show SL
input bool   InpPnlExpiry   = true;   // Show Expiration
input bool   InpPnlPrice    = true;   // Show Current Price
input bool   InpPnlSpread   = true;   // Show Spread
input bool   InpPnlAlerts   = true;   // Show Alerts status

//+------------------------------------------------------------------+
//| GLOBALS                                                          |
//+------------------------------------------------------------------+
#define PFX "FBS_"

double  g_point      = 0.0;       // resolved point size
int     g_depth      = 12;
int     g_deviation  = 5;
int     g_backstep   = 3;
int     g_maxHist    = 5;
int     g_prec       = 2;
int     g_rightExt   = 25;

// --- ZigZag state machine (mirrors Pine lastP/lastB/lastD/prevP/prevB) ---
double  g_lastP = 0.0;
int     g_lastB = -1;
int     g_lastD = 0;            // +1 = swing high, -1 = swing low
double  g_prevP = 0.0;
int     g_prevB = -1;
bool    g_hasPrev = false;

bool    g_bullUsed = false;
bool    g_bearUsed = false;

int     g_processed = 0;        // index of next bar to process
int     g_setupId   = 0;
bool    g_alertsOn  = false;    // suppressed during the initial history pass

string  g_zzNames[];            // ZigZag polyline object names (committed legs)

// --- ZigZag rendering state (v1.12) -------------------------------------
// The newest leg is PROVISIONAL: its right endpoint keeps moving while
// same-direction pivots extend it, so it lives in one reused object and is
// only committed to a permanent, index-named object once the chain advances.
// Written only by the ZZ* draw helpers - no signal code reads any of these.
double  g_zzProvAP   = 0.0;     // provisional leg - left anchor price
int     g_zzProvAB   = -1;      // provisional leg - left anchor bar
double  g_zzProvBP   = 0.0;     // provisional leg - right endpoint price
int     g_zzProvBB   = -1;      // provisional leg - right endpoint bar
bool    g_zzHasProv  = false;   // a provisional leg is currently drawn
bool    g_zzHasLive  = false;   // the live-leg object currently exists

// --- Trial / expiration state ---
bool    g_warnAlerted = false;  // one-shot flag so the warning alert doesn't spam

//+------------------------------------------------------------------+
//| SETUP OBJECT                                                     |
//+------------------------------------------------------------------+
class CSetup
  {
public:
   int      id;
   int      dir;
   double   a0, a1;
   int      leftBar;
   int      extBar;
   int      createBar;
   double   enA, enB, enMid;
   double   boxTop, boxBot;
   double   tp1, tp2, tp3, sl;
   bool     active, inZone, touched;
   bool     t1, t2, t3, slHit;
   string   objs[];

            CSetup(void)
     {
      id=0; dir=0; a0=0.0; a1=0.0; leftBar=0; extBar=0; createBar=0;
      enA=0.0; enB=0.0; enMid=0.0; boxTop=0.0; boxBot=0.0;
      tp1=0.0; tp2=0.0; tp3=0.0; sl=0.0;
      active=true; inZone=false; touched=false;
      t1=false; t2=false; t3=false; slHit=false;
      ArrayResize(objs,0);
     }

   void     AddObj(const string nm)
     {
      int n=ArraySize(objs);
      ArrayResize(objs,n+1);
      objs[n]=nm;
     }

   void     Kill(void)
     {
      for(int i=0; i<ArraySize(objs); i++)
         ObjectDelete(0,objs[i]);
      ArrayResize(objs,0);
     }
  };

CSetup *g_setups[];

//+------------------------------------------------------------------+
//| SMALL HELPERS                                                    |
//+------------------------------------------------------------------+
int TxtSize(const ENUM_TXTSIZE s)
  {
   switch(s)
     {
      case TS_TINY:   return 7;
      case TS_SMALL:  return 8;
      case TS_LARGE:  return 12;
      default:        return 10;
     }
  }

ENUM_LINE_STYLE LStyle(const ENUM_LSTYLE s)
  {
   switch(s)
     {
      case LS_DASHED: return STYLE_DASH;
      case LS_DOTTED: return STYLE_DOT;
      default:        return STYLE_SOLID;
     }
  }

string FmtPx(const double v)
  {
   return DoubleToString(v,g_prec);
  }

// MT5 chart objects have no alpha channel: emulate Pine transparency by
// blending the colour towards the current chart background colour.
color Blend(const color c,const int transp)
  {
   int t = (int)MathMax(0,MathMin(100,transp));
   color bg = (color)ChartGetInteger(0,CHART_COLOR_BACKGROUND);
   double a = 1.0 - t/100.0;
   int c0=(int)(c&0xFF),      c1=(int)((c>>8)&0xFF),  c2=(int)((c>>16)&0xFF);
   int b0=(int)(bg&0xFF),     b1=(int)((bg>>8)&0xFF), b2=(int)((bg>>16)&0xFF);
   int r0=(int)(c0*a + b0*(1.0-a));
   int r1=(int)(c1*a + b1*(1.0-a));
   int r2=(int)(c2*a + b2*(1.0-a));
   return (color)((r2<<16)|(r1<<8)|r0);
  }

// Fibonacci price for level L given anchors a0 (level 0) and a1 (level 1)
double FibPrice(const double a0,const double a1,const double L)
  {
   return a0 + L*(a1-a0);
  }

string TfString(void)
  {
   string s = EnumToString((ENUM_TIMEFRAMES)_Period);   // e.g. PERIOD_M5
   int p = StringFind(s,"_");
   if(p>=0)
      return StringSubstr(s,p+1);
   return s;
  }

datetime RightTime(const datetime &time[],const int rates_total)
  {
   int last = rates_total-1;
   if(last<0)
      return (datetime)TimeCurrent();
   return (datetime)(time[last] + (long)g_rightExt*PeriodSeconds(_Period));
  }

datetime BarTime(const datetime &time[],const int rates_total,const int idx)
  {
   int i = (int)MathMax(0,MathMin(rates_total-1,idx));
   return time[i];
  }

//+------------------------------------------------------------------+
//| OBJECT CREATION                                                  |
//+------------------------------------------------------------------+
void MkLine(CSetup *s,const string nm,const datetime t1,const double p1,
            const datetime t2,const double p2,const color c,const int w,
            const ENUM_LINE_STYLE st)
  {
   if(ObjectFind(0,nm)<0)
      ObjectCreate(0,nm,OBJ_TREND,0,t1,p1,t2,p2);
   ObjectSetInteger(0,nm,OBJPROP_TIME,0,t1);
   ObjectSetDouble (0,nm,OBJPROP_PRICE,0,p1);
   ObjectSetInteger(0,nm,OBJPROP_TIME,1,t2);
   ObjectSetDouble (0,nm,OBJPROP_PRICE,1,p2);
   ObjectSetInteger(0,nm,OBJPROP_COLOR,c);
   ObjectSetInteger(0,nm,OBJPROP_WIDTH,w);
   ObjectSetInteger(0,nm,OBJPROP_STYLE,st);
   ObjectSetInteger(0,nm,OBJPROP_RAY_LEFT,false);
   ObjectSetInteger(0,nm,OBJPROP_RAY_RIGHT,false);
   ObjectSetInteger(0,nm,OBJPROP_BACK,false);
   ObjectSetInteger(0,nm,OBJPROP_SELECTABLE,false);
   ObjectSetInteger(0,nm,OBJPROP_SELECTED,false);
   ObjectSetInteger(0,nm,OBJPROP_HIDDEN,true);
   if(s!=NULL)
      s.AddObj(nm);
  }

void MkText(CSetup *s,const string nm,const datetime t,const double p,
            const string txt,const color c,const int fsize,
            const ENUM_ANCHOR_POINT anchor)
  {
   if(ObjectFind(0,nm)<0)
      ObjectCreate(0,nm,OBJ_TEXT,0,t,p);
   ObjectSetInteger(0,nm,OBJPROP_TIME,0,t);
   ObjectSetDouble (0,nm,OBJPROP_PRICE,0,p);
   ObjectSetString (0,nm,OBJPROP_TEXT,txt);
   ObjectSetInteger(0,nm,OBJPROP_COLOR,c);
   ObjectSetInteger(0,nm,OBJPROP_FONTSIZE,fsize);
   ObjectSetString (0,nm,OBJPROP_FONT,"Arial");
   ObjectSetInteger(0,nm,OBJPROP_ANCHOR,anchor);
   ObjectSetInteger(0,nm,OBJPROP_BACK,false);
   ObjectSetInteger(0,nm,OBJPROP_SELECTABLE,false);
   ObjectSetInteger(0,nm,OBJPROP_SELECTED,false);
   ObjectSetInteger(0,nm,OBJPROP_HIDDEN,true);
   if(s!=NULL)
      s.AddObj(nm);
  }

void MkRect(CSetup *s,const string nm,const datetime t1,const double p1,
            const datetime t2,const double p2,const color c,
            const bool fill,const int width)
  {
   if(ObjectFind(0,nm)<0)
      ObjectCreate(0,nm,OBJ_RECTANGLE,0,t1,p1,t2,p2);
   ObjectSetInteger(0,nm,OBJPROP_TIME,0,t1);
   ObjectSetDouble (0,nm,OBJPROP_PRICE,0,p1);
   ObjectSetInteger(0,nm,OBJPROP_TIME,1,t2);
   ObjectSetDouble (0,nm,OBJPROP_PRICE,1,p2);
   ObjectSetInteger(0,nm,OBJPROP_COLOR,c);
   ObjectSetInteger(0,nm,OBJPROP_FILL,fill);
   ObjectSetInteger(0,nm,OBJPROP_WIDTH,width);
   ObjectSetInteger(0,nm,OBJPROP_STYLE,STYLE_SOLID);
   ObjectSetInteger(0,nm,OBJPROP_BACK,fill);
   ObjectSetInteger(0,nm,OBJPROP_SELECTABLE,false);
   ObjectSetInteger(0,nm,OBJPROP_SELECTED,false);
   ObjectSetInteger(0,nm,OBJPROP_HIDDEN,true);
   if(s!=NULL)
      s.AddObj(nm);
  }

//+------------------------------------------------------------------+
//| SETUP ARRAY MANAGEMENT                                           |
//+------------------------------------------------------------------+
void PushSetup(CSetup *s)
  {
   int n=ArraySize(g_setups);
   ArrayResize(g_setups,n+1);
   g_setups[n]=s;
  }

void RemoveSetupAt(const int idx)
  {
   int n=ArraySize(g_setups);
   if(idx<0 || idx>=n)
      return;
   if(CheckPointer(g_setups[idx])!=POINTER_INVALID)
     {
      g_setups[idx].Kill();
      delete g_setups[idx];
     }
   for(int i=idx; i<n-1; i++)
      g_setups[i]=g_setups[i+1];
   ArrayResize(g_setups,n-1);
  }

void ClearAllSetups(void)
  {
   for(int i=ArraySize(g_setups)-1; i>=0; i--)
      RemoveSetupAt(i);
   ArrayResize(g_setups,0);
  }

void ClearZigZag(void)
  {
   for(int i=0; i<ArraySize(g_zzNames); i++)
      ObjectDelete(0,g_zzNames[i]);
   ArrayResize(g_zzNames,0);
   //--- the two single-instance legs are not in g_zzNames, so delete them here
   ObjectDelete(0,PFX+"zz_prov");
   ObjectDelete(0,PFX+"zz_live");
   g_zzProvAP=0.0; g_zzProvAB=-1;
   g_zzProvBP=0.0; g_zzProvBB=-1;
   g_zzHasProv=false;
   g_zzHasLive=false;
  }

//+------------------------------------------------------------------+
//| ZIGZAG RENDERING (v1.12)                                         |
//|                                                                  |
//| Visual layer only. These helpers read the ZigZag state machine   |
//| but never write to it, so no setup, entry zone, TP or SL can be  |
//| affected by anything in this section.                            |
//+------------------------------------------------------------------+

// The provisional leg has become final (the chain advanced past it): copy it
// into a permanent object named after its two bar indices and let the
// existing InpZZSegments FIFO own it from here on.
void ZZCommitProvisional(const datetime &time[],const int rates_total)
  {
   if(!g_zzHasProv)
      return;

   string nm = PFX + "zz_" + IntegerToString(g_zzProvAB) + "_" + IntegerToString(g_zzProvBB);
   MkLine(NULL,nm,BarTime(time,rates_total,g_zzProvAB),g_zzProvAP,
          BarTime(time,rates_total,g_zzProvBB),g_zzProvBP,InpZZColor,1,STYLE_SOLID);

   int k=ArraySize(g_zzNames);
   ArrayResize(g_zzNames,k+1);
   g_zzNames[k]=nm;
   while(ArraySize(g_zzNames)>InpZZSegments)
     {
      ObjectDelete(0,g_zzNames[0]);
      int m=ArraySize(g_zzNames);
      for(int i=0; i<m-1; i++)
         g_zzNames[i]=g_zzNames[i+1];
      ArrayResize(g_zzNames,m-1);
     }

   g_zzHasProv=false;
  }

// Point the single provisional object at the current newest leg,
// prev swing -> last swing. Called on every confirmed pivot that touches the
// chain, so an extension moves this endpoint in place instead of stranding it.
void ZZUpdateProvisional(const datetime &time[],const int rates_total)
  {
   g_zzProvAB=g_prevB;  g_zzProvAP=g_prevP;
   g_zzProvBB=g_lastB;  g_zzProvBP=g_lastP;
   g_zzHasProv=true;

   MkLine(NULL,PFX+"zz_prov",BarTime(time,rates_total,g_zzProvAB),g_zzProvAP,
          BarTime(time,rates_total,g_zzProvBB),g_zzProvBP,InpZZColor,1,STYLE_SOLID);
  }

void ZZHideLive(void)
  {
   if(g_zzHasLive)
      ObjectSetInteger(0,PFX+"zz_live",OBJPROP_TIMEFRAMES,OBJ_NO_PERIODS);
  }

// Optional dashed leg from the last confirmed swing to the running extreme of
// the developing move, including the forming bar. REPAINTS by design - it is
// off unless the user asks for it.
void ZZUpdateLiveLeg(const datetime &time[],const int rates_total,
                     const double &high[],const double &low[])
  {
   if(!InpShowZZ || !InpZZLiveLeg || g_lastD==0 || g_lastB<0)
     {
      ZZHideLive();
      return;
     }

   int cur = rates_total-1;
   if(cur<=g_lastB)
     {
      ZZHideLive();
      return;
     }

   // window [g_lastB, cur] inclusive; HighestHigh/LowestLow scan back from cur
   int    len = cur-g_lastB+1;
   double xv  = 0.0;
   int    xb  = cur;
   if(g_lastD==-1)
      HighestHigh(high,cur,len,xv,xb);   // last swing was a LOW  -> leg is UP
   else
      LowestLow(low,cur,len,xv,xb);      // last swing was a HIGH -> leg is DOWN

   //--- degenerate: the extreme is still the swing itself, there is no leg yet
   if(xb==g_lastB)
     {
      ZZHideLive();
      return;
     }

   //--- same deviation filter the state machine applies before advancing, so a
   //--- one-tick wiggle cannot spawn a line.
   //--- NOTE: deliberately NOT backstep-filtered. This leg can therefore show a
   //--- move that the chain would later refuse to confirm. That is intended:
   //--- it is a preview of the developing move, not a prediction that the swing
   //--- will be confirmed.
   if(MathAbs(xv-g_lastP) < g_deviation*g_point)
     {
      ZZHideLive();
      return;
     }

   //--- one object, updated in place - never recreated per tick
   MkLine(NULL,PFX+"zz_live",BarTime(time,rates_total,g_lastB),g_lastP,
          BarTime(time,rates_total,xb),xv,Blend(InpZZColor,45),1,STYLE_DASH);
   ObjectSetInteger(0,PFX+"zz_live",OBJPROP_TIMEFRAMES,OBJ_ALL_PERIODS);
   g_zzHasLive=true;
  }

void ResetAll(void)
  {
   ClearAllSetups();
   ClearZigZag();
   ObjectsDeleteAll(0,PFX);
   g_lastP=0.0; g_lastB=-1; g_lastD=0;
   g_prevP=0.0; g_prevB=-1; g_hasPrev=false;
   g_bullUsed=false; g_bearUsed=false;
   g_processed=0;
   g_setupId=0;
   g_alertsOn=false;
   CreatePanel();   // recreate panel objects since ObjectsDeleteAll wiped them (same PFX prefix)
  }

//+------------------------------------------------------------------+
//| ============ TRIAL / EXPIRATION SYSTEM (ADDED) ================ |
//| Central, single source of truth for the licence state so every  |
//| signal / alert path can be gated through the same check.        |
//+------------------------------------------------------------------+

// Uses TimeCurrent() (MT5 server/platform time) rather than the local PC
// clock, and the comparison is against a fixed calendar input, so changing
// the chart timeframe or reloading the indicator cannot reset or bypass it.
bool IsExpired(void)
  {
   if(!InpEnableExpiry)
      return false;
   return (TimeCurrent() >= InpExpiryDate);
  }

bool IsInWarningWindow(void)
  {
   if(!InpEnableExpiry || !InpShowExpiryWarn)
      return false;
   if(IsExpired())
      return false;
   long secsLeft = (long)(InpExpiryDate - TimeCurrent());
   long warnSecs = (long)InpWarnDays*86400;
   return (secsLeft>=0 && secsLeft<=warnSecs);
  }

// Whole days remaining, rounded up (e.g. 30h left -> "2 days")
int DaysToExpiry(void)
  {
   long secsLeft = (long)(InpExpiryDate - TimeCurrent());
   if(secsLeft<0)
      secsLeft=0;
   int days = (int)(secsLeft/86400);
   if(secsLeft%86400 > 0)
      days++;
   return days;
  }

string ExpiryDateString(void)
  {
   MqlDateTime dt;
   TimeToStruct(InpExpiryDate,dt);
   static string months[12] = {"Jan","Feb","Mar","Apr","May","Jun","Jul","Aug","Sep","Oct","Nov","Dec"};
   string mon = (dt.mon>=1 && dt.mon<=12) ? months[dt.mon-1] : "";
   return StringFormat("%02d %s %04d",dt.day,mon,dt.year);
  }

// One-shot (non-spamming) alert when the warning window is first entered.
void CheckExpiryWarningAlert(void)
  {
   if(!InpWarnAlert)
      return;
   if(IsInWarningWindow())
     {
      if(!g_warnAlerted)
        {
         g_warnAlerted=true;
         Notify_Raw("TRIAL EXPIRING SOON\nExpires: "+ExpiryDateString()+" ("+IntegerToString(DaysToExpiry())+" day(s) left)");
        }
     }
   else
      g_warnAlerted=false;
  }

//+------------------------------------------------------------------+
//| NOTIFICATIONS                                                    |
//+------------------------------------------------------------------+
// Low-level sender used both by the normal trading alerts and by the
// (optional) expiry-warning alert. Does NOT itself check IsExpired(),
// since the warning alert must still fire while the trial is active.
void Notify_Raw(const string body)
  {
   string head = _Symbol + " " + TfString();
   string msg  = head + "\n" + body;

   if(InpUsePopup)
      Alert(msg);
   if(InpUsePush)
      SendNotification(msg);
   if(InpUseSound && StringLen(InpSoundFile)>0)
      PlaySound(InpSoundFile);
   if(InpUseEmail)
      SendMail(head + " - Fibonacci BOS Setup", msg);
   Print("[FBS] ",StringSubstr(msg,0,400));
  }

void Notify(const string body)
  {
   if(!g_alertsOn)
      return;
   // Central expiry gate: once the trial has expired, no trading alert of
   // any kind (setup / zone / TP / SL) is allowed to fire, from any path.
   if(IsExpired())
      return;
   Notify_Raw(body);
  }

void NotifySetup(CSetup *s)
  {
   if(s==NULL)
      return;
   if(s.dir==1 && !InpAlertBullSetup)
      return;
   if(s.dir==-1 && !InpAlertBearSetup)
      return;
   string body = (s.dir==1 ? "BULLISH" : "BEARISH") + " Fibonacci Setup\n"
                 + "Entry: " + FmtPx(s.boxBot) + " - " + FmtPx(s.boxTop) + "\n"
                 + "TP1: " + FmtPx(s.tp1) + "\n"
                 + "TP2: " + FmtPx(s.tp2) + "\n"
                 + "TP3: " + FmtPx(s.tp3) + "\n"
                 + "SL: "  + FmtPx(s.sl);
   Notify(body);
  }

void NotifyZone(CSetup *s)
  {
   if(s==NULL)
      return;
   if(s.dir==1 && !InpAlertBullZone)
      return;
   if(s.dir==-1 && !InpAlertBearZone)
      return;
   string body = (s.dir==1 ? "BULLISH" : "BEARISH") + " ENTRY ZONE\n"
                 + "Entry: " + FmtPx(s.boxBot) + " - " + FmtPx(s.boxTop);
   Notify(body);
  }

void NotifyLevel(const string tag,const double price,const bool enabled)
  {
   if(!enabled)
      return;
   Notify(tag + " REACHED\nPrice: " + FmtPx(price));
  }

//+------------------------------------------------------------------+
//| PIVOTS - replication of ta.pivothigh / ta.pivotlow               |
//| A pivot at bar p needs `depth` bars on BOTH sides and is only    |
//| confirmed once bar p+depth has closed.                           |
//+------------------------------------------------------------------+
bool IsPivotHigh(const double &high[],const int p,const int depth,const int rates_total)
  {
   if(p-depth<0 || p+depth>rates_total-1)
      return false;
   double v=high[p];
   for(int i=p-depth; i<=p+depth; i++)
     {
      if(i==p)
         continue;
      if(high[i]>=v)
         return false;
     }
   return true;
  }

bool IsPivotLow(const double &low[],const int p,const int depth,const int rates_total)
  {
   if(p-depth<0 || p+depth>rates_total-1)
      return false;
   double v=low[p];
   for(int i=p-depth; i<=p+depth; i++)
     {
      if(i==p)
         continue;
      if(low[i]<=v)
         return false;
     }
   return true;
  }

// Highest high (and its bar) over the last `len` bars ending at bar b.
// Ties keep the MOST RECENT bar - identical to the Pine f_hh() loop.
void HighestHigh(const double &high[],const int b,const int len,double &val,int &idx)
  {
   val=high[b];
   idx=b;
   for(int i=1; i<len; i++)
     {
      int j=b-i;
      if(j<0)
         break;
      if(high[j]>val)
        {
         val=high[j];
         idx=j;
        }
     }
  }

void LowestLow(const double &low[],const int b,const int len,double &val,int &idx)
  {
   val=low[b];
   idx=b;
   for(int i=1; i<len; i++)
     {
      int j=b-i;
      if(j<0)
         break;
      if(low[j]<val)
        {
         val=low[j];
         idx=j;
        }
     }
  }

//+------------------------------------------------------------------+
//| BUILD ALL OBJECTS FOR A SETUP                                    |
//+------------------------------------------------------------------+
void BuildFibLine(CSetup *s,const string tag,const double lvl,const color c,
                  const int w,const ENUM_LSTYLE st,const datetime tLeft,
                  const datetime tRight)
  {
   double p = FibPrice(s.a0,s.a1,lvl);
   string nm = PFX + IntegerToString(s.id) + "_fib_" + tag;
   MkLine(s,nm,tLeft,p,tRight,p,c,w,LStyle(st));
   if(InpShowPriceLab)
      MkText(s,nm+"_lab",tRight,p,FmtPx(p),c,TxtSize(InpFibLabSize),ANCHOR_LEFT);
  }

void BuildLevelLine(CSetup *s,const string tag,const double p,const color c,
                    const int w,const ENUM_LSTYLE st,const bool lab,
                    const datetime tLeft,const datetime tRight)
  {
   string nm = PFX + IntegerToString(s.id) + "_lvl_" + tag;
   MkLine(s,nm,tLeft,p,tRight,p,c,w,LStyle(st));
   if(lab)
      MkText(s,nm+"_lab",tRight,p,FmtPx(p),c,TxtSize(InpTPLabSize),ANCHOR_LEFT);
  }

void BuildSetup(CSetup *s,const datetime &time[],const int rates_total)
  {
   datetime tLeft  = BarTime(time,rates_total,s.leftBar);
   datetime tRight = RightTime(time,rates_total);
   color    zcol   = (s.dir==1 ? InpColBull : InpColBear);
   bool     isBull = (s.dir==1);
   string   base   = PFX + IntegerToString(s.id);

   //--- Fibonacci structure lines -------------------------------------
   if(InpShowFib)
     {
      BuildFibLine(s,"1",  1.0,      InpColFib,1,LS_SOLID, tLeft,tRight);
      BuildFibLine(s,"0",  0.0,      InpColFib,1,LS_SOLID, tLeft,tRight);
      BuildFibLine(s,"eH", InpEnHi,  InpColFib,1,LS_DOTTED,tLeft,tRight);
      BuildFibLine(s,"eM", InpEnMid, InpColFib,1,LS_DASHED,tLeft,tRight);
      BuildFibLine(s,"eL", InpEnLo,  InpColFib,1,LS_DOTTED,tLeft,tRight);
      if(InpShowZone1)
        {
         BuildFibLine(s,"z1H",InpZ1Hi, InpColZone1,1,LS_DOTTED,tLeft,tRight);
         BuildFibLine(s,"z1M",InpZ1Mid,InpColZone1,1,LS_DASHED,tLeft,tRight);
         BuildFibLine(s,"z1L",InpZ1Lo, InpColZone1,1,LS_DOTTED,tLeft,tRight);
        }
     }

   //--- Zone 1 box -----------------------------------------------------
   if(InpShowZone1)
     {
      double z1a = FibPrice(s.a0,s.a1,InpZ1Hi);
      double z1b = FibPrice(s.a0,s.a1,InpZ1Lo);
      double zTop = MathMax(z1a,z1b);
      double zBot = MathMin(z1a,z1b);
      MkRect(s,base+"_z1fill",tLeft,zTop,tRight,zBot,
             Blend(InpColZone1,(int)MathMin(InpBoxTransp+8,100)),true,1);
      if(InpBoxBorder)
         MkRect(s,base+"_z1edge",tLeft,zTop,tRight,zBot,InpColZone1,false,1);
      if(InpBoxText)
         MkText(s,base+"_z1txt",tLeft,(zTop+zBot)/2.0,
                FmtPx(zTop)+" - "+FmtPx(zBot),InpColZone1,
                TxtSize(InpFibLabSize),ANCHOR_LEFT);
     }

   //--- Entry Box ------------------------------------------------------
   if(InpShowEntryBox)
     {
      MkRect(s,base+"_enfill",tLeft,s.boxTop,tRight,s.boxBot,
             Blend(zcol,InpBoxTransp),true,1);
      if(InpBoxBorder)
         MkRect(s,base+"_enedge",tLeft,s.boxTop,tRight,s.boxBot,zcol,false,
                (int)MathMax(1,InpBoxBorderW));
      if(InpBoxText)
        {
         datetime tMid = (datetime)(tLeft + (tRight-tLeft)/2);
         MkText(s,base+"_entxt",tMid,(s.boxTop+s.boxBot)/2.0,
                FmtPx(s.boxTop)+" - "+FmtPx(s.boxBot),zcol,
                TxtSize(InpBoxTextSize),ANCHOR_CENTER);
        }
     }

   //--- TP levels ------------------------------------------------------
   if(InpShowTP)
     {
      BuildLevelLine(s,"tp1",s.tp1,InpColTP,InpTPWidth,InpTPStyle,InpTPLabShow,tLeft,tRight);
      BuildLevelLine(s,"tp2",s.tp2,InpColTP,InpTPWidth,InpTPStyle,InpTPLabShow,tLeft,tRight);
      BuildLevelLine(s,"tp3",s.tp3,InpColTP,InpTPWidth,InpTPStyle,InpTPLabShow,tLeft,tRight);
     }

   //--- Stop Loss ------------------------------------------------------
   if(InpShowSL)
      BuildLevelLine(s,"sl",s.sl,InpColSL,InpTPWidth,LS_SOLID,InpTPLabShow,tLeft,tRight);

   //--- Swing anchor labels -------------------------------------------
   if(InpShowSwingLab)
     {
      string nA1 = isBull ? "Swing Low (1)"  : "Swing High (1)";
      string nA0 = isBull ? "Swing High (0)" : "Swing Low (0)";
      datetime tA0 = BarTime(time,rates_total,s.createBar);
      MkText(s,base+"_sw1",tLeft,s.a1,nA1+"  "+FmtPx(s.a1),InpColSwing,
             TxtSize(InpFibLabSize),isBull ? ANCHOR_UPPER : ANCHOR_LOWER);
      MkText(s,base+"_sw0",tA0,s.a0,nA0+"  "+FmtPx(s.a0),InpColSwing,
             TxtSize(InpFibLabSize),isBull ? ANCHOR_LOWER : ANCHOR_UPPER);
     }
  }

//+------------------------------------------------------------------+
//| EXTEND THE ACTIVE SETUP TO THE RIGHT                             |
//+------------------------------------------------------------------+
void ExtendActive(const datetime &time[],const int rates_total)
  {
   int n=ArraySize(g_setups);
   if(n<=0)
      return;
   CSetup *s=g_setups[n-1];
   if(CheckPointer(s)==POINTER_INVALID || !s.active)
      return;

   datetime tRight = RightTime(time,rates_total);
   datetime tLeft  = BarTime(time,rates_total,s.leftBar);

   for(int i=0; i<ArraySize(s.objs); i++)
     {
      string nm=s.objs[i];
      if(ObjectFind(0,nm)<0)
         continue;
      ENUM_OBJECT tp=(ENUM_OBJECT)ObjectGetInteger(0,nm,OBJPROP_TYPE);
      if(tp==OBJ_TREND || tp==OBJ_RECTANGLE)
         ObjectSetInteger(0,nm,OBJPROP_TIME,1,tRight);
      else
         if(tp==OBJ_TEXT)
           {
            if(StringFind(nm,"_lab")>=0)
               ObjectSetInteger(0,nm,OBJPROP_TIME,0,tRight);
            else
               if(StringFind(nm,"_entxt")>=0)
                  ObjectSetInteger(0,nm,OBJPROP_TIME,0,(datetime)(tLeft+(tRight-tLeft)/2));
           }
     }
  }

//+------------------------------------------------------------------+
//| LIVE STATE TRACKING (zone / TP / SL) for one bar                 |
//+------------------------------------------------------------------+
void TrackState(const double barHigh,const double barLow)
  {
   int n=ArraySize(g_setups);
   if(n<=0)
      return;
   CSetup *s=g_setups[n-1];
   if(CheckPointer(s)==POINTER_INVALID || !s.active)
      return;

   //--- Entry-zone transition: fires on ENTRY only -------------------
   bool inside = (barLow<=s.boxTop && barHigh>=s.boxBot);
   if(inside && !s.inZone)
      NotifyZone(s);
   s.inZone=inside;
   if(inside)
      s.touched=true;

   bool gate = (!InpGateAfterEntry) || s.touched;
   if(!gate)
      return;

   if(!s.t1 && (s.dir==1 ? barHigh>=s.tp1 : barLow<=s.tp1))
     {
      s.t1=true;
      NotifyLevel("TP1",s.tp1,InpAlertTP1);
     }
   if(!s.t2 && (s.dir==1 ? barHigh>=s.tp2 : barLow<=s.tp2))
     {
      s.t2=true;
      NotifyLevel("TP2",s.tp2,InpAlertTP2);
     }
   if(!s.t3 && (s.dir==1 ? barHigh>=s.tp3 : barLow<=s.tp3))
     {
      s.t3=true;
      NotifyLevel("TP3",s.tp3,InpAlertTP3);
     }
   if(!s.slHit && (s.dir==1 ? barLow<=s.sl : barHigh>=s.sl))
     {
      s.slHit=true;
      NotifyLevel("SL",s.sl,InpAlertSL);
     }
  }

//+------------------------------------------------------------------+
//| PROCESS ONE CLOSED BAR (full Pine bar logic)                     |
//+------------------------------------------------------------------+
void ProcessBar(const int b,const int rates_total,const datetime &time[],
                const double &high[],const double &low[],const double &close[])
  {
   bool newLowSwing  = false;
   bool newHighSwing = false;
   bool chainAdvance = false;

   int p = b - g_depth;   // candidate pivot bar confirmed on bar b

   //================= LOW PIVOT =====================================
   if(p>=0 && IsPivotLow(low,p,g_depth,rates_total))
     {
      double pv = low[p];
      if(g_lastD==0)
        {
         g_lastP=pv; g_lastB=p; g_lastD=-1;
         newLowSwing=true;
        }
      else
         if(g_lastD==-1)
           {
            if(pv<g_lastP)
              {
               g_lastP=pv; g_lastB=p;
               newLowSwing=true;
              }
           }
         else
           {
            if(MathAbs(g_lastP-pv)>=g_deviation*g_point && (p-g_lastB)>=g_backstep)
              {
               g_prevP=g_lastP; g_prevB=g_lastB; g_hasPrev=true;
               g_lastP=pv; g_lastB=p; g_lastD=-1;
               newLowSwing=true;
               chainAdvance=true;
              }
           }
     }

   //================= HIGH PIVOT ====================================
   if(p>=0 && IsPivotHigh(high,p,g_depth,rates_total))
     {
      double pv = high[p];
      if(g_lastD==0)
        {
         g_lastP=pv; g_lastB=p; g_lastD=1;
         newHighSwing=true;
        }
      else
         if(g_lastD==1)
           {
            if(pv>g_lastP)
              {
               g_lastP=pv; g_lastB=p;
               newHighSwing=true;
              }
           }
         else
           {
            if(MathAbs(pv-g_lastP)>=g_deviation*g_point && (p-g_lastB)>=g_backstep)
              {
               g_prevP=g_lastP; g_prevB=g_lastB; g_hasPrev=true;
               g_lastP=pv; g_lastB=p; g_lastD=1;
               newHighSwing=true;
               chainAdvance=true;
              }
           }
     }

   //================= ZIGZAG POLYLINE ===============================
   // Fires on EXTENSIONS (newLow/HighSwing) as well as flips, which is what
   // keeps the polyline continuous: the newest leg is re-pointed in place
   // rather than left behind at a superseded extreme.
   //
   // Ordering note: commit-then-update is safe because at most ONE
   // chainAdvance can occur per bar. On a bar that is both a pivot high and a
   // pivot low, the LOW block runs first and every path through it sets
   // g_lastB = p; the HIGH block's advance guard then tests
   // (p - g_lastB) >= g_backstep, i.e. 0 >= g_backstep, which is always false
   // because OnInit clamps g_backstep = MathMax(1,InpBackstep). If that clamp
   // ever allowed 0, a second advance could fire here and one leg would go
   // uncommitted.
   if(InpShowZZ && g_hasPrev && (chainAdvance || newLowSwing || newHighSwing))
     {
      if(chainAdvance)
         ZZCommitProvisional(time,rates_total);   // the leg just finalised
      ZZUpdateProvisional(time,rates_total);      // re-point the newest leg
     }

   //================= BOS DETECTION =================================
   if(newLowSwing)
      g_bullUsed=false;
   if(newHighSwing)
      g_bearUsed=false;

   bool bullBOS = (g_lastD==-1 && g_hasPrev && !g_bullUsed && b>g_lastB && close[b]>g_prevP);
   bool bearBOS = (g_lastD== 1 && g_hasPrev && !g_bearUsed && b>g_lastB && close[b]<g_prevP);

   //================= SETUP CONSTRUCTION ============================
   if(bullBOS || bearBOS)
     {
      // ---- ADDED: trial gate ---------------------------------------
      // If the trial has expired, the break-of-structure is still
      // detected (so the ZigZag/BOS state machine keeps behaving
      // exactly as before), but no NEW setup / entry zone / TP / SL is
      // built and no alert is fired. Consume the used-flag exactly as
      // the un-gated branch below would, so the state machine can't get
      // stuck re-evaluating the same BOS every bar.
      if(IsExpired())
        {
         if(bullBOS) g_bullUsed=true;
         else        g_bearUsed=true;
        }
      else
        {
      int span = (int)MathMin(MathMax(b-g_lastB+1,1),5000);
      double a0=0.0, a1=0.0;
      int    extB=b;

      if(bullBOS)
        {
         double hv=0.0; int hb=b;
         HighestHigh(high,b,span,hv,hb);
         a0   = hv;        // level 0.0 = breakout Swing High
         a1   = g_lastP;   // level 1.0 = confirmed Swing Low
         extB = hb;
         g_bullUsed=true;
        }
      else
        {
         double lv=0.0; int lb=b;
         LowestLow(low,b,span,lv,lb);
         a0   = lv;        // level 0.0 = breakout Swing Low
         a1   = g_lastP;   // level 1.0 = confirmed Swing High
         extB = lb;
         g_bearUsed=true;
        }

      if(a0!=a1)
        {
         CSetup *s = new CSetup();
         s.id        = ++g_setupId;
         s.dir       = bullBOS ? 1 : -1;
         s.a0        = a0;
         s.a1        = a1;
         s.extBar    = extB;
         s.createBar = b;
         s.leftBar   = (int)MathMin(g_lastB,extB);
         s.enA       = FibPrice(a0,a1,InpEnHi);
         s.enB       = FibPrice(a0,a1,InpEnLo);
         s.enMid     = FibPrice(a0,a1,InpEnMid);
         s.boxTop    = MathMax(s.enA,s.enB);
         s.boxBot    = MathMin(s.enA,s.enB);
         s.tp1       = FibPrice(a0,a1,InpTP1);
         s.tp2       = FibPrice(a0,a1,InpTP2);
         s.tp3       = FibPrice(a0,a1,InpTP3);
         double slDist = InpSLPoints*g_point;
         s.sl        = (s.dir==1 ? s.boxBot-slDist : s.boxTop+slDist);

         // freeze / retire the previous setup
         int n=ArraySize(g_setups);
         if(n>0 && CheckPointer(g_setups[n-1])!=POINTER_INVALID)
            g_setups[n-1].active=false;

         if(!InpShowHistory)
            ClearAllSetups();
         else
            while(ArraySize(g_setups)>=g_maxHist)
               RemoveSetupAt(0);

         BuildSetup(s,time,rates_total);
         PushSetup(s);
         NotifySetup(s);
        }
        } // end IsExpired() else branch
     }

   //================= LIVE STATE TRACKING ON THIS BAR ===============
   TrackState(high[b],low[b]);
  }

//+------------------------------------------------------------------+
//| =============== BAR-CLOSE COUNTDOWN (ADDED) =================== |
//| How long the forming candle still has to run.  Display only -    |
//| no signal, alert or ZigZag logic reads any of this.              |
//+------------------------------------------------------------------+

// Seconds until the current bar closes, -1 if it cannot be worked out.
// TimeTradeServer() runs off the local clock, so the countdown keeps moving
// through a dead session or a weekend; TimeCurrent() only moves on ticks.
int BarSecondsLeft(void)
  {
   int      per = PeriodSeconds(PERIOD_CURRENT);
   datetime t0  = iTime(_Symbol,PERIOD_CURRENT,0);
   if(per<=0 || t0==0)
      return(-1);

   datetime now = TimeTradeServer();
   if(now==0) now = TimeCurrent();
   if(now==0) return(-1);

   long left = (long)t0 + (long)per - (long)now;
   if(left<0)          left = 0;
   if(left>(long)per)  left = per;
   return((int)left);
  }

string CdClock(const int s)
  {
   if(s<0)
      return("--:--");
   int h = s/3600, m = (s%3600)/60, sec = s%60;
   if(h>0)
      return(StringFormat("%d:%02d:%02d",h,m,sec));
   return(StringFormat("%02d:%02d",m,sec));
  }

//+------------------------------------------------------------------+
//| =============== INFORMATION PANEL (ADDED) ====================== |
//+------------------------------------------------------------------+
#define PNL_PFX      "FBS_PNL_"
#define PNL_MAXROWS  32
#define PNL_LINEH    15
#define PNL_PADTOP   22   // room for the title row
#define PNL_PADBOT   8

int ENUM_CORNER_OF(void)
  {
   switch(InpPanelPos)
     {
      case PC_TOPRIGHT: return (int)CORNER_RIGHT_UPPER;
      case PC_BOTLEFT:  return (int)CORNER_LEFT_LOWER;
      case PC_BOTRIGHT: return (int)CORNER_RIGHT_LOWER;
      default:          return (int)CORNER_LEFT_UPPER;
     }
  }

bool PanelIsTop(void)   { return (InpPanelPos==PC_TOPLEFT || InpPanelPos==PC_TOPRIGHT); }

void PnlLabel(const string nm,const ENUM_OBJECT otype)
  {
   if(ObjectFind(0,nm)>=0)
      return;
   ObjectCreate(0,nm,otype,0,0,0);
   ObjectSetInteger(0,nm,OBJPROP_CORNER,ENUM_CORNER_OF());
   ObjectSetInteger(0,nm,OBJPROP_BACK,false);
   ObjectSetInteger(0,nm,OBJPROP_SELECTABLE,false);
   ObjectSetInteger(0,nm,OBJPROP_SELECTED,false);
   ObjectSetInteger(0,nm,OBJPROP_HIDDEN,true);
   ObjectSetInteger(0,nm,OBJPROP_ZORDER,1000);
  }

// Create every panel object ONCE. Text/position/visibility are updated
// in-place afterwards (see UpdatePanel) - nothing is recreated per tick.
void CreatePanel(void)
  {
   if(!InpShowPanel)
      return;

   PnlLabel(PNL_PFX+"bg",OBJ_RECTANGLE_LABEL);
   ObjectSetInteger(0,PNL_PFX+"bg",OBJPROP_BGCOLOR,Blend(InpPanelBg,InpPanelTransp));
   ObjectSetInteger(0,PNL_PFX+"bg",OBJPROP_COLOR,InpPanelBorder);
   ObjectSetInteger(0,PNL_PFX+"bg",OBJPROP_BORDER_TYPE,BORDER_FLAT);
   ObjectSetInteger(0,PNL_PFX+"bg",OBJPROP_STYLE,STYLE_SOLID);
   ObjectSetInteger(0,PNL_PFX+"bg",OBJPROP_WIDTH,1);

   PnlLabel(PNL_PFX+"title",OBJ_LABEL);
   ObjectSetString (0,PNL_PFX+"title",OBJPROP_FONT,"Arial Bold");
   ObjectSetInteger(0,PNL_PFX+"title",OBJPROP_FONTSIZE,10);
   ObjectSetString (0,PNL_PFX+"title",OBJPROP_TEXT,"FIB BOS SETUP");
   ObjectSetInteger(0,PNL_PFX+"title",OBJPROP_COLOR,InpPanelTitleC);

   for(int i=0; i<PNL_MAXROWS; i++)
     {
      string nm = PNL_PFX+"row"+IntegerToString(i);
      PnlLabel(nm,OBJ_LABEL);
      ObjectSetString (0,nm,OBJPROP_FONT,"Arial");
      ObjectSetInteger(0,nm,OBJPROP_FONTSIZE,8);
      ObjectSetString (0,nm,OBJPROP_TEXT,"");
     }

   // Prominent full-width banner shown only while the trial is expired.
   PnlLabel(PNL_PFX+"banner",OBJ_LABEL);
   ObjectSetInteger(0,PNL_PFX+"banner",OBJPROP_CORNER,(long)CORNER_LEFT_UPPER);
   ObjectSetString (0,PNL_PFX+"banner",OBJPROP_FONT,"Arial Bold");
   ObjectSetInteger(0,PNL_PFX+"banner",OBJPROP_FONTSIZE,14);
   ObjectSetInteger(0,PNL_PFX+"banner",OBJPROP_ANCHOR,ANCHOR_CENTER);
   ObjectSetInteger(0,PNL_PFX+"banner",OBJPROP_COLOR,InpPanelExpC);
   ObjectSetString (0,PNL_PFX+"banner",OBJPROP_TEXT,"");
  }

// Adds one row to the local buffers used by UpdatePanel().
void PnlAddRow(string &txt[],color &col[],int &n,const string t,const color c)
  {
   if(n>=PNL_MAXROWS)
      return;
   txt[n]=t;
   col[n]=c;
   n++;
  }

void UpdatePanel(void)
  {
   if(!InpShowPanel)
     {
      // panel toggled off - make sure any previously drawn panel is hidden
      if(ObjectFind(0,PNL_PFX+"bg")>=0)
         ObjectSetInteger(0,PNL_PFX+"bg",OBJPROP_TIMEFRAMES,OBJ_NO_PERIODS);
      return;
     }
   ObjectSetInteger(0,PNL_PFX+"bg",OBJPROP_TIMEFRAMES,OBJ_ALL_PERIODS);

   bool expired = IsExpired();
   bool warn    = IsInWarningWindow();

   //--- build the row text/colour lists ------------------------------
   string txt[]; color col[];
   ArrayResize(txt,PNL_MAXROWS);
   ArrayResize(col,PNL_MAXROWS);
   int n=0;

   if(InpPnlSymbol || InpPnlTF || InpPnlCountdown)
     {
      PnlAddRow(txt,col,n,"MARKET",InpPanelHeadC);
      if(InpPnlSymbol) PnlAddRow(txt,col,n,"Symbol   "+_Symbol,InpPanelTxtC);
      if(InpPnlTF)      PnlAddRow(txt,col,n,"TF       "+TfString(),InpPanelTxtC);
      if(InpPnlCountdown)
        {
         int cdLeft = BarSecondsLeft();
         PnlAddRow(txt,col,n,"Close in "+CdClock(cdLeft),
                   (cdLeft>=0 && cdLeft<=InpPnlCdWarnSecs) ? InpPanelWarnC : InpPanelTxtC);
        }
     }
   if(InpPnlPrice || InpPnlSpread)
     {
      double bid = SymbolInfoDouble(_Symbol,SYMBOL_BID);
      long   spr = SymbolInfoInteger(_Symbol,SYMBOL_SPREAD);
      if(InpPnlPrice)  PnlAddRow(txt,col,n,"Price    "+FmtPx(bid),InpPanelTxtC);
      if(InpPnlSpread) PnlAddRow(txt,col,n,"Spread   "+IntegerToString((int)spr)+" pts",InpPanelTxtC);
     }
   if(InpPnlZZ)
     {
      PnlAddRow(txt,col,n,"ZIGZAG",InpPanelHeadC);
      PnlAddRow(txt,col,n,"Depth    "+IntegerToString(g_depth),InpPanelTxtC);
      PnlAddRow(txt,col,n,"Deviation "+IntegerToString(g_deviation),InpPanelTxtC);
      PnlAddRow(txt,col,n,"Backstep "+IntegerToString(g_backstep),InpPanelTxtC);
     }

   if(InpPnlStruct || InpPnlBOS || InpPnlEntry || InpPnlTP || InpPnlSL)
     {
      PnlAddRow(txt,col,n,"SIGNAL",InpPanelHeadC);

      int cnt=ArraySize(g_setups);
      CSetup *s = (cnt>0) ? g_setups[cnt-1] : NULL;
      bool have = (s!=NULL && CheckPointer(s)!=POINTER_INVALID);

      if(InpPnlStruct)
        {
         string stxt = have ? (s.dir==1 ? "BULLISH" : "BEARISH") : "-";
         color  scol = have ? (s.dir==1 ? InpPanelBullC : InpPanelBearC) : InpPanelDimC;
         PnlAddRow(txt,col,n,"Structure "+stxt,scol);
        }
      if(InpPnlBOS)
         PnlAddRow(txt,col,n,"BOS      "+(have?"CONFIRMED":"-"),have?InpPanelTxtC:InpPanelDimC);
      if(InpPnlEntry)
         PnlAddRow(txt,col,n,"Entry    "+(have?(FmtPx(s.boxBot)+" - "+FmtPx(s.boxTop)):"-"),have?InpPanelTxtC:InpPanelDimC);
      if(InpPnlTP)
        {
         PnlAddRow(txt,col,n,"TP1      "+(have?FmtPx(s.tp1):"-"),have?InpPanelTxtC:InpPanelDimC);
         PnlAddRow(txt,col,n,"TP2      "+(have?FmtPx(s.tp2):"-"),have?InpPanelTxtC:InpPanelDimC);
         PnlAddRow(txt,col,n,"TP3      "+(have?FmtPx(s.tp3):"-"),have?InpPanelTxtC:InpPanelDimC);
        }
      if(InpPnlSL)
         PnlAddRow(txt,col,n,"SL       "+(have?FmtPx(s.sl):"-"),have?InpPanelTxtC:InpPanelDimC);
     }

   if(InpPnlAlerts)
     {
      bool anyAlerts = (InpAlertBullSetup||InpAlertBearSetup||InpAlertBullZone||InpAlertBearZone||
                         InpAlertTP1||InpAlertTP2||InpAlertTP3||InpAlertSL);
      PnlAddRow(txt,col,n,"Alerts   "+(expired?"OFF (expired)":(anyAlerts?"ON":"OFF")),
                expired?InpPanelExpC:InpPanelTxtC);
     }

   if(InpPnlStatus || InpPnlExpiry)
     {
      PnlAddRow(txt,col,n,"LICENSE",InpPanelHeadC);
      if(InpPnlStatus)
        {
         string stat = !InpEnableExpiry ? "ACTIVE" : (expired ? "TRIAL EXPIRED" : (warn ? "TRIAL" : "TRIAL"));
         color  scol = !InpEnableExpiry ? InpPanelBullC : (expired ? InpPanelExpC : (warn ? InpPanelWarnC : InpPanelTxtC));
         PnlAddRow(txt,col,n,"Status   "+stat,scol);
        }
      if(InpPnlExpiry && InpEnableExpiry)
        {
         if(expired)
            PnlAddRow(txt,col,n,"Expired  "+ExpiryDateString(),InpPanelExpC);
         else
            if(warn)
               PnlAddRow(txt,col,n,"Expires in "+IntegerToString(DaysToExpiry())+" day(s)",InpPanelWarnC);
            else
               PnlAddRow(txt,col,n,"Expires  "+ExpiryDateString(),InpPanelTxtC);
        }
     }

   //--- geometry -------------------------------------------------------
   int   W = InpPanelWidth;
   int   H = (InpPanelHeight>0) ? InpPanelHeight : (PNL_PADTOP + n*PNL_LINEH + PNL_PADBOT);
   bool  top = PanelIsTop();

   ObjectSetInteger(0,PNL_PFX+"bg",OBJPROP_XDISTANCE,InpPanelX);
   ObjectSetInteger(0,PNL_PFX+"bg",OBJPROP_YDISTANCE,InpPanelY);
   ObjectSetInteger(0,PNL_PFX+"bg",OBJPROP_XSIZE,W);
   ObjectSetInteger(0,PNL_PFX+"bg",OBJPROP_YSIZE,H);

   ObjectSetInteger(0,PNL_PFX+"title",OBJPROP_XDISTANCE,InpPanelX+8);
   ObjectSetInteger(0,PNL_PFX+"title",OBJPROP_YDISTANCE, top ? InpPanelY+6 : InpPanelY+H-PNL_LINEH-4);
   ObjectSetInteger(0,PNL_PFX+"title",OBJPROP_TIMEFRAMES,OBJ_ALL_PERIODS);

   for(int i=0; i<PNL_MAXROWS; i++)
     {
      string nm = PNL_PFX+"row"+IntegerToString(i);
      if(i<n)
        {
         int y = top ? (InpPanelY + PNL_PADTOP + i*PNL_LINEH)
                     : (InpPanelY + H - PNL_PADTOP - (i+1)*PNL_LINEH + 4);
         ObjectSetInteger(0,nm,OBJPROP_XDISTANCE,InpPanelX+8);
         ObjectSetInteger(0,nm,OBJPROP_YDISTANCE,y);
         ObjectSetString (0,nm,OBJPROP_TEXT,txt[i]);
         ObjectSetInteger(0,nm,OBJPROP_COLOR,col[i]);
         ObjectSetInteger(0,nm,OBJPROP_TIMEFRAMES,OBJ_ALL_PERIODS);
        }
      else
        {
         ObjectSetString(0,nm,OBJPROP_TEXT,"");
         ObjectSetInteger(0,nm,OBJPROP_TIMEFRAMES,OBJ_NO_PERIODS);
        }
     }

   //--- expired banner ---------------------------------------------
   if(InpEnableExpiry && expired)
     {
      long chartW = ChartGetInteger(0,CHART_WIDTH_IN_PIXELS);
      ObjectSetInteger(0,PNL_PFX+"banner",OBJPROP_XDISTANCE,(int)(chartW/2));
      ObjectSetInteger(0,PNL_PFX+"banner",OBJPROP_YDISTANCE,30);
      ObjectSetString (0,PNL_PFX+"banner",OBJPROP_TEXT,"!!! TRIAL EXPIRED !!!");
      ObjectSetInteger(0,PNL_PFX+"banner",OBJPROP_TIMEFRAMES,OBJ_ALL_PERIODS);
     }
   else
     {
      ObjectSetString(0,PNL_PFX+"banner",OBJPROP_TEXT,"");
      ObjectSetInteger(0,PNL_PFX+"banner",OBJPROP_TIMEFRAMES,OBJ_NO_PERIODS);
     }
  }

//+------------------------------------------------------------------+
//| OnInit                                                           |
//+------------------------------------------------------------------+
int OnInit(void)
  {
   IndicatorSetString(INDICATOR_SHORTNAME,"523 - MDC | Fibonacci BOS Setup (ZigZag)");

   g_depth     = (int)MathMax(1,InpDepth);
   g_deviation = (int)MathMax(0,InpDeviation);
   g_backstep  = (int)MathMax(1,InpBackstep);
   g_maxHist   = (int)MathMax(1,MathMin(20,InpMaxHistory));
   g_prec      = (int)MathMax(0,MathMin(8,InpPricePrec));
   g_rightExt  = (int)MathMax(0,MathMin(200,InpRightExt));

   if(InpPtMode==PT_CUSTOM)
      g_point = MathMax(0.00001,InpPtCustom);
   else
     {
      g_point = SymbolInfoDouble(_Symbol,SYMBOL_TRADE_TICK_SIZE);
      if(g_point<=0.0)
         g_point = _Point;
      if(g_point<=0.0)
         g_point = 0.01;
     }

   ArrayResize(g_setups,0);
   ArrayResize(g_zzNames,0);
   g_warnAlerted = false;
   ResetAll();               // also creates the panel objects
   UpdatePanel();

   //--- the panel otherwise only refreshes on ticks, and the countdown has to
   //--- keep moving in a quiet session or at the weekend
   EventSetTimer(1);
   return(INIT_SUCCEEDED);
  }

//+------------------------------------------------------------------+
//| OnDeinit                                                         |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
   EventKillTimer();
   ClearAllSetups();
   ClearZigZag();
   ObjectsDeleteAll(0,PFX);   // PNL_PFX ("FBS_PNL_") also starts with PFX, so
                               // this cleans up the panel/banner too, and
                               // never touches objects from other indicators.
   ChartRedraw();
  }

//+------------------------------------------------------------------+
//| OnTimer - once a second, refresh the panel only.  UpdatePanel()  |
//| just rewrites the text of labels that already exist, so this is  |
//| cheap and touches no ZigZag, setup or alert logic.               |
//+------------------------------------------------------------------+
void OnTimer(void)
  {
   UpdatePanel();
   ChartRedraw();
  }

//+------------------------------------------------------------------+
//| OnCalculate                                                      |
//+------------------------------------------------------------------+
int OnCalculate(const int rates_total,
                const int prev_calculated,
                const datetime &time[],
                const double &open[],
                const double &high[],
                const double &low[],
                const double &close[],
                const long &tick_volume[],
                const long &volume[],
                const int &spread[])
  {
   ArraySetAsSeries(time,false);
   ArraySetAsSeries(open,false);
   ArraySetAsSeries(high,false);
   ArraySetAsSeries(low,false);
   ArraySetAsSeries(close,false);

   int minBars = 2*g_depth + 2;
   if(rates_total < minBars)
      return(0);

   //--- full recalculation (first run, history refresh, symbol/TF change)
   if(prev_calculated==0)
     {
      ResetAll();
      g_alertsOn=false;
     }

   int lastClosed = rates_total-2;   // last fully closed bar

   //--- process every newly closed bar exactly once ------------------
   for(int b=g_processed; b<=lastClosed; b++)
      ProcessBar(b,rates_total,time,high,low,close);

   if(lastClosed>=g_processed)
      g_processed = lastClosed+1;

   //--- history pass finished -> alerts become live ------------------
   if(!g_alertsOn && prev_calculated>0)
      g_alertsOn=true;

   //--- live bar: state tracking + object extension only -------------
   int cur = rates_total-1;
   if(cur>=0)
     {
      TrackState(high[cur],low[cur]);
      ExtendActive(time,rates_total);
      ZZUpdateLiveLeg(time,rates_total,high,low);
     }

   //--- trial / panel bookkeeping (ADDED) -----------------------------
   CheckExpiryWarningAlert();
   UpdatePanel();

   ChartRedraw();
   return(rates_total);
  }
//+------------------------------------------------------------------+