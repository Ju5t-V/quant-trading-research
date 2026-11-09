//+------------------------------------------------------------------+
//|                                   GoldBreakout_PartialBE.mq5     |
//|  Gold breakout of yesterday's high/low OR the Asia-session range |
//|  with partial profit, breakeven and a final target or trail.     |
//|                                                                  |
//|  Rebuilt from PDH_PDL_Breakout M1 v2.0 (info panel and CSV       |
//|  journal kept). Settings come from NautilusTrader tests on real  |
//|  MetaQuotes-Demo and Dukascopy ticks - see REPORT.md.            |
//|                                                                  |
//|  HOW THE EXITS WORK (hedging account)                            |
//|  A separate sell-limit order would open a NEW short instead of   |
//|  closing a buy, so every breakout opens TWO positions:           |
//|    leg 1: InpPartialPct of the size, take profit at InpTP1_R     |
//|    leg 2: the rest, take profit at InpFinalR (or no target when  |
//|           the second half trails)                                |
//|  Both share the same stop loss (1R). When leg 1 closes at its    |
//|  take profit, leg 2's stop moves to its entry price plus         |
//|  InpBEBufferPts (breakeven); in trail mode it then follows price |
//|  InpRunnerTrailR x R behind. Stops and targets sit on the        |
//|  broker's server, so they still work if MT5 disconnects; only    |
//|  the breakeven and trail moves need MT5 running.                 |
//|                                                                  |
//|  CHANGES vs v2.0                                                 |
//|   - lot size from risk % via OrderCalcProfit (v2.0's tick-value  |
//|     formula made lots 10x too big on MetaQuotes feeds)           |
//|   - never more than 40% of free margin per breakout              |
//|   - restart-safe: a mid-day restart keeps today's orders instead |
//|     of placing them twice                                        |
//|   - broker stop-level checks on every order and stop change      |
//|  v3.10: optional ATR-sized stop, trailing second half, Friday     |
//|   close, sell-only-in-downtrend filter, recovery mode (risk / 10  |
//|   while recent breakouts are net negative)                       |
//|  v3.20: defaults from the study (REPORT.md): no design beat the  |
//|   original exits, so the defaults ARE the original exits at 1%    |
//|   risk, with orders placed 01:15 server (after the 01:00 reopen,  |
//|   whose price spikes cost -155R on 2025-26 raw ticks).            |
//|   Partial profit + breakeven and the ATR stop are still there     |
//|   (InpExitMode / InpAtrScaling), but both lost money on the       |
//|   2021-2025 holdout. Demo only.                                  |
//+------------------------------------------------------------------+
#property copyright   "Jerry"
#property version     "3.20"
#property description "Yesterday's high/low or Asia-range breakout: trail exit (default) or partial profit + breakeven"

#include <Trade\Trade.mqh>

//+------------------------------------------------------------------+
//| Enums                                                            |
//+------------------------------------------------------------------+
enum ENUM_LEVEL_MODE
{
   LEVELS_PREV_DAY = 0,   // Yesterday's high / low
   LEVELS_ASIA     = 1    // Asia session high / low
};

enum ENUM_EXIT_MODE
{
   EXIT_PARTIAL_BE = 0,   // Partial profit + breakeven + second half
   EXIT_TRAIL      = 1    // Fixed SL/TP + trailing stop (v2.0 style)
};

enum ENUM_RUNNER_MODE
{
   RUNNER_TARGET = 0,     // Second half: fixed final target
   RUNNER_TRAIL  = 1      // Second half: trail behind price, no target
};

enum ENUM_SERVER_TZ
{
   TZ_EET_EEST = 0,       // EET/EEST (MetaQuotes-Demo and most brokers)
   TZ_FIXED    = 1,       // Fixed offset from UTC
   TZ_AUTO     = 2        // Live clock TimeCurrent-TimeGMT (not for backtests)
};

//+------------------------------------------------------------------+
//| Input Parameters                                                 |
//+------------------------------------------------------------------+
input group "=== Levels ==="
input ENUM_LEVEL_MODE InpLevelMode = LEVELS_PREV_DAY; // Breakout levels
input int    InpArmHour        = 1;       // Yesterday mode: place orders at server hour
input int    InpArmMinute      = 15;      // Yesterday mode: ... and minute (01:15 = after the reopen)
input int    InpAsiaStartUTC   = 0;       // Asia mode: range starts (UTC hour)
input int    InpAsiaEndUTC     = 8;       // Asia mode: range ends, orders placed (UTC hour)
input int    InpAsiaCancelUTC  = 20;      // Asia mode: unfilled orders cancelled (UTC hour)
input int    InpMinAsiaBars    = 240;     // Asia mode: skip the day if fewer M1 bars in range
input bool   InpTradeBuy       = true;    // Buy stop at the upper level
input bool   InpTradeSell      = true;    // Sell stop at the lower level
input bool   InpSellTrendFilter = false;  // Sell only when yesterday closed below the SMA
input int    InpTrendSmaDays   = 50;      // SMA period for the sell filter (daily bars)
input int    InpMaxSpreadPts   = 80;      // Wait to place orders while spread is above (points)

input group "=== Risk ==="
input bool   InpAutoLot        = true;    // Auto lot size by risk %
input double InpRiskPercent    = 1.0;     // Risk % of balance per breakout (all legs)
input double InpManualLots     = 0.10;    // Total lots per breakout when Auto Lot is off
input double InpStopLossPts    = 1000;    // Stop loss = 1R (points, before ATR scaling)
input bool   InpAtrScaling     = false;   // Scale distances with daily ATR(14)
input double InpAtrRefPts      = 14000;   // ATR (points) at which distances equal the inputs
input bool   InpRecoveryMode   = false;   // Cut risk to 1/10 while recent breakouts are net negative
input int    InpRecentTrades   = 10;      // Breakouts checked by recovery mode

input group "=== Exits ==="
input ENUM_EXIT_MODE InpExitMode = EXIT_TRAIL; // Exit style
input double InpTP1_R          = 1.0;     // Partial: first target (R)
input double InpPartialPct     = 50.0;    // Partial: % of size closed at the first target
input ENUM_RUNNER_MODE InpRunnerMode = RUNNER_TARGET; // Partial: second half
input double InpFinalR         = 2.0;     // Partial: final target for the second half (R)
input double InpRunnerTrailR   = 1.0;     // Partial: trail distance for the second half (R)
input int    InpBEBufferPts    = 10;      // Partial: breakeven stop = entry + this (points)
input double InpTakeProfitPts  = 1000;    // Trail style: take profit (points)
input double InpTrailStartPts  = 100;     // Trail style: start trailing at this profit (points)
input double InpTrailDistPts   = 50;      // Trail style: trailing distance (points)

input group "=== Weekend ==="
input bool   InpFridayClose    = false;   // Close everything on Friday evening
input int    InpFridayHour     = 22;      // Friday close hour (server)
input int    InpFridayMinute   = 30;      // Friday close minute (server)

input group "=== Server clock ==="
input ENUM_SERVER_TZ InpServerTZ = TZ_EET_EEST; // Broker server time zone
input int    InpFixedOffset    = 3;       // Fixed offset from UTC (hours), if selected

