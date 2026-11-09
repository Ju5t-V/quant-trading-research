//+------------------------------------------------------------------+
//| AOI_MeanReversionEA.mq5                                v1.01     |
//| Daily-zone mean reversion ("improved fxalexg", Revelio ablation) |
//| Default config = the ablation's best cell: filters OFF, Asia     |
//| session, 25p SL floor. NOTE: Python study verdict = NO tradeable |
//| edge net of costs; this EA exists for MT5 cross-verification.    |
//|                                                                  |
//| Rules (SPEC.md):                                                 |
//|  - Zones on D1: fractal(k=2) swing CLOSES clustered <=60 pips,   |
//|    active after 3rd touch (confirm-bar CLOSE), expire 730d after |
//|    last touch, min band width 5 pips                             |
//|  - Entry: first chart-TF candle CLOSING inside an active zone,   |
//|    approached from outside; buy at support, sell at resistance;  |
//|    one trade per zone visit; one open position per symbol        |
//|  - SL: 5 pips beyond band, with minimum SL distance floor        |
//|  - TP: nearest confirmed D1 swing (730d lookback) beyond entry;  |
//|    skip if RR < 2, cap at RR 4                                   |
//|  - Session filter on signal-close hour (server time)             |
//|  - Risk: % of high-watermark balance, OrderCalcProfit sizing     |
//+------------------------------------------------------------------+
#property copyright "Jerry / Claude"
#property version   "1.01"
#property strict

#include <Trade/Trade.mqh>

input double   InpZoneMaxPips     = 60.0;   // zone max span (pips)
input double   InpZoneMinPips     = 5.0;    // zone min width (pips)
input int      InpTouchesActive   = 3;      // touches to activate zone
input int      InpExpiryDays      = 730;    // zone expiry after last touch (days)
input double   InpSLBeyondPips    = 5.0;    // SL beyond band (pips)
input double   InpSLFloorPips     = 25.0;   // minimum SL distance (pips, 0=off)
input double   InpMinRR           = 2.0;    // skip trade below this RR
input double   InpMaxRR           = 4.0;    // cap TP at this RR
input int      InpTPLookbackDays  = 730;    // D1 swing lookback for TP
enum ESession { SES_ASIA=0, SES_LONDON=1, SES_NEWYORK=2, SES_OVERLAP=3, SES_ALL=4 };
input ESession InpSession         = SES_ASIA; // trading session (server hours)
input double   InpRiskPct         = 0.5;    // risk % of high-watermark balance
input double   InpMaxMarginPct    = 40.0;   // max free-margin % per order
input long     InpMagic           = 20260718;
input bool     InpVerbose         = false;

CTrade trade;

#define MAX_ZONES   600
#define MAX_MEMBERS 96
struct SZone
  {
   int      n;                      // member count (0 = free slot)
   double   levels[MAX_MEMBERS];
   datetime last_touch;             // swing-bar time of last member
   datetime activated;              // confirm-bar CLOSE time of 3rd member (0 = inactive)
   int      state;                  // +1 out-above / -1 out-below / 0 inside / -9 unknown
   int      vdir;                   // direction of current visit (+1 buy / -1 sell / 0 n/a)
   int      visit;                  // visit counter
   int      consumed;               // visit number already traded (-1 none)
  };
SZone    g_zones[MAX_ZONES];

#define MAX_SWINGS 4096
double   g_swHiL[MAX_SWINGS]; datetime g_swHiT[MAX_SWINGS]; int g_nHi=0;
double   g_swLoL[MAX_SWINGS]; datetime g_swLoT[MAX_SWINGS]; int g_nLo=0;

datetime g_lastD1  = 0;
datetime g_lastBar = 0;
int      g_lastConfirmed = 1;       // highest non-series D1 swing index ingested
double   g_pip;
double   g_hwm = 0.0;

