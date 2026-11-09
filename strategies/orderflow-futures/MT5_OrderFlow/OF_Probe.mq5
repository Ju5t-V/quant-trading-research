//+------------------------------------------------------------------+
//|                                                     OF_Probe.mq5 |
//|  Feed capability probe for the orderflow toolkit.                |
//|                                                                  |
//|  Answers three questions that decide what can honestly be built: |
//|                                                                  |
//|   1. Does this symbol carry REAL traded volume, or only tick     |
//|      counts?  (volume_real / TICK_FLAG_VOLUME)                   |
//|   2. Does the feed tell us the AGGRESSOR side of each trade,     |
//|      or must buy/sell be inferred?  (TICK_FLAG_BUY / SELL)       |
//|   3. Is there a readable ORDER BOOK?  Most CFD brokers show a    |
//|      manual DOM window but block MarketBookAdd() from code -     |
//|      that returns error 4901 with bookdepth 0.  Without this a   |
//|      Bookmap-style liquidity heatmap is impossible, so we test   |
//|      rather than assume.                                         |
//|                                                                  |
//|  Drag onto any chart, wait ~20s, then send the Experts log or    |
//|  the CSV written to MQL5\Files\OF_Probe_<server>.csv             |
//+------------------------------------------------------------------+
#property copyright "Jerry"
#property version   "1.00"
#property script_show_inputs
#property description "Reports what real orderflow data this broker/feed actually provides"

input string InpSymbols     = "XAUUSD,USTEC,QQQ,NVDA"; // Symbols to probe (comma separated)
input int    InpTickHours   = 3;                       // Hours of tick history to sample
input int    InpBookWaitSec = 8;                       // Seconds to wait for order book updates
input int    InpMaxTicks    = 300000;                  // Safety cap on ticks examined per symbol

//--- one row of findings per symbol
struct ProbeResult
{
   string symbol;
   bool   exists;
   long   bookDepth;        // SYMBOL_TICKS_BOOKDEPTH (0 = broker declares no book)
   bool   bookAdded;        // MarketBookAdd() succeeded
   int    bookAddError;     // error if it did not
   int    bookLevelsMax;    // most levels ever returned by MarketBookGet()
   string bookSample;       // a readable ladder snapshot
   int    ticksTotal;
   int    ticksLast;        // carrying a real "last traded price"
   int    ticksBuy;         // carrying a true aggressor flag
   int    ticksSell;
   int    ticksVolReal;     // carrying volume_real > 0
   double volRealSum;
   long   volLongSum;
   double ticksPerMin;
   string calcMode;
   string exeMode;
   string chartMode;
   int    digits;
   double point;
};

ProbeResult g_res[];

//+------------------------------------------------------------------+
string CalcModeText(long m)
{
   switch((ENUM_SYMBOL_CALC_MODE)m)
   {
      case SYMBOL_CALC_MODE_FOREX:              return "FOREX";
      case SYMBOL_CALC_MODE_FOREX_NO_LEVERAGE:  return "FOREX_NO_LEVERAGE";
      case SYMBOL_CALC_MODE_FUTURES:            return "FUTURES";
      case SYMBOL_CALC_MODE_CFD:                return "CFD";
      case SYMBOL_CALC_MODE_CFDINDEX:           return "CFDINDEX";
      case SYMBOL_CALC_MODE_CFDLEVERAGE:        return "CFDLEVERAGE";
      case SYMBOL_CALC_MODE_EXCH_STOCKS:        return "EXCH_STOCKS";
      case SYMBOL_CALC_MODE_EXCH_FUTURES:       return "EXCH_FUTURES";
      case SYMBOL_CALC_MODE_EXCH_FUTURES_FORTS: return "EXCH_FUTURES_FORTS";
      case SYMBOL_CALC_MODE_EXCH_BONDS:         return "EXCH_BONDS";
      case SYMBOL_CALC_MODE_EXCH_STOCKS_MOEX:   return "EXCH_STOCKS_MOEX";
      case SYMBOL_CALC_MODE_EXCH_BONDS_MOEX:    return "EXCH_BONDS_MOEX";
      case SYMBOL_CALC_MODE_SERV_COLLATERAL:    return "SERV_COLLATERAL";
   }
   return "UNKNOWN(" + IntegerToString(m) + ")";
}

//+------------------------------------------------------------------+
string ExeModeText(long m)
{
   switch((ENUM_SYMBOL_TRADE_EXECUTION)m)
   {
      case SYMBOL_TRADE_EXECUTION_REQUEST:  return "REQUEST";
      case SYMBOL_TRADE_EXECUTION_INSTANT:  return "INSTANT";
      case SYMBOL_TRADE_EXECUTION_MARKET:   return "MARKET";
      case SYMBOL_TRADE_EXECUTION_EXCHANGE: return "EXCHANGE";
   }
   return "UNKNOWN(" + IntegerToString(m) + ")";
}