input group "=== Info Panel ==="
input bool   InpShowPanel      = true;              // Show info panel
input int    InpPanelX         = 15;                // Panel X (px from left)
input int    InpPanelY         = 30;                // Panel Y (px from top)
input color  InpPanelBg        = C'20,24,36';       // Panel background
input color  InpHeaderColor    = C'100,181,246';    // Header text
input color  InpLabelColor     = C'176,190,197';    // Label text
input color  InpValueColor     = clrWhite;          // Value text
input color  InpProfitColor    = C'102,187,106';    // Profit / bullish
input color  InpLossColor      = C'239,83,80';      // Loss / bearish
input color  InpNeutralColor   = C'255,183,77';     // Pending / neutral

input group "=== Journal / Logging ==="
input bool   InpEnableJournal  = true;                               // Enable CSV trade journal
input string InpJournalFile    = "GoldBreakout_PartialBE_Journal.csv"; // Journal filename
input bool   InpEnableAlerts   = false;                              // Enable MT5 Alerts

input group "=== EA Settings ==="
input long   InpMagicNumber    = 20260916;  // Magic Number

//+------------------------------------------------------------------+
//| Global Variables                                                 |
//+------------------------------------------------------------------+
CTrade   g_trade;
int      g_atrHandle      = INVALID_HANDLE;
int      g_maHandle       = INVALID_HANDLE;

datetime g_periodKey      = 0;     // start of the current arming period (server time)
datetime g_armTime        = 0;     // when today's orders are placed (server time)
datetime g_expiry         = 0;     // when unfilled orders are removed (server time)
bool     g_armed          = false; // today's orders placed (or the day was skipped)
string   g_tag            = "";    // yymmdd, used in order comments
double   g_up             = 0.0;   // today's upper level
double   g_dn             = 0.0;   // today's lower level
double   g_slPts          = 0.0;   // today's 1R (points)
double   g_tpPts          = 0.0;   // trail style: take profit (points)
double   g_trailStartPts  = 0.0;   // trail style: start (points)
double   g_trailDistPts   = 0.0;   // trail style: distance (points)
bool     g_recoveryActive = false;
string   g_status         = "starting";
string   g_sideNote[2]    = {"-", "-"};   // [0] buy, [1] sell

// statistics (positions, not breakouts: a partial breakout closes two legs)
int      g_sessWins = 0, g_sessLosses = 0, g_totalWins = 0, g_totalLosses = 0;
double   g_sessPnl = 0.0, g_totalPnl = 0.0, g_peakBalance = 0.0, g_maxDrawdown = 0.0;
datetime g_sessDay = 0;
ulong    g_lastDealTicket = 0;
bool     g_needDealScan = false;
bool     g_warnedMinLot = false;

string   g_pfx = "GBPBE_";

#define PANEL_W   300
#define ROW_H     18
#define FONT_SIZE 8
#define FONT_FACE "Consolas"

enum EPanelRow
{
   ROW_HEADER = 0, ROW_SEP1, ROW_PRICE, ROW_SPREAD, ROW_CLOCK,
   ROW_SEP2, ROW_MODE, ROW_UP, ROW_DN, ROW_RANGE, ROW_DIST,
   ROW_SEP3, ROW_STATUS, ROW_BUY, ROW_SELL,
   ROW_SEP4, ROW_OPEN, ROW_FLOAT,
   ROW_SEP5, ROW_SESS_WL, ROW_SESS_PNL,
   ROW_SEP6, ROW_TOTAL_WL, ROW_TOTAL_WR, ROW_TOTAL_PNL, ROW_MAX_DD, ROW_BALANCE,
   ROW_SEP7, ROW_RISK, ROW_EXIT, ROW_RUNNER, ROW_FILTERS,
   ROW_LAST
};

//+------------------------------------------------------------------+
//| OnInit                                                           |
//+------------------------------------------------------------------+
int OnInit()
{
   if(InpTP1_R <= 0.0 || InpFinalR <= InpTP1_R || InpPartialPct <= 0.0 || InpPartialPct >= 100.0 ||
      InpRunnerTrailR <= 0.0)
   {
      Print("Invalid exit settings: need 0 < TP1 < final target, 0 < partial % < 100, trail R > 0");
      return(INIT_PARAMETERS_INCORRECT);
   }
   if(InpAsiaEndUTC <= InpAsiaStartUTC || InpAsiaCancelUTC <= InpAsiaEndUTC || InpAsiaCancelUTC > 24)
   {
      Print("Invalid Asia hours: need start < end < cancel <= 24");
      return(INIT_PARAMETERS_INCORRECT);
   }

   g_trade.SetExpertMagicNumber((ulong)InpMagicNumber);
   g_trade.SetTypeFillingBySymbol(_Symbol);
   g_trade.SetDeviationInPoints(30);

   if(InpAtrScaling)
   {
      g_atrHandle = iATR(_Symbol, PERIOD_D1, 14);
      if(g_atrHandle == INVALID_HANDLE)
         Print("iATR handle failed - using fixed distances");
   }
   if(InpSellTrendFilter)
   {
      g_maHandle = iMA(_Symbol, PERIOD_D1, InpTrendSmaDays, 0, MODE_SMA, PRICE_CLOSE);
      if(g_maHandle == INVALID_HANDLE)
         Print("iMA handle failed - sells will be skipped while the filter is on");
   }

   g_peakBalance = AccountInfoDouble(ACCOUNT_BALANCE);
   g_lastDealTicket = LatestDealTicket();
   RefreshDistances();

   if(InpShowPanel)
      PanelCreate();
   if(InpEnableJournal)
      JournalInit();
   EventSetTimer(1);

   JournalWrite("EA_EVENT", "INIT", 0, 0, 0, 0, 0, AccountInfoDouble(ACCOUNT_BALANCE),
                "v3.10 started | Magic=" + IntegerToString(InpMagicNumber) + " | " + _Symbol +
                " | server-UTC offset now " + IntegerToString(ServerOffsetHours(TimeCurrent())) + "h");
   PrintFormat("GoldBreakout_PartialBE v3.10 | %s | levels=%s exit=%s runner=%s | server-UTC offset now %dh",
               _Symbol, EnumToString(InpLevelMode), EnumToString(InpExitMode), EnumToString(InpRunnerMode),
               ServerOffsetHours(TimeCurrent()));
   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   EventKillTimer();
   PanelDelete();
   if(g_atrHandle != INVALID_HANDLE)
      IndicatorRelease(g_atrHandle);
   if(g_maHandle != INVALID_HANDLE)
      IndicatorRelease(g_maHandle);
   JournalWrite("EA_EVENT", "DEINIT", 0, 0, 0, 0, 0, AccountInfoDouble(ACCOUNT_BALANCE),
                "EA stopped | Reason=" + IntegerToString(reason));
}

//+------------------------------------------------------------------+
void OnTimer()
{
   if(InpShowPanel)
      PanelUpdate();
}

//+------------------------------------------------------------------+
void OnTradeTransaction(const MqlTradeTransaction &trans,
                        const MqlTradeRequest &request,
                        const MqlTradeResult &result)
{
   if(trans.type == TRADE_TRANSACTION_DEAL_ADD)
      g_needDealScan = true;
}