//+------------------------------------------------------------------+
int OnInit()
  {
   g_pip = (_Digits == 3 || _Digits == 5) ? 10.0 * _Point : _Point;
   trade.SetExpertMagicNumber(InpMagic);
   trade.SetDeviationInPoints(30);
   for(int i=0; i<MAX_ZONES; i++)
     {
      g_zones[i].n=0; g_zones[i].state=-9; g_zones[i].vdir=0;
      g_zones[i].visit=0; g_zones[i].consumed=-1;
      g_zones[i].last_touch=0; g_zones[i].activated=0;
     }
   g_nHi=0; g_nLo=0; g_lastD1=0; g_lastBar=0; g_lastConfirmed=1;
   g_hwm = AccountInfoDouble(ACCOUNT_BALANCE);
   return(INIT_SUCCEEDED);
  }
//+------------------------------------------------------------------+
bool InSession(const datetime tsig)
  {
   MqlDateTime dt; TimeToStruct(tsig, dt);
   int h = dt.hour;
   switch(InpSession)
     {
      case SES_ASIA:    return(h >= 1  && h < 10);
      case SES_LONDON:  return(h >= 10 && h < 19);
      case SES_NEWYORK: return(h >= 15 && h < 24);
      case SES_OVERLAP: return(h >= 15 && h < 19);
      default:          return(true);
     }
  }
//+------------------------------------------------------------------+
//| Cluster a confirmed swing level into the zone book (SPEC A2).    |
//+------------------------------------------------------------------+
void AddZoneLevel(const double lvl, const datetime swing_t, const datetime conf_t)
  {
   int    best  = -1;
   double bestd = 0.0;
   for(int z=0; z<MAX_ZONES; z++)
     {
      if(g_zones[z].n == 0) continue;
      double lo = lvl, hi = lvl, sum = 0.0;
      for(int k=0; k<g_zones[z].n; k++)
        {
         double L = g_zones[z].levels[k];
         if(L < lo) lo = L;
         if(L > hi) hi = L;
         sum += L;
        }
      if(hi - lo <= InpZoneMaxPips * g_pip)
        {
         double d = MathAbs(lvl - sum / g_zones[z].n);
         if(best < 0 || d < bestd) { best = z; bestd = d; }
        }
     }
   if(best >= 0)
     {
      if(g_zones[best].n < MAX_MEMBERS)
         g_zones[best].levels[g_zones[best].n++] = lvl;
      if(swing_t > g_zones[best].last_touch)
         g_zones[best].last_touch = swing_t;
      if(g_zones[best].n >= InpTouchesActive && g_zones[best].activated == 0)
         g_zones[best].activated = conf_t;
      return;
     }
   for(int z=0; z<MAX_ZONES; z++)
      if(g_zones[z].n == 0)
        {
         g_zones[z].n = 1;
         g_zones[z].levels[0] = lvl;
         g_zones[z].last_touch = swing_t;
         g_zones[z].activated = 0;
         g_zones[z].state = -9;
         g_zones[z].vdir = 0;
         g_zones[z].visit = 0;
         g_zones[z].consumed = -1;
         return;
        }
  }