//+------------------------------------------------------------------+
//| Subscribe to the book and poll it - this is the make-or-break    |
//| test for a liquidity heatmap                                     |
//+------------------------------------------------------------------+
void ProbeBook(ProbeResult &r)
{
   r.bookDepth     = SymbolInfoInteger(r.symbol, SYMBOL_TICKS_BOOKDEPTH);
   r.bookLevelsMax = 0;
   r.bookSample    = "";

   ResetLastError();
   r.bookAdded = MarketBookAdd(r.symbol);
   if(!r.bookAdded)
   {
      r.bookAddError = GetLastError();
      return;
   }
   r.bookAddError = 0;

   MqlBookInfo book[];
   for(int s = 0; s < InpBookWaitSec * 4; s++)
   {
      Sleep(250);
      ResetLastError();
      if(!MarketBookGet(r.symbol, book))
         continue;

      int n = ArraySize(book);
      if(n > r.bookLevelsMax)
      {
         r.bookLevelsMax = n;
         // keep the deepest ladder we saw, trimmed to something readable
         string txt = "";
         int show = (int)MathMin(n, 10);
         for(int i = 0; i < show; i++)
         {
            string side = (book[i].type == BOOK_TYPE_SELL || book[i].type == BOOK_TYPE_SELL_MARKET) ? "ASK" : "BID";
            txt += side + " " + DoubleToString(book[i].price, r.digits)
                        + " x" + IntegerToString(book[i].volume) + " | ";
         }
         r.bookSample = txt;
      }
   }
   MarketBookRelease(r.symbol);
}

//+------------------------------------------------------------------+
//| Walk recent ticks and count what the feed actually carries       |
//+------------------------------------------------------------------+
void ProbeTicks(ProbeResult &r)
{
   datetime to   = TimeCurrent();
   datetime from = to - (datetime)(InpTickHours * 3600);

   MqlTick ticks[];
   int got = -1;
   for(int attempt = 0; attempt < 12; attempt++)
   {
      ResetLastError();
      got = CopyTicksRange(r.symbol, ticks, COPY_TICKS_ALL,
                           (ulong)from * 1000, (ulong)to * 1000);
      if(got > 0)
         break;
      Sleep(500);   // 4401 = tick history still downloading
   }
   if(got <= 0)
   {
      r.ticksTotal = 0;
      return;
   }

   int n = (int)MathMin(got, InpMaxTicks);
   r.ticksTotal = n;

   for(int i = 0; i < n; i++)
   {
      uint f = ticks[i].flags;
      if((f & TICK_FLAG_LAST) != 0) r.ticksLast++;
      if((f & TICK_FLAG_BUY)  != 0) r.ticksBuy++;
      if((f & TICK_FLAG_SELL) != 0) r.ticksSell++;
      if(ticks[i].volume_real > 0.0)
      {
         r.ticksVolReal++;
         r.volRealSum += ticks[i].volume_real;
      }
      r.volLongSum += (long)ticks[i].volume;
   }

   double mins = (double)(ticks[n-1].time - ticks[0].time) / 60.0;
   r.ticksPerMin = (mins > 0.0) ? (double)n / mins : 0.0;
}

//+------------------------------------------------------------------+
void ClearResult(ProbeResult &r, string sym)
{
   r.symbol       = sym;
   r.exists       = false;
   r.bookDepth    = 0;
   r.bookAdded    = false;
   r.bookAddError = 0;
   r.bookLevelsMax= 0;
   r.bookSample   = "";
   r.ticksTotal   = 0;
   r.ticksLast    = 0;
   r.ticksBuy     = 0;
   r.ticksSell    = 0;
   r.ticksVolReal = 0;
   r.volRealSum   = 0.0;
   r.volLongSum   = 0;
   r.ticksPerMin  = 0.0;
   r.calcMode     = "-";
   r.exeMode      = "-";
   r.chartMode    = "-";
   r.digits       = 5;
   r.point        = 0.0;
}

//+------------------------------------------------------------------+
void OnStart()
{
   string parts[];
   int count = StringSplit(InpSymbols, ',', parts);
   if(count <= 0)
   {
      Print("OF_Probe: no symbols given");
      return;
   }

   ArrayResize(g_res, count);

   Print("==================================================================");
   Print("OF_Probe  |  server: ", AccountInfoString(ACCOUNT_SERVER),
         "  |  build: ", TerminalInfoInteger(TERMINAL_BUILD));
   Print("==================================================================");

   for(int i = 0; i < count; i++)
   {
      string sym = parts[i];
      StringTrimLeft(sym);
      StringTrimRight(sym);

      ClearResult(g_res[i], sym);

      if(!SymbolSelect(sym, true))
      {
         Print("--- ", sym, ": NOT AVAILABLE on this server");
         continue;
      }
      g_res[i].exists    = true;
      g_res[i].digits    = (int)SymbolInfoInteger(sym, SYMBOL_DIGITS);
      g_res[i].point     = SymbolInfoDouble(sym, SYMBOL_POINT);
      g_res[i].calcMode  = CalcModeText(SymbolInfoInteger(sym, SYMBOL_TRADE_CALC_MODE));
      g_res[i].exeMode   = ExeModeText(SymbolInfoInteger(sym, SYMBOL_TRADE_EXEMODE));
      g_res[i].chartMode = (SymbolInfoInteger(sym, SYMBOL_CHART_MODE) == SYMBOL_CHART_MODE_LAST)
                           ? "LAST" : "BID";

      Print("--- probing ", sym, " ...");
      ProbeTicks(g_res[i]);
      ProbeBook(g_res[i]);
   }

   Report();
}