//+------------------------------------------------------------------+
//| OnTick                                                           |
//+------------------------------------------------------------------+
void OnTick()
{
   UpdatePeriod();

   if(g_needDealScan)
   {
      g_needDealScan = false;
      ScanClosedDeals();
   }

   if(FridayClosePassed())
   {
      DeletePendings(TimeCurrent() + 1);
      CloseAllPositions("Friday close");
      g_status = "Friday close: flat until Monday";
      return;
   }

   datetime now = TimeCurrent();
   if(!g_armed && now >= g_armTime && now < g_expiry)
      TryArm();

   if(now >= g_expiry)
      DeletePendings(g_expiry);   // for brokers without order expiry times

   if(InpExitMode == EXIT_PARTIAL_BE)
      ManageSecondHalf();
   else
      ManageTrailing();
}

//+------------------------------------------------------------------+
//| Server clock                                                     |
//+------------------------------------------------------------------+
int LastSunday(int year, int month)   // month must have 31 days (March, October)
{
   MqlDateTime t;
   ZeroMemory(t);
   t.year = year;
   t.mon  = month;
   t.day  = 31;
   t.hour = 12;
   MqlDateTime s;
   TimeToStruct(StructToTime(t), s);
   return(31 - s.day_of_week);
}

bool IsEuSummer(datetime serverTime)
{
   MqlDateTime s;
   TimeToStruct(serverTime, s);
   if(s.mon < 3 || s.mon > 10)
      return(false);
   if(s.mon > 3 && s.mon < 10)
      return(true);
   int ls = LastSunday(s.year, s.mon);
   if(s.mon == 3)
      return(s.day > ls || (s.day == ls && s.hour >= 3));
   return(s.day < ls || (s.day == ls && s.hour < 3));
}

int ServerOffsetHours(datetime serverTime)
{
   if(InpServerTZ == TZ_FIXED)
      return(InpFixedOffset);
   if(InpServerTZ == TZ_AUTO && !MQLInfoInteger(MQL_TESTER))
   {
      int d = (int)MathRound((double)(TimeCurrent() - TimeGMT()) / 3600.0);
      if(d >= -12 && d <= 14)
         return(d);
   }
   return(IsEuSummer(serverTime) ? 3 : 2);
}

datetime UtcToServer(datetime utc)
{
   datetime s = utc + 2 * 3600;
   s = utc + ServerOffsetHours(s) * 3600;
   return(utc + ServerOffsetHours(s) * 3600);
}

datetime ServerToUtc(datetime srv)
{
   return(srv - ServerOffsetHours(srv) * 3600);
}

bool FridayClosePassed()
{
   if(!InpFridayClose)
      return(false);
   MqlDateTime s;
   TimeToStruct(TimeCurrent(), s);
   return(s.day_of_week == 5 && s.hour * 60 + s.min >= InpFridayHour * 60 + InpFridayMinute);
}

//+------------------------------------------------------------------+
//| Arming period: one per server day (yesterday mode) or UTC day    |
//+------------------------------------------------------------------+
void UpdatePeriod()
{
   datetime now = TimeCurrent();
   datetime key, arm, exp;
   string   tag;

   if(InpLevelMode == LEVELS_PREV_DAY)
   {
      key = now - (now % 86400);
      arm = key + InpArmHour * 3600 + InpArmMinute * 60;
      exp = key + 86400;
      tag = TimeToString(key, TIME_DATE);
   }
   else
   {
      datetime utc    = ServerToUtc(now);
      datetime utcDay = utc - (utc % 86400);
      key = UtcToServer(utcDay);
      arm = UtcToServer(utcDay + InpAsiaEndUTC * 3600);
      exp = UtcToServer(utcDay + InpAsiaCancelUTC * 3600);
      tag = TimeToString(utcDay, TIME_DATE);
   }

   if(key == g_periodKey)
      return;

   g_periodKey = key;
   g_armTime   = arm;
   g_expiry    = exp;
   StringReplace(tag, ".", "");
   g_tag       = StringSubstr(tag, 2);      // yymmdd
   g_sideNote[0] = "-";
   g_sideNote[1] = "-";

   datetime today = now - (now % 86400);
   if(today != g_sessDay)
   {
      g_sessDay = today;
      g_sessWins = 0;
      g_sessLosses = 0;
      g_sessPnl = 0.0;
   }

   if(ActedSince(key))
   {
      // restarted after today's orders were already placed or traded: leave them alone
      g_armed  = true;
      g_status = "restored after restart";
      RefreshDistances();
      double up, dn;
      if(GetLevels(up, dn) == 1)
      {
         g_up = up;
         g_dn = dn;
      }
      return;
   }

   g_armed  = false;
   g_status = "waiting for " + TimeToString(arm, TIME_DATE | TIME_MINUTES) + " (server)";
   DeletePendings(key);   // anything left from an earlier period
}

//+------------------------------------------------------------------+
//| True if this EA placed an order or opened a position since `from`|
//+------------------------------------------------------------------+
bool ActedSince(datetime from)
{
   for(int i = OrdersTotal() - 1; i >= 0; i--)
   {
      ulong t = OrderGetTicket(i);
      if(t == 0 || OrderGetString(ORDER_SYMBOL) != _Symbol || OrderGetInteger(ORDER_MAGIC) != InpMagicNumber)
         continue;
      if((datetime)OrderGetInteger(ORDER_TIME_SETUP) >= from)
         return(true);
   }
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong t = PositionGetTicket(i);
      if(t == 0 || PositionGetString(POSITION_SYMBOL) != _Symbol || PositionGetInteger(POSITION_MAGIC) != InpMagicNumber)
         continue;
      if((datetime)PositionGetInteger(POSITION_TIME) >= from)
         return(true);
   }
   if(HistorySelect(from, TimeCurrent() + 60))
   {
      for(int i = HistoryDealsTotal() - 1; i >= 0; i--)
      {
         ulong d = HistoryDealGetTicket(i);
         if(d == 0 || HistoryDealGetInteger(d, DEAL_MAGIC) != InpMagicNumber || HistoryDealGetString(d, DEAL_SYMBOL) != _Symbol)
            continue;
         if(HistoryDealGetInteger(d, DEAL_ENTRY) == DEAL_ENTRY_IN)
            return(true);
      }
   }
   return(false);
}

//+------------------------------------------------------------------+
//| Levels: 1 = ok, 0 = skip today, -1 = data not ready, try again   |
//+------------------------------------------------------------------+
int GetLevels(double &up, double &dn)
{
   if(InpLevelMode == LEVELS_PREV_DAY)
   {
      datetime bar0 = iTime(_Symbol, PERIOD_D1, 0);
      if(bar0 == 0 || bar0 < g_periodKey)
         return(-1);                       // today's daily bar not built yet
      up = iHigh(_Symbol, PERIOD_D1, 1);
      dn = iLow(_Symbol, PERIOD_D1, 1);
      return((up > 0.0 && dn > 0.0 && up > dn) ? 1 : -1);
   }

   datetime utcDay = ServerToUtc(g_armTime);
   utcDay -= utcDay % 86400;
   datetime from = UtcToServer(utcDay + InpAsiaStartUTC * 3600);
   datetime to   = UtcToServer(utcDay + InpAsiaEndUTC * 3600) - 60;   // last bar opens at xx:59
   MqlRates r[];
   int n = CopyRates(_Symbol, PERIOD_M1, from, to, r);
   if(n < 0)
      return(-1);
   if(n < InpMinAsiaBars)
   {
      g_status = StringFormat("skipped: only %d M1 bars in the Asia range", n);
      return(0);
   }
   up = r[0].high;
   dn = r[0].low;
   for(int i = 1; i < n; i++)
   {
      if(r[i].high > up) up = r[i].high;
      if(r[i].low  < dn) dn = r[i].low;
   }
   return(up > dn ? 1 : 0);
}