//+------------------------------------------------------------------+
//| Ingest newly CONFIRMED D1 swings (fractal k=2 on closes).        |
//| A swing at non-series index s is confirmed once bar s+2 CLOSED.  |
//+------------------------------------------------------------------+
void UpdateD1(void)
  {
   datetime d1time = iTime(_Symbol, PERIOD_D1, 0);
   if(d1time == 0 || d1time == g_lastD1) return;
   g_lastD1 = d1time;

   int total = Bars(_Symbol, PERIOD_D1);
   if(total < 10) return;
   int nc = total - 2;                        // newest CLOSED bar (non-series)

   MqlRates r[];
   ArraySetAsSeries(r, false);
   int need = (int)MathMin(total, 4000);
   if(CopyRates(_Symbol, PERIOD_D1, 0, need, r) < need) return;
   int off = total - need;                    // non-series index of r[0]

   for(int s = (int)MathMax(g_lastConfirmed + 1, off + 2); s <= nc - 2; s++)
     {
      int i = s - off;
      if(i < 2 || i + 2 >= need) { g_lastConfirmed = s; continue; }
      double c = r[i].close;
      bool isHi = (c > r[i-1].close && c > r[i-2].close && c > r[i+1].close && c > r[i+2].close);
      bool isLo = (c < r[i-1].close && c < r[i-2].close && c < r[i+1].close && c < r[i+2].close);
      g_lastConfirmed = s;
      if(!isHi && !isLo) continue;
      datetime swing_t = r[i].time;
      datetime conf_t  = r[i+2].time + 86400;     // confirm-bar CLOSE (no lookahead)
      if(isHi && g_nHi < MAX_SWINGS) { g_swHiL[g_nHi]=c; g_swHiT[g_nHi]=conf_t; g_nHi++; }
      if(isLo && g_nLo < MAX_SWINGS) { g_swLoL[g_nLo]=c; g_swLoT[g_nLo]=conf_t; g_nLo++; }
      AddZoneLevel(c, swing_t, conf_t);
     }
   datetime cutoff = d1time - (datetime)InpExpiryDays * 86400;
   for(int z=0; z<MAX_ZONES; z++)
      if(g_zones[z].n > 0 && g_zones[z].last_touch < cutoff)
         g_zones[z].n = 0;                       // expire
  }
//+------------------------------------------------------------------+
void ZoneBand(const int z, double &lo, double &hi)
  {
   lo = g_zones[z].levels[0]; hi = lo;
   for(int k=1; k<g_zones[z].n; k++)
     {
      double L = g_zones[z].levels[k];
      if(L < lo) lo = L;
      if(L > hi) hi = L;
     }
   if(hi - lo < InpZoneMinPips * g_pip)
     {
      double m = (hi + lo) / 2.0;
      lo = m - InpZoneMinPips * g_pip / 2.0;
      hi = m + InpZoneMinPips * g_pip / 2.0;
     }
  }
//+------------------------------------------------------------------+
double FindTP(const int dir, const double entry, const datetime tsig)
  {
   datetime lb = tsig - (datetime)InpTPLookbackDays * 86400;
   double best = 0.0;
   if(dir > 0)
     {
      for(int i=0; i<g_nHi; i++)
         if(g_swHiT[i] <= tsig && g_swHiT[i] >= lb && g_swHiL[i] > entry)
            if(best == 0.0 || g_swHiL[i] < best) best = g_swHiL[i];
     }
   else
     {
      for(int i=0; i<g_nLo; i++)
         if(g_swLoT[i] <= tsig && g_swLoT[i] >= lb && g_swLoL[i] < entry)
            if(best == 0.0 || g_swLoL[i] > best) best = g_swLoL[i];
     }
   return(best);
  }
//+------------------------------------------------------------------+
double CalcLots(const int dir, const double entry, const double sl)
  {
   double bal = AccountInfoDouble(ACCOUNT_BALANCE);
   if(bal > g_hwm) g_hwm = bal;
   double risk_money = g_hwm * InpRiskPct / 100.0;

   double loss1 = 0.0;
   ENUM_ORDER_TYPE ot = (dir > 0) ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;
   if(!OrderCalcProfit(ot, _Symbol, 1.0, entry, sl, loss1) || loss1 >= 0)
      return(0.0);
   double lots = risk_money / MathAbs(loss1);

   double margin1 = 0.0;
   if(OrderCalcMargin(ot, _Symbol, 1.0, entry, margin1) && margin1 > 0)
     {
      double maxlots = AccountInfoDouble(ACCOUNT_MARGIN_FREE) * InpMaxMarginPct / 100.0 / margin1;
      if(lots > maxlots) lots = maxlots;
     }
   double step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   double vmin = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double vmax = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   if(step > 0) lots = MathFloor(lots / step) * step;
   if(lots < vmin) return(0.0);
   if(lots > vmax) lots = vmax;
   return(lots);
  }