//+------------------------------------------------------------------+
void Report()
{
   int n = ArraySize(g_res);

   Print("");
   Print("=========================== RESULTS ==============================");
   for(int i = 0; i < n; i++)
   {
      Print("");
      Print("### ", g_res[i].symbol);
      if(!g_res[i].exists)
      {
         Print("   not available on this server");
         continue;
      }
      Print("   calc mode      : ", g_res[i].calcMode, "   exec: ", g_res[i].exeMode,
            "   chart: ", g_res[i].chartMode, "   digits: ", g_res[i].digits);
      Print("   ticks sampled  : ", g_res[i].ticksTotal,
            "  (", DoubleToString(g_res[i].ticksPerMin, 1), " ticks/min)");
      if(g_res[i].ticksTotal > 0)
      {
         Print("   real volume    : ", g_res[i].ticksVolReal, " ticks carry volume_real",
               "   sum=", DoubleToString(g_res[i].volRealSum, 2),
               "   (tick.volume sum=", g_res[i].volLongSum, ")");
         Print("   last-price flag: ", g_res[i].ticksLast, " / ", g_res[i].ticksTotal);
         Print("   aggressor flags: BUY=", g_res[i].ticksBuy, "  SELL=", g_res[i].ticksSell,
               (g_res[i].ticksBuy + g_res[i].ticksSell == 0
                ? "   -> NONE, side must be inferred"
                : "   -> REAL aggressor side"));
      }
      Print("   SYMBOL_TICKS_BOOKDEPTH: ", g_res[i].bookDepth);
      if(g_res[i].bookAdded)
         Print("   MarketBookAdd  : OK    deepest MarketBookGet = ", g_res[i].bookLevelsMax, " levels");
      else
         Print("   MarketBookAdd  : FAILED, error ", g_res[i].bookAddError,
               (g_res[i].bookAddError == 4901 ? " (ERR_BOOKS_CANNOT_ADD - broker blocks API depth)" : ""));
      if(StringLen(g_res[i].bookSample) > 0)
         Print("   ladder sample  : ", g_res[i].bookSample);

      //--- the plain-English verdict
      string vol = (g_res[i].ticksVolReal > 0) ? "REAL volume" : "tick counts only";
      string agg = (g_res[i].ticksBuy + g_res[i].ticksSell > 0)
                   ? "real aggressor side" : "inferred aggressor side";
      string dom = "NO depth from code";
      if(g_res[i].bookAdded && g_res[i].bookLevelsMax > 2)
         dom = "usable depth (" + IntegerToString(g_res[i].bookLevelsMax) + " levels)";
      else if(g_res[i].bookAdded && g_res[i].bookLevelsMax > 0)
         dom = "best bid/ask only - not a heatmap";
      Print("   VERDICT        : ", vol, " | ", agg, " | ", dom);
   }
   Print("==================================================================");

   WriteCsv();
}

//+------------------------------------------------------------------+
void WriteCsv()
{
   string server = AccountInfoString(ACCOUNT_SERVER);
   StringReplace(server, " ", "_");
   string fname = "OF_Probe_" + server + ".csv";

   int h = FileOpen(fname, FILE_WRITE | FILE_CSV | FILE_ANSI, ',');
   if(h == INVALID_HANDLE)
   {
      Print("OF_Probe: could not write ", fname, " error ", GetLastError());
      return;
   }

   FileWrite(h, "symbol", "exists", "calc_mode", "exec_mode", "chart_mode", "digits", "point",
                "ticks_sampled", "ticks_per_min", "ticks_with_last", "ticks_buy_flag",
                "ticks_sell_flag", "ticks_volume_real", "sum_volume_real", "sum_tick_volume",
                "book_depth_declared", "book_add_ok", "book_add_error", "book_levels_max",
                "book_sample");

   for(int i = 0; i < ArraySize(g_res); i++)
   {
      FileWrite(h, g_res[i].symbol, (g_res[i].exists ? 1 : 0), g_res[i].calcMode,
                   g_res[i].exeMode, g_res[i].chartMode, g_res[i].digits,
                   DoubleToString(g_res[i].point, 8),
                   g_res[i].ticksTotal, DoubleToString(g_res[i].ticksPerMin, 2),
                   g_res[i].ticksLast, g_res[i].ticksBuy, g_res[i].ticksSell,
                   g_res[i].ticksVolReal, DoubleToString(g_res[i].volRealSum, 2),
                   g_res[i].volLongSum, g_res[i].bookDepth, (g_res[i].bookAdded ? 1 : 0),
                   g_res[i].bookAddError, g_res[i].bookLevelsMax, g_res[i].bookSample);
   }
   FileClose(h);

   Print("OF_Probe: wrote MQL5\\Files\\", fname);
}
//+------------------------------------------------------------------+