//+------------------------------------------------------------------+
//| Sell filter: yesterday's close below the daily SMA               |
//+------------------------------------------------------------------+
bool SellAllowed()
{
   if(!InpSellTrendFilter)
      return(true);
   double ma[1];
   if(g_maHandle == INVALID_HANDLE || CopyBuffer(g_maHandle, 0, 1, 1, ma) != 1 || ma[0] <= 0.0)
   {
      Print("Sell filter: SMA not available - sell skipped today");
      return(false);
   }
   double prevClose = iClose(_Symbol, PERIOD_D1, 1);
   return(prevClose > 0.0 && prevClose < ma[0]);
}

//+------------------------------------------------------------------+
//| Distances for today (points), optionally scaled by daily ATR     |
//+------------------------------------------------------------------+
void RefreshDistances()
{
   double s = 1.0;
   if(InpAtrScaling && g_atrHandle != INVALID_HANDLE)
   {
      double buf[1];
      if(CopyBuffer(g_atrHandle, 0, 1, 1, buf) == 1 && buf[0] > 0.0)
         s = MathMax(0.1, MathMin(2.0, (buf[0] / _Point) / InpAtrRefPts));
      g_slPts         = MathMax(200.0, InpStopLossPts   * s);
      g_tpPts         = MathMax(400.0, InpTakeProfitPts * s);
      g_trailStartPts = MathMax(150.0, InpTrailStartPts * s);
      g_trailDistPts  = MathMax(80.0,  InpTrailDistPts  * s);
      return;
   }
   g_slPts         = InpStopLossPts;
   g_tpPts         = InpTakeProfitPts;
   g_trailStartPts = InpTrailStartPts;
   g_trailDistPts  = InpTrailDistPts;
}

//+------------------------------------------------------------------+
//| Place today's buy stop(s) and sell stop(s)                       |
//+------------------------------------------------------------------+
void TryArm()
{
   long spread = SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);
   if(spread > InpMaxSpreadPts)
   {
      g_status = "waiting: spread " + IntegerToString(spread) + " pts";
      return;                              // try again next tick
   }

   double up, dn;
   int lv = GetLevels(up, dn);
   if(lv < 0)
      return;
   g_armed = true;
   if(lv == 0)
   {
      JournalWrite("DAY_SKIPPED", "-", 0, 0, 0, 0, 0, AccountInfoDouble(ACCOUNT_BALANCE), g_status);
      return;
   }

   g_up = up;
   g_dn = dn;
   RefreshDistances();
   g_status = "armed " + TimeToString(TimeCurrent(), TIME_MINUTES);

   JournalWrite("LEVELS", InpLevelMode == LEVELS_PREV_DAY ? "PREV_DAY" : "ASIA", up, dn, 0, 0, 0,
                AccountInfoDouble(ACCOUNT_BALANCE),
                "Spread=" + IntegerToString(spread) + "pts | 1R=" + DoubleToString(g_slPts, 0) + "pts");

   if(InpTradeBuy)
      PlaceSide(true);
   if(InpTradeSell)
   {
      if(SellAllowed())
         PlaceSide(false);
      else
         g_sideNote[1] = "skipped: no downtrend (close above SMA)";
   }

   if(InpEnableAlerts)
      Alert(_Symbol, " | orders armed | up ", DoubleToString(up, _Digits), " dn ", DoubleToString(dn, _Digits));
}

void PlaceSide(bool buy)
{
   int    k     = buy ? 0 : 1;
   double level = NormalizeDouble(buy ? g_up : g_dn, _Digits);
   double ask   = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid   = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double minD  = StopsLevelPoints() * _Point;

   if(buy ? (level <= ask + minD) : (level >= bid - minD))
   {
      g_sideNote[k] = "skipped: price already beyond level";
      PrintFormat("%s stop skipped: price already beyond %.2f (bid %.2f ask %.2f)",
                  buy ? "Buy" : "Sell", level, bid, ask);
      return;
   }

   double sgn  = buy ? 1.0 : -1.0;
   double r    = g_slPts * _Point;
   double sl   = NormalizeDouble(level - sgn * r, _Digits);
   double lots = CalcTotalLots(r);
   if(lots <= 0.0)
   {
      g_sideNote[k] = "skipped: lot size";
      return;
   }

   bool     canExpire = ((SymbolInfoInteger(_Symbol, SYMBOL_EXPIRATION_MODE) & SYMBOL_EXPIRATION_SPECIFIED) != 0);
   ENUM_ORDER_TYPE_TIME tt = canExpire ? ORDER_TIME_SPECIFIED : ORDER_TIME_GTC;
   datetime exp = canExpire ? g_expiry : 0;
   // comment carries the day, side and 1R in points so leg 2 can be managed after a restart
   string   tag = g_tag + (buy ? "B" : "S") + "|" + IntegerToString((int)MathRound(g_slPts));

   if(InpExitMode == EXIT_PARTIAL_BE)
   {
      double step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
      double minL = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
      double l1   = MathMax(minL, MathFloor(lots * InpPartialPct / 100.0 / step + 1e-9) * step);
      double l2   = MathMax(minL, MathFloor((lots - l1) / step + 1e-9) * step);
      double tp1  = NormalizeDouble(level + sgn * InpTP1_R  * r, _Digits);
      double tp2  = (InpRunnerMode == RUNNER_TRAIL) ? 0.0 : NormalizeDouble(level + sgn * InpFinalR * r, _Digits);
      bool ok1 = SendStop(buy, NormalizeDouble(l1, 2), level, sl, tp1, tt, exp, "PBE1|" + tag);
      bool ok2 = SendStop(buy, NormalizeDouble(l2, 2), level, sl, tp2, tt, exp, "PBE2|" + tag);
      g_sideNote[k] = (ok1 && ok2) ? "armed 2 legs" : "order FAILED - see Experts log";
   }
   else
   {
      double tp = NormalizeDouble(level + sgn * g_tpPts * _Point, _Digits);
      bool ok = SendStop(buy, lots, level, sl, tp, tt, exp, "TRL|" + tag);
      g_sideNote[k] = ok ? "armed" : "order FAILED - see Experts log";
   }
}

bool SendStop(bool buy, double lots, double price, double sl, double tp,
              ENUM_ORDER_TYPE_TIME tt, datetime exp, string comment)
{
   bool ok = buy ? g_trade.BuyStop(lots, price, _Symbol, sl, tp, tt, exp, comment)
                 : g_trade.SellStop(lots, price, _Symbol, sl, tp, tt, exp, comment);
   if(ok)
      JournalWrite("ORDER_PLACED", buy ? "BUY_STOP" : "SELL_STOP", price, sl, tp, lots, 0,
                   AccountInfoDouble(ACCOUNT_BALANCE), comment + " | Ticket=" + IntegerToString((long)g_trade.ResultOrder()));
   else
      PrintFormat("%s stop %s @%.2f failed: %u %s", buy ? "Buy" : "Sell", comment, price,
                  g_trade.ResultRetcode(), g_trade.ResultRetcodeDescription());
   return(ok);
}