//+------------------------------------------------------------------+
void OnTick()
  {
   datetime bt = iTime(_Symbol, _Period, 0);
   if(bt == 0 || bt == g_lastBar) return;     // act once per new chart-TF bar
   g_lastBar = bt;

   UpdateD1();

   double c1 = iClose(_Symbol, _Period, 1);   // last CLOSED bar
   if(c1 <= 0) return;
   datetime tsig = bt;                        // == close wall-time of bar 1

   //--- update every zone's state machine; pick nearest-band signal
   int    sigZone = -1, sigDir = 0;
   double sigLo = 0, sigHi = 0, sigDist = 0;
   for(int z=0; z<MAX_ZONES; z++)
     {
      if(g_zones[z].n == 0 || g_zones[z].activated == 0) continue;
      if(g_zones[z].activated > tsig) continue;
      double lo, hi; ZoneBand(z, lo, hi);
      bool inside = (c1 >= lo && c1 <= hi);
      if(!inside)
        {
         g_zones[z].state = (c1 > hi) ? 1 : -1;
         continue;
        }
      int prev = g_zones[z].state;
      if(prev == -9) { g_zones[z].state = 0; continue; }   // no approach info yet
      if(prev != 0)                                        // fresh entry -> new visit
        {
         g_zones[z].visit++;
         g_zones[z].vdir = (prev == 1) ? 1 : -1;           // from above=support=BUY
         g_zones[z].state = 0;
        }
      if(g_zones[z].vdir == 0) continue;
      if(g_zones[z].consumed == g_zones[z].visit) continue; // one trade per visit
      double d = MathAbs(c1 - (lo + hi) / 2.0);
      if(sigZone < 0 || d < sigDist)
        {
         sigZone = z; sigDir = g_zones[z].vdir;
         sigLo = lo; sigHi = hi; sigDist = d;
        }
     }

   if(sigZone < 0) return;
   if(!InSession(tsig)) return;
   if(PositionSelect(_Symbol)) return;        // one open trade per symbol

   double entry = (sigDir > 0) ? SymbolInfoDouble(_Symbol, SYMBOL_ASK)
                               : SymbolInfoDouble(_Symbol, SYMBOL_BID);
   if(entry <= 0) return;
   double sl = (sigDir > 0) ? sigLo - InpSLBeyondPips * g_pip
                            : sigHi + InpSLBeyondPips * g_pip;
   if(InpSLFloorPips > 0)
     {
      if(sigDir > 0) sl = MathMin(sl, entry - InpSLFloorPips * g_pip);
      else           sl = MathMax(sl, entry + InpSLFloorPips * g_pip);
     }
   double risk = (sigDir > 0) ? (entry - sl) : (sl - entry);
   if(risk <= 0) return;

   double tp = FindTP(sigDir, entry, tsig);
   if(tp == 0.0) return;
   double rr = ((sigDir > 0) ? (tp - entry) : (entry - tp)) / risk;
   if(rr < InpMinRR) return;
   if(rr > InpMaxRR)
      tp = entry + InpMaxRR * risk * ((sigDir > 0) ? 1.0 : -1.0);

   double lots = CalcLots(sigDir, entry, sl);
   if(lots <= 0) return;

   sl = NormalizeDouble(sl, _Digits);
   tp = NormalizeDouble(tp, _Digits);
   bool ok = (sigDir > 0) ? trade.Buy(lots, _Symbol, 0.0, sl, tp, "AOI")
                          : trade.Sell(lots, _Symbol, 0.0, sl, tp, "AOI");
   if(ok)
     {
      g_zones[sigZone].consumed = g_zones[sigZone].visit;
      if(InpVerbose)
         PrintFormat("AOI %s %s %.2f lots band[%.5f..%.5f] SL %.5f TP %.5f RR %.2f",
                     (sigDir > 0 ? "BUY" : "SELL"), _Symbol, lots, sigLo, sigHi, sl, tp, rr);
     }
  }
//+------------------------------------------------------------------+