//+------------------------------------------------------------------+
//| Total lots for one breakout (all legs)                           |
//+------------------------------------------------------------------+
double CalcTotalLots(double stopDist)
{
   double lots = InpManualLots;
   double ask  = SymbolInfoDouble(_Symbol, SYMBOL_ASK);

   if(InpAutoLot)
   {
      // money lost per 1.0 lot at the stop, from the broker's own profit model
      double lossPerLot = 0.0;
      if(!OrderCalcProfit(ORDER_TYPE_BUY, _Symbol, 1.0, ask, ask - stopDist, lossPerLot) || lossPerLot >= 0.0)
      {
         Print("Auto lot: OrderCalcProfit failed - no order placed");
         return(0.0);
      }
      double riskPct = InpRiskPercent;
      g_recoveryActive = false;
      if(InpRecoveryMode)
      {
         int legs = (InpExitMode == EXIT_PARTIAL_BE) ? 2 : 1;
         if(RecentClosedTradesPL(InpRecentTrades * legs) < 0.0)
         {
            riskPct /= 10.0;          // losing streak: keep trading at minimal size
            g_recoveryActive = true;
         }
      }
      lots = AccountInfoDouble(ACCOUNT_BALANCE) * riskPct / 100.0 / MathAbs(lossPerLot);
   }

   double marginPerLot = 0.0;
   if(OrderCalcMargin(ORDER_TYPE_BUY, _Symbol, 1.0, ask, marginPerLot) && marginPerLot > 0.0)
   {
      double maxLots = AccountInfoDouble(ACCOUNT_MARGIN_FREE) * 0.4 / marginPerLot;
      if(lots > maxLots)
         lots = maxLots;
   }

   double step   = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   double minLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   lots = MathFloor(lots / step + 1e-9) * step;

   double need = (InpExitMode == EXIT_PARTIAL_BE) ? 2.0 * minLot : minLot;
   if(lots < need)
   {
      if(!g_warnedMinLot)
      {
         PrintFormat("Risk is below the minimum size - using %.2f lots (more risk than set)", need);
         g_warnedMinLot = true;
      }
      lots = need;
   }
   return(NormalizeDouble(MathMin(maxLot, lots), 2));
}

//+------------------------------------------------------------------+
//| Sum of the last `deals` closing deals of this EA (money)         |
//+------------------------------------------------------------------+
double RecentClosedTradesPL(int deals)
{
   if(!HistorySelect(0, TimeCurrent() + 60))
      return(0.0);
   double sum = 0.0;
   int    counted = 0;
   for(int i = HistoryDealsTotal() - 1; i >= 0 && counted < deals; i--)
   {
      ulong t = HistoryDealGetTicket(i);
      if(t == 0 || HistoryDealGetInteger(t, DEAL_MAGIC) != InpMagicNumber || HistoryDealGetString(t, DEAL_SYMBOL) != _Symbol)
         continue;
      if(HistoryDealGetInteger(t, DEAL_ENTRY) != DEAL_ENTRY_OUT)
         continue;
      sum += HistoryDealGetDouble(t, DEAL_PROFIT) + HistoryDealGetDouble(t, DEAL_SWAP)
           + HistoryDealGetDouble(t, DEAL_COMMISSION);
      counted++;
   }
   return(sum);
}

//+------------------------------------------------------------------+
//| Partial style: leg 2 to breakeven once leg 1 took profit, then   |
//| (trail mode) follow price InpRunnerTrailR x R behind             |
//+------------------------------------------------------------------+
void ManageSecondHalf()
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong tk = PositionGetTicket(i);
      if(tk == 0 || PositionGetString(POSITION_SYMBOL) != _Symbol || PositionGetInteger(POSITION_MAGIC) != InpMagicNumber)
         continue;
      string c = PositionGetString(POSITION_COMMENT);
      if(StringFind(c, "PBE2|") != 0)
         continue;

      string tag  = StringSubstr(c, 5);
      int    bar  = StringFind(tag, "|");
      double rPts = (bar > 0) ? StringToDouble(StringSubstr(tag, bar + 1)) : g_slPts;
      if(rPts <= 0.0)
         rPts = g_slPts;

      long   type = PositionGetInteger(POSITION_TYPE);
      double open = PositionGetDouble(POSITION_PRICE_OPEN);
      double sl   = PositionGetDouble(POSITION_SL);
      double tp   = PositionGetDouble(POSITION_TP);
      double sgn  = (type == POSITION_TYPE_BUY) ? 1.0 : -1.0;
      double be   = NormalizeDouble(open + sgn * InpBEBufferPts * _Point, _Digits);
      bool   atBE = sl > 0.0 && ((sgn > 0 && sl >= be - _Point / 2.0) || (sgn < 0 && sl <= be + _Point / 2.0));

      if(!atBE && Leg1Status(tag) != 1)
         continue;                                      // leg 1 still open, or stopped out
      if(atBE && InpRunnerMode != RUNNER_TRAIL)
         continue;                                      // fixed target: nothing more to do

      double bid  = SymbolInfoDouble(_Symbol, SYMBOL_BID);
      double ask  = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      double minD = StopsLevelPoints() * _Point;
      double want = be;
      if(InpRunnerMode == RUNNER_TRAIL)
      {
         double trail = (sgn > 0) ? bid - InpRunnerTrailR * rPts * _Point : ask + InpRunnerTrailR * rPts * _Point;
         want = (sgn > 0) ? MathMax(be, trail) : MathMin(be, trail);
      }
      want = NormalizeDouble(want, _Digits);

      if(atBE)
      {
         double step = MathMax(10.0 * _Point, 0.05 * rPts * _Point);
         if(sgn > 0 ? want <= sl + step : want >= sl - step)
            continue;                                   // trail has not moved enough yet
      }

      bool valid = (sgn > 0) ? (want <= bid - minD) : (want >= ask + minD);
      if(valid)
      {
         if(g_trade.PositionModify(tk, want, tp) && !atBE)
            JournalWrite("BREAKEVEN", sgn > 0 ? "BUY" : "SELL", open, want, tp, PositionGetDouble(POSITION_VOLUME), 0,
                         AccountInfoDouble(ACCOUNT_BALANCE), "Leg 2 stop moved to breakeven | " + c);
      }
      else if(!atBE)
      {
         // price already went back through breakeven: close the rest now
         if(g_trade.PositionClose(tk))
            JournalWrite("BREAKEVEN_CLOSE", sgn > 0 ? "BUY" : "SELL", open, be, tp, 0, 0,
                         AccountInfoDouble(ACCOUNT_BALANCE), "Price past breakeven, leg 2 closed | " + c);
      }
   }
}

//+------------------------------------------------------------------+
//| Leg 1 of a breakout: 0 = open/unknown, 1 = closed at TP, 2 = other|
//+------------------------------------------------------------------+
int Leg1Status(string tag)
{
   string want = "PBE1|" + tag;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong t = PositionGetTicket(i);
      if(t != 0 && PositionGetInteger(POSITION_MAGIC) == InpMagicNumber && PositionGetString(POSITION_COMMENT) == want)
         return(0);
   }
   if(!HistorySelect(TimeCurrent() - 14 * 86400, TimeCurrent() + 60))
      return(0);
   long posId = -1;
   int  total = HistoryDealsTotal();
   for(int i = total - 1; i >= 0; i--)
   {
      ulong d = HistoryDealGetTicket(i);
      if(d == 0 || HistoryDealGetInteger(d, DEAL_MAGIC) != InpMagicNumber)
         continue;
      if(HistoryDealGetInteger(d, DEAL_ENTRY) == DEAL_ENTRY_IN && HistoryDealGetString(d, DEAL_COMMENT) == want)
      {
         posId = HistoryDealGetInteger(d, DEAL_POSITION_ID);
         break;
      }
   }
   if(posId < 0)
      return(0);
   for(int i = total - 1; i >= 0; i--)
   {
      ulong d = HistoryDealGetTicket(i);
      if(d == 0 || HistoryDealGetInteger(d, DEAL_POSITION_ID) != posId)
         continue;
      if(HistoryDealGetInteger(d, DEAL_ENTRY) == DEAL_ENTRY_OUT)
         return(HistoryDealGetInteger(d, DEAL_REASON) == DEAL_REASON_TP ? 1 : 2);
   }
   return(0);
}

//+------------------------------------------------------------------+
//| Trail style: v2.0 trailing stop with broker stop-level checks    |
//+------------------------------------------------------------------+
void ManageTrailing()
{
   double minD = StopsLevelPoints() * _Point;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong tk = PositionGetTicket(i);
      if(tk == 0 || PositionGetString(POSITION_SYMBOL) != _Symbol || PositionGetInteger(POSITION_MAGIC) != InpMagicNumber)
         continue;
      double open  = PositionGetDouble(POSITION_PRICE_OPEN);
      double curSL = PositionGetDouble(POSITION_SL);
      double tp    = PositionGetDouble(POSITION_TP);
      double bid   = SymbolInfoDouble(_Symbol, SYMBOL_BID);
      double ask   = SymbolInfoDouble(_Symbol, SYMBOL_ASK);

      if(PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY)
      {
         if(bid - open < g_trailStartPts * _Point)
            continue;
         double newSL = NormalizeDouble(MathMin(bid - g_trailDistPts * _Point, bid - minD), _Digits);
         if(curSL == 0.0 || newSL > curSL + _Point / 2.0)
            g_trade.PositionModify(tk, newSL, tp);
      }
      else
      {
         if(open - ask < g_trailStartPts * _Point)
            continue;
         double newSL = NormalizeDouble(MathMax(ask + g_trailDistPts * _Point, ask + minD), _Digits);
         if(curSL == 0.0 || newSL < curSL - _Point / 2.0)
            g_trade.PositionModify(tk, newSL, tp);
      }
   }
}

//+------------------------------------------------------------------+
//| Remove this EA's pending stops that were set up before `before`  |
//+------------------------------------------------------------------+
void DeletePendings(datetime before)
{
   for(int i = OrdersTotal() - 1; i >= 0; i--)
   {
      ulong t = OrderGetTicket(i);
      if(t == 0 || OrderGetString(ORDER_SYMBOL) != _Symbol || OrderGetInteger(ORDER_MAGIC) != InpMagicNumber)
         continue;
      long type = OrderGetInteger(ORDER_TYPE);
      if(type != ORDER_TYPE_BUY_STOP && type != ORDER_TYPE_SELL_STOP)
         continue;
      if((datetime)OrderGetInteger(ORDER_TIME_SETUP) >= before)
         continue;
      if(g_trade.OrderDelete(t))
         JournalWrite("ORDER_CANCELLED", type == ORDER_TYPE_BUY_STOP ? "BUY_STOP" : "SELL_STOP", 0, 0, 0, 0, 0,
                      AccountInfoDouble(ACCOUNT_BALANCE), "Removed unfilled | Ticket=" + IntegerToString((long)t));
   }
}

void CloseAllPositions(string why)
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong t = PositionGetTicket(i);
      if(t == 0 || PositionGetString(POSITION_SYMBOL) != _Symbol || PositionGetInteger(POSITION_MAGIC) != InpMagicNumber)
         continue;
      if(g_trade.PositionClose(t))
         JournalWrite("POSITION_CLOSED", PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY ? "BUY" : "SELL",
                      0, 0, 0, 0, 0, AccountInfoDouble(ACCOUNT_BALANCE), why + " | Ticket=" + IntegerToString((long)t));
   }
}

//+------------------------------------------------------------------+
//| Closed positions -> statistics and journal                       |
//+------------------------------------------------------------------+
ulong LatestDealTicket()
{
   ulong last = 0;
   if(HistorySelect(TimeCurrent() - 30 * 86400, TimeCurrent() + 60))
      for(int i = HistoryDealsTotal() - 1; i >= 0; i--)
      {
         ulong d = HistoryDealGetTicket(i);
         if(d > last)
            last = d;
      }
   return(last);
}

void ScanClosedDeals()
{
   if(!HistorySelect(TimeCurrent() - 14 * 86400, TimeCurrent() + 60))
      return;
   int total = HistoryDealsTotal();
   for(int i = 0; i < total; i++)
   {
      ulong d = HistoryDealGetTicket(i);
      if(d == 0 || d <= g_lastDealTicket)
         continue;
      g_lastDealTicket = d;
      if(HistoryDealGetInteger(d, DEAL_MAGIC) != InpMagicNumber || HistoryDealGetString(d, DEAL_SYMBOL) != _Symbol)
         continue;

      long   entry  = HistoryDealGetInteger(d, DEAL_ENTRY);
      double price  = HistoryDealGetDouble(d, DEAL_PRICE);
      double volume = HistoryDealGetDouble(d, DEAL_VOLUME);
      string cmt    = HistoryDealGetString(d, DEAL_COMMENT);
      long   dtype  = HistoryDealGetInteger(d, DEAL_TYPE);

      if(entry == DEAL_ENTRY_IN)
      {
         JournalWrite("TRADE_OPEN", dtype == DEAL_TYPE_BUY ? "BUY" : "SELL", price, 0, 0, volume, 0,
                      AccountInfoDouble(ACCOUNT_BALANCE), cmt + " | Deal=" + IntegerToString((long)d));
         continue;
      }
      if(entry != DEAL_ENTRY_OUT)
         continue;

      double profit = HistoryDealGetDouble(d, DEAL_PROFIT) + HistoryDealGetDouble(d, DEAL_SWAP)
                    + HistoryDealGetDouble(d, DEAL_COMMISSION);
      if(profit >= 0.0) { g_totalWins++; g_sessWins++; }
      else              { g_totalLosses++; g_sessLosses++; }
      g_totalPnl += profit;
      g_sessPnl  += profit;

      double balance = AccountInfoDouble(ACCOUNT_BALANCE);
      if(balance > g_peakBalance)
         g_peakBalance = balance;
      g_maxDrawdown = MathMax(g_maxDrawdown, g_peakBalance - balance);

      long   reason = HistoryDealGetInteger(d, DEAL_REASON);
      string why    = (reason == DEAL_REASON_TP) ? "TP" : (reason == DEAL_REASON_SL) ? "SL" : "OTHER";
      JournalWrite("TRADE_CLOSE", dtype == DEAL_TYPE_BUY ? "BUY_CLOSE" : "SELL_CLOSE", price, 0, 0, volume, profit,
                   balance, "Exit=" + why + " | " + cmt + " | Deal=" + IntegerToString((long)d));
      if(InpEnableAlerts)
         Alert(_Symbol, " | position closed (", why, ") | P&L $", DoubleToString(profit, 2));
   }
}

//+------------------------------------------------------------------+
//| Utilities                                                        |
//+------------------------------------------------------------------+
double StopsLevelPoints()
{
   return((double)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL));
}

void CountSide(bool buy, int &pending, int &open, int &atBE)
{
   pending = 0;
   open = 0;
   atBE = 0;
   for(int i = OrdersTotal() - 1; i >= 0; i--)
   {
      ulong t = OrderGetTicket(i);
      if(t == 0 || OrderGetString(ORDER_SYMBOL) != _Symbol || OrderGetInteger(ORDER_MAGIC) != InpMagicNumber)
         continue;
      if(OrderGetInteger(ORDER_TYPE) == (buy ? ORDER_TYPE_BUY_STOP : ORDER_TYPE_SELL_STOP))
         pending++;
   }
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong t = PositionGetTicket(i);
      if(t == 0 || PositionGetString(POSITION_SYMBOL) != _Symbol || PositionGetInteger(POSITION_MAGIC) != InpMagicNumber)
         continue;
      if(PositionGetInteger(POSITION_TYPE) != (buy ? POSITION_TYPE_BUY : POSITION_TYPE_SELL))
         continue;
      open++;
      double sl = PositionGetDouble(POSITION_SL), op = PositionGetDouble(POSITION_PRICE_OPEN);
      if(sl > 0.0 && (buy ? sl >= op : sl <= op))
         atBE++;
   }
}

//+------------------------------------------------------------------+
//|   INFO PANEL                                                     |
//+------------------------------------------------------------------+
void PanelCreate()
{
   string bg = g_pfx + "BG";
   ObjectCreate(0, bg, OBJ_RECTANGLE_LABEL, 0, 0, 0);
   ObjectSetInteger(0, bg, OBJPROP_XDISTANCE,   InpPanelX);
   ObjectSetInteger(0, bg, OBJPROP_YDISTANCE,   InpPanelY);
   ObjectSetInteger(0, bg, OBJPROP_XSIZE,       PANEL_W);
   ObjectSetInteger(0, bg, OBJPROP_YSIZE,       (ROW_LAST + 1) * ROW_H + 10);
   ObjectSetInteger(0, bg, OBJPROP_BGCOLOR,     InpPanelBg);
   ObjectSetInteger(0, bg, OBJPROP_BORDER_TYPE, BORDER_FLAT);
   ObjectSetInteger(0, bg, OBJPROP_COLOR,       C'50,60,80');
   ObjectSetInteger(0, bg, OBJPROP_CORNER,      CORNER_LEFT_UPPER);
   ObjectSetInteger(0, bg, OBJPROP_BACK,        false);
   ObjectSetInteger(0, bg, OBJPROP_SELECTABLE,  false);

   for(int r = 0; r < ROW_LAST; r++)
   {
      int y = InpPanelY + 6 + r * ROW_H;
      string lbl = g_pfx + "L" + IntegerToString(r);
      ObjectCreate(0, lbl, OBJ_LABEL, 0, 0, 0);
      ObjectSetInteger(0, lbl, OBJPROP_XDISTANCE,  InpPanelX + 8);
      ObjectSetInteger(0, lbl, OBJPROP_YDISTANCE,  y);
      ObjectSetInteger(0, lbl, OBJPROP_CORNER,     CORNER_LEFT_UPPER);
      ObjectSetInteger(0, lbl, OBJPROP_COLOR,      InpLabelColor);
      ObjectSetInteger(0, lbl, OBJPROP_FONTSIZE,   FONT_SIZE);
      ObjectSetString (0, lbl, OBJPROP_FONT,       FONT_FACE);
      ObjectSetInteger(0, lbl, OBJPROP_SELECTABLE, false);
      ObjectSetString (0, lbl, OBJPROP_TEXT,       "");

      string val = g_pfx + "V" + IntegerToString(r);
      ObjectCreate(0, val, OBJ_LABEL, 0, 0, 0);
      ObjectSetInteger(0, val, OBJPROP_XDISTANCE,  InpPanelX + PANEL_W - 8);
      ObjectSetInteger(0, val, OBJPROP_YDISTANCE,  y);
      ObjectSetInteger(0, val, OBJPROP_CORNER,     CORNER_LEFT_UPPER);
      ObjectSetInteger(0, val, OBJPROP_ANCHOR,     ANCHOR_RIGHT_UPPER);
      ObjectSetInteger(0, val, OBJPROP_COLOR,      InpValueColor);
      ObjectSetInteger(0, val, OBJPROP_FONTSIZE,   FONT_SIZE);
      ObjectSetString (0, val, OBJPROP_FONT,       FONT_FACE);
      ObjectSetInteger(0, val, OBJPROP_SELECTABLE, false);
      ObjectSetString (0, val, OBJPROP_TEXT,       "");
   }
   PanelUpdate();
}

void PanelRow(int row, string label, string value, color vc = clrNONE)
{
   ObjectSetString (0, g_pfx + "L" + IntegerToString(row), OBJPROP_TEXT,  label);
   ObjectSetString (0, g_pfx + "V" + IntegerToString(row), OBJPROP_TEXT,  value);
   ObjectSetInteger(0, g_pfx + "L" + IntegerToString(row), OBJPROP_COLOR, InpLabelColor);
   ObjectSetInteger(0, g_pfx + "V" + IntegerToString(row), OBJPROP_COLOR, vc == clrNONE ? InpValueColor : vc);
}

void PanelSep(int row, string txt = "")
{
   string s = (txt == "") ? "--------------------------------" : "-- " + txt + " --";
   ObjectSetString (0, g_pfx + "L" + IntegerToString(row), OBJPROP_TEXT,  s);
   ObjectSetString (0, g_pfx + "V" + IntegerToString(row), OBJPROP_TEXT,  "");
   ObjectSetInteger(0, g_pfx + "L" + IntegerToString(row), OBJPROP_COLOR, C'55,65,85');
}

void PanelUpdate()
{
   if(ObjectFind(0, g_pfx + "BG") < 0)
      return;
   double bid    = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   long   spread = SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);

   ObjectSetString (0, g_pfx + "L0", OBJPROP_TEXT, "  GOLD BREAKOUT  PARTIAL-BE  v3.10");
   ObjectSetString (0, g_pfx + "V0", OBJPROP_TEXT, "");
   ObjectSetInteger(0, g_pfx + "L0", OBJPROP_COLOR, InpHeaderColor);
   PanelSep(ROW_SEP1);

   PanelRow(ROW_PRICE,  _Symbol, DoubleToString(bid, _Digits));
   PanelRow(ROW_SPREAD, "Spread", IntegerToString(spread) + " pts", spread > InpMaxSpreadPts ? InpLossColor : InpProfitColor);
   PanelRow(ROW_CLOCK,  "Server / UTC offset", "+" + IntegerToString(ServerOffsetHours(TimeCurrent())) + "h");
   PanelSep(ROW_SEP2, "LEVELS");

   PanelRow(ROW_MODE, "Mode", InpLevelMode == LEVELS_PREV_DAY ? "Yesterday high/low" :
            StringFormat("Asia %02d-%02d UTC", InpAsiaStartUTC, InpAsiaEndUTC));
   PanelRow(ROW_UP, "Upper level", g_up > 0 ? DoubleToString(g_up, _Digits) : "waiting", InpProfitColor);
   PanelRow(ROW_DN, "Lower level", g_dn > 0 ? DoubleToString(g_dn, _Digits) : "waiting", InpLossColor);
   PanelRow(ROW_RANGE, "Range", (g_up > 0 && g_dn > 0) ? DoubleToString((g_up - g_dn) / _Point, 0) + " pts" : "-");
   if(InpExitMode == EXIT_PARTIAL_BE)
      PanelRow(ROW_DIST, "1R today (pts)", DoubleToString(g_slPts, 0) + (InpAtrScaling ? " (ATR)" : ""));
   else
      PanelRow(ROW_DIST, "SL / TP / trail", StringFormat("%.0f / %.0f / %.0f-%.0f", g_slPts, g_tpPts, g_trailStartPts, g_trailDistPts));
   PanelSep(ROW_SEP3, "ORDERS");

   PanelRow(ROW_STATUS, "Status", g_status, InpNeutralColor);
   for(int k = 0; k < 2; k++)
   {
      int pend, open, be;
      CountSide(k == 0, pend, open, be);
      string s = g_sideNote[k];
      color  c = InpLabelColor;
      if(open > 0)
      {
         s = StringFormat("ACTIVE %d%s", open, be > 0 ? StringFormat(" (%d at BE+)", be) : "");
         c = (k == 0) ? InpProfitColor : InpLossColor;
      }
      else if(pend > 0)
      {
         s = StringFormat("PENDING %d", pend);
         c = InpNeutralColor;
      }
      PanelRow(k == 0 ? ROW_BUY : ROW_SELL, k == 0 ? "Buy stop" : "Sell stop", s, c);
   }
   PanelSep(ROW_SEP4, "OPEN POSITIONS");

   int    openCount = 0;
   double openPnl   = 0.0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong t = PositionGetTicket(i);
      if(t == 0 || PositionGetString(POSITION_SYMBOL) != _Symbol || PositionGetInteger(POSITION_MAGIC) != InpMagicNumber)
         continue;
      openCount++;
      openPnl += PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP);
   }
   PanelRow(ROW_OPEN,  "Open positions", IntegerToString(openCount));
   PanelRow(ROW_FLOAT, "Floating P&L", "$" + DoubleToString(openPnl, 2), openPnl >= 0 ? InpProfitColor : InpLossColor);
   PanelSep(ROW_SEP5, "TODAY");

   PanelRow(ROW_SESS_WL,  "W / L today", IntegerToString(g_sessWins) + " / " + IntegerToString(g_sessLosses));
   PanelRow(ROW_SESS_PNL, "P&L today", "$" + DoubleToString(g_sessPnl, 2), g_sessPnl >= 0 ? InpProfitColor : InpLossColor);
   PanelSep(ROW_SEP6, "SINCE EA START");

   int    n  = g_totalWins + g_totalLosses;
   double wr = n > 0 ? 100.0 * g_totalWins / n : 0.0;
   PanelRow(ROW_TOTAL_WL,  "Closed (W/L)", IntegerToString(g_totalWins) + "W / " + IntegerToString(g_totalLosses) + "L");
   PanelRow(ROW_TOTAL_WR,  "Win rate", DoubleToString(wr, 1) + "%", wr >= 50 ? InpProfitColor : InpLossColor);
   PanelRow(ROW_TOTAL_PNL, "Total P&L", "$" + DoubleToString(g_totalPnl, 2), g_totalPnl >= 0 ? InpProfitColor : InpLossColor);
   PanelRow(ROW_MAX_DD,    "Max drawdown", "$" + DoubleToString(g_maxDrawdown, 2), g_maxDrawdown > 0 ? InpLossColor : InpLabelColor);
   PanelRow(ROW_BALANCE,   "Balance", "$" + DoubleToString(AccountInfoDouble(ACCOUNT_BALANCE), 2));
   PanelSep(ROW_SEP7, "SETTINGS");

   PanelRow(ROW_RISK, "Size", InpAutoLot ? "Auto " + DoubleToString(InpRiskPercent, 2) + "% risk"
                                         : DoubleToString(InpManualLots, 2) + " lots");
   PanelRow(ROW_EXIT, "Exit", InpExitMode == EXIT_PARTIAL_BE
            ? StringFormat("%.0f%% @%.1fR, then BE", InpPartialPct, InpTP1_R)
            : StringFormat("SL/TP + trail %.0f/%.0f", InpTrailStartPts, InpTrailDistPts));
   PanelRow(ROW_RUNNER, "Second half", InpExitMode != EXIT_PARTIAL_BE ? "-" :
            (InpRunnerMode == RUNNER_TRAIL ? StringFormat("trail %.1fR behind", InpRunnerTrailR)
                                           : StringFormat("target %.1fR", InpFinalR)));
   PanelRow(ROW_FILTERS, "Fri close / sell SMA / recov",
            StringFormat("%s / %s / %s",
                         InpFridayClose ? StringFormat("%02d:%02d", InpFridayHour, InpFridayMinute) : "off",
                         InpSellTrendFilter ? IntegerToString(InpTrendSmaDays) : "off",
                         !InpRecoveryMode ? "off" : (g_recoveryActive ? "ACTIVE" : "ready")),
            g_recoveryActive ? InpLossColor : clrNONE);
   ChartRedraw(0);
}

void PanelDelete()
{
   ObjectsDeleteAll(0, g_pfx);
   ChartRedraw(0);
}

//+------------------------------------------------------------------+
//|   TRADE JOURNAL (CSV in MQL5\Files)                              |
//+------------------------------------------------------------------+
void JournalInit()
{
   int h = FileOpen(InpJournalFile, FILE_READ | FILE_CSV);
   if(h == INVALID_HANDLE)
   {
      h = FileOpen(InpJournalFile, FILE_WRITE | FILE_CSV | FILE_ANSI);
      if(h == INVALID_HANDLE)
      {
         Print("ERROR: cannot create journal ", InpJournalFile);
         return;
      }
      FileWrite(h, "Timestamp", "EventType", "Direction", "Price_Entry", "Price_SL", "Price_TP",
                "Volume_Lots", "PnL_USD", "Balance_USD", "Notes");
      FileClose(h);
      return;
   }
   FileClose(h);
}

void JournalWrite(string eventType, string direction, double priceEntry, double priceSL, double priceTP,
                  double volumeLots, double pnl, double balance, string notes)
{
   if(!InpEnableJournal)
      return;
   int h = FileOpen(InpJournalFile, FILE_READ | FILE_WRITE | FILE_CSV | FILE_ANSI);
   if(h == INVALID_HANDLE)
      return;
   FileSeek(h, 0, SEEK_END);
   FileWrite(h,
             TimeToString(TimeCurrent(), TIME_DATE | TIME_SECONDS),
             eventType,
             direction,
             priceEntry > 0 ? DoubleToString(priceEntry, _Digits) : "",
             priceSL    > 0 ? DoubleToString(priceSL, _Digits) : "",
             priceTP    > 0 ? DoubleToString(priceTP, _Digits) : "",
             volumeLots > 0 ? DoubleToString(volumeLots, 2) : "",
             pnl != 0 ? DoubleToString(pnl, 2) : "",
             balance > 0 ? DoubleToString(balance, 2) : "",
             notes);
   FileClose(h);
}
//+------------------------------------------------------------------+
