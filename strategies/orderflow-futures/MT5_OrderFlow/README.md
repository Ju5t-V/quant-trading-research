# MT5 Orderflow Toolkit

Three MT5 indicators for reading the chart by hand: a volume heatmap, automatic
HVN/POC/value-area levels, and absorption detection.

Built 2026-09-12. Source lives here; compiled copies are already installed in the
terminal at `...\MQL5\Indicators\OrderFlow\` and `...\MQL5\Scripts\OrderFlow\`.

---

## What is installed

| File | Where it goes in MT5 | What it does |
|---|---|---|
| `OF_Probe.mq5` | Navigator → Scripts → OrderFlow | Reports what your feed actually provides. Run it once per broker. |
| `OF_Heatmap.mq5` | Navigator → Indicators → OrderFlow | Volume heatmap, profile, POC, value area, HVN/LVN, widest void, dashboard |
| `OF_Absorption.mq5` | Navigator → Indicators → OrderFlow | Volume bubbles — unusual volume by default, absorption tests optional |
| `OF_Sessions.mq5` | Navigator → Indicators → OrderFlow | Shades Asia / London / New York and marks each session's high and low |

Drag them onto a chart from the Navigator panel (Ctrl+N if it is hidden).

---

## What your feed actually carries — measured, not assumed

Checked directly against the live terminal on **MetaQuotes-Demo, build 6192**:

| | XAUUSD | USTEC | QQQ / NVDA / MSFT / AMD |
|---|---|---|---|
| Calc mode | CFD (leverage) | CFD | Exchange stocks |
| Ticks available | 1.8M over 4 days (351/min) | 976k (191/min) | **none — server serves no ticks** |
| Real traded volume | **no** | **no** | **yes, but bar-level only** |
| Aggressor side (buy/sell flag) | **no** — inferred | **no** — inferred | n/a (no ticks) |
| Declared book depth | **32 levels** | **10 levels** | 0 |
| `MarketBookAdd` from code | **succeeded** | **succeeded** | failed |

Three things to take from that:

1. **Volume on gold is a tick count, not contracts.** Every tool here says so on the
   chart in orange rather than hiding it. Tick count tracks real activity closely on
   gold, but it is not the same thing, and delta is *inferred* with the tick rule —
   useful, but an estimate, and weakest on thin fast moves.

2. **The free real-volume route does not work here — checked and closed off.** The US
   stock symbols on MetaQuotes-Demo *do* carry genuine exchange volume (QQQ shows 880M
   shares over 60 days, NVDA 4.2bn), which looked like a free way to practise on real
   contracts. But the server serves **no tick history at all** for them — 20 forced
   download attempts returned nothing. Both tools here are tick-based, so they cannot
   run on those symbols. Real volume at bar level only, which is not orderflow.

3. **The order book is more promising than expected.** I assumed a CFD broker would
   block API depth outright. This one declares 32 levels on gold and accepted the
   subscription. It returned no levels — but it was Saturday with the market shut, so
   that proves nothing either way. **Re-run `OF_Probe` during the Monday session.** If
   real levels come back, a Bookmap-style liquidity heatmap is genuinely buildable here
   and that is the third indicator.

### What it actually draws — Friday 11 Sep gold session, M5

Replicating the shipped code against that session (264 bars, 01:00–22:55):

```
POC 4346.30    value area 4328.10 – 4380.10  (70.0% of volume)
HVN 4332.90 / 4346.30 / 4352.50 / 4362.80    (min gap $4.20, from the VA width)
LVN 4340.90 / 4356.80                        (genuine pockets between the shelves)
absorption  16:50  BEAR at 4390.15  delta +581/3391  vol 1.6x  range 0.59x ATR
```

That last one reads correctly: buyers were leaning on it (delta positive) just above the
value-area high, and the bar still closed in its bottom 40%. Buying absorbed.

### Verification done

- Replicated the heatmap's bucketing independently in Python against the same ticks:
  cells sum back to the bar volume on **39/39 bars** for both XAUUSD and USTEC.
- Found and fixed a real bug doing it: `COPY_TICKS_ALL` also returns ask-only quote
  updates, which MT5's own bar volume does not count. Including them inflated gold's
  volume by **50.7%**. With the fix (`InpMatchBarVol`, on by default) the heatmap now
  matches the terminal's bar volume **exactly** — 54,707 vs 54,707 over 39 bars.
- POC / value area cross-checked: value area covers 70.0% of volume on gold, 70.1% on
  USTEC, as it should.
- Fixed two more bugs found the same way: HVN nodes were spaced by a fixed bucket count
  (80 cents on gold), which reported one shelf as four levels; and LVNs were being found
  in the dead tails of the range rather than between shelves, where an air pocket actually
  means something. LVN candidates are now bounded by the outermost HVNs.

---

## OF_Heatmap — how to read it

**The heatmap.** Each bar is sliced into price buckets and shaded by how much volume
traded in each. Bright = heavy trade. It shows where price spent its effort, which is
usually more informative than where it closed. A bar that looks like a plain long candle
often turns out to have one bright shelf and a lot of empty space — that shelf is the
real level.

**The profile on the right** is the same data collapsed into one histogram.

**The lines it draws:**

| Line | Meaning | How it is used |
|---|---|---|
| **POC** (red, solid) | The single most-traded price | The session's magnet. Price keeps coming back. |
| **VAH / VAL** (blue, dashed) | Edges of the 70% value area | Inside = balance, outside = trend. Rejection at the edge is a common fade. |
| **HVN** (gold **shaded band** + line) | A shelf of heavy trade, drawn at its true width | Price stalls and rotates in here. The band is the area price has to chew through. |
| **LVN** (grey, dotted) | An air pocket, barely traded | Price travels through fast. Bad place for a target, good place for a stop. |

**Settings worth touching:**

- `InpScope` — `SCOPE_SESSION` (default) profiles today from midnight server time.
  `SCOPE_VISIBLE` profiles whatever is on screen, which is handy for sizing up a
  multi-day range. `SCOPE_ROLLING` uses the last N bars.
- `InpBucketMode` (v1.10, default **Points**) — how the bucket height is chosen.
  **Points** uses `InpBucketPoints` exactly as before. That is 10 points = $0.10 only on a
  **2-digit** gold feed; on a 3-digit feed it is $0.01. **Price** uses `InpBucketPrice`
  (price units). **Auto** derives it from the symbol's tick size and the timeframe
  (M5 ≈ 0.25 bp of price ≈ $0.10 on gold; the table is a guess). The Experts log always
  prints digits, point, tick size, the bucket in use and what Auto would pick, in points
  and price, whichever mode you choose.
- `InpLogScale` — leave on. Linear scaling makes one big print drown out everything else.
- `InpHvnMinPct` — raise it (say 70) for fewer, stronger HVNs; lower it for more.
- `InpMinSepPct` — how far apart two nodes must be, as a share of value-area width
  (default 8%). This replaced a fixed bucket count, which was 80 cents on gold and split
  one shelf into four "separate" HVNs.
- `InpDataSource` (default Auto) — **Ticks** is the accurate mode and needs tick history;
  **Bars** spreads each bar's volume across its high-low range and therefore works on any
  symbol, including QQQ/NVDA where MetaQuotes serves no ticks at all; **Auto** uses ticks and
  falls back per bar. The status line says which is live, in orange when it fell back.
- `InpShowDash` (default on) — stats panel: POC, distance to POC, VA range, upper/lower mass
  split, mass skew, range location, total volume. Painted on the heatmap canvas, not as chart
  objects, so it costs nothing.
- `InpShowVoid` (default on) — shades the single widest run of near-empty buckets (below
  `InpVoidPct`, default 15% of the peak). This is the area price crosses fastest: a bad target,
  a good place to hide a stop behind.
- `InpRecencyWeight` (default off) — weights recent bars more heavily **in the profile only**.
  The heatmap cells stay raw, so the picture itself is never distorted. It forces the whole
  scope to be re-read every bar, so v1.10 **forces it off** (log + "RECENCY OFF - SCOPE TOO
  LARGE") when ticks would be read for more than `InpRecencyMaxBars` (300) bars.
- `InpHvnAsZone` (default on) — shade each HVN as a band rather than a bare line. The band
  grows out from the peak while the profile stays above `InpHvnZoneEdge` (default 70%) of
  that node's own height, capped at `InpHvnZoneMaxPct` of the value area. Bands that
  overlap are **merged**, so shading never stacks and the darkest patch is never an
  artefact. `InpHvnZoneAlpha` sets opacity. On Friday's gold session this gives three
  bands — 4330.00–4333.80, 4345.60–4353.60 (the main shelf) and 4360.80–4364.00.
  Turn it off to go back to plain lines.
- **HVN band look** (v1.10): the band is see-through (`InpHvnZoneAlpha` 35), its drawn height
  is capped at `InpHvnZoneMaxPx` (10 px) around the node so a zoomed-in chart is not covered
  (0 = the old full-shelf band), with thin edges (`InpHvnZoneEdges`) and an "HVN price" tag
  beside each node (`InpHvnLabels`). Drawing only — levels and what OF_Absorption reads are
  unchanged.

### v1.10 changes (2026-09-13)

- **The profile no longer moves when you zoom or scroll.** Before v1.10 the profile, POC,
  value area, HVN/LVN, widest void **and every dashboard number** were built from the bars
  on screen, using a bucket that also changed with zoom — so a "session" profile silently
  meant "the visible part of the session", and an M1 session was cut to 500 bars.
  `InpProfileFullScope` (default **on**) builds Session/Rolling profiles from one histogram
  covering the whole scope, closed bars only, at a zoom-independent bucket. Levels change
  only when a bar closes or the session resets. Off = the old behaviour. Visible scope is
  unchanged by definition.
- `InpProfileMaxBars` (2000) caps the scope; if hit the status line says **PROFILE
  TRUNCATED**. `InpProfileMaxRows` (600) coarsens very wide ranges for level detection,
  based on the price range, never on zoom.
- `InpAutoTune` (default **on** — this one is about not freezing the terminal):
  M1–M30 → Session scope with ticks (bar fallback on tick-less symbols); H1 and up →
  Rolling scope with bar data. Heatmap span comes from `InpMaxHeatmapHours` (48) instead of
  a bar count, clamped 50–500 bars; a manually changed `InpMaxBars` is respected. Build
  times and tick counts are logged, with a warning above 3 s (heatmap) / 5 s (profile).
- **HVN globals are per timeframe**: `OFHM_<symbol>_<tf>_hvn_count / _0.. / _time / _bucket`,
  so H1, M5 and M1 heatmaps on the same symbol no longer overwrite each other. Levels are
  republished only when they change; `_time` is a heartbeat; removing the heatmap marks
  the set stale immediately.
- `InpMinScopeBars` (30, a guess): until the scope has that many bars (start of a session)
  the heatmap publishes **no** HVNs and shows **PROFILE WARMING (n/30)**.

### v1.11 changes (2026-09-18)

- **Bar-close countdown.** `InpShowCountdown` (default on) adds a small "M15 close 04:32"
  chip docked to the stats panel - under it at the top corners, above it at the bottom ones,
  and in the panel's own slot when `InpShowDash` is off. It turns `InpCdWarnColor` (orange)
  in the last `InpCdWarnSecs` (10) seconds. It is painted on its own small canvas from the
  timer, **not** in `DrawDashboard`, so the heatmap itself is never redrawn to move a clock;
  the second only repaints when it changes. The countdown runs off `TimeTradeServer()`, so it
  keeps ticking in a dead session or at the weekend when no ticks arrive.

## OF_Absorption — how to read it

Absorption is heavy aggressive trade that fails to move price: someone passive is
soaking up everything the aggressors throw, so volume is large and price goes nowhere.

### What the literature actually says

- **Cont, Kukanov & Stoikov, *The Price Impact of Order Book Events*** ([SSRN 1712822](https://papers.ssrn.com/sol3/papers.cfm?abstract_id=1712822)):
  over short horizons price change is roughly **linear in order-flow imbalance**, with a
  slope **inversely proportional to market depth**. They also find the relation to raw
  *volume* is "noisy and less robust" than the one based on imbalance.
- That makes absorption precise: it is a **local collapse in Kyle's lambda** — a lot of
  flow producing far less price movement than that much flow normally produces.
- Practitioner criteria agree, e.g. [anomiq's absorption vs exhaustion](https://anomiq.io/blog/absorption-exhaustion/):
  **volume Z-score > 3**, **taker imbalance > ±60%**, **relative price impact < 0.8**.
- On trade classification, [Chakrabarty, Pascual & Shkilko](https://papers.ssrn.com/sol3/papers.cfm?abstract_id=2182819)
  find the **tick rule and Lee-Ready beat bulk volume classification** for aggressor
  accuracy — so the tick rule used here is the right choice, where trades exist at all.

### What that means for this feed — measured

| Ingredient | Needs | Works here? |
|---|---|---|
| Volume Z-score | bar volume | **yes** |
| Relative price impact | volume + price | **yes** |
| Taker imbalance (delta) | real bid/ask trade volume | **no** |

The delta leg was measured on 2000 gold M5 bars: net tick count explains **1.7%** of the
bar's price change (corr +0.13). That is not a bug — the control test in the same script
returns corr **+1.000** for tick-weighted flow vs close−open. It is the proxy that is weak,
and the reason is simple: on a quote-only CFD every tick weighs 1, but the information in
real delta is in the trade **sizes**, which this feed does not carry.

So the shipped default (`InpMethod = Z-score + price impact`) is built on the two legs that
work, and takes direction from which end of the bar the close rejected rather than from
delta. The original four-condition version is still selectable as `Classic`.

### The four things it draws

A blue marker = **bullish absorption** (selling got soaked up), orange = the reverse. The
line sits at the bar's own point of control — the exact price defended. A **gold box** is a
stacked zone: two or more absorptions at the same price within 30 bars.

`InpMarkerStyle` picks the marker:

- **Bubble** (default) — a filled circle whose **size scales with the bar's volume**, with
  the volume printed on it (`38.89K`) and a dotted stem down to the defended price. This is
  the volume-bubble look from orderflow terminals.
- **Circle** — a ring around the defended price, no size encoding.
- **Dot** / **Arrow** — plain markers.

Bubble geometry: `InpBubbleMinBars`/`InpBubbleMaxBars` set the radius range, and
`InpBubbleOffsetAtr` how far off the bar it floats.

### Does it work? Tested, and the answer is no — not as a trade trigger

2000 gold M5 bars, 8 trading days, fading in the direction of the rejection, 12-bar horizon:

| Setting | Signals/day | Median | Mean | Win % |
|---|---|---|---|---|
| baseline (every bar) | 236 | −11 | −25 | 49% |
| Z≥1.5, impact≤0.8 | 7.9 | +197 | **−30** | 57% |
| Z≥2.0, impact≤0.6 | 3.2 | +103 | **−578** | 54% |
| Z≥2.5, impact≤0.8 | 3.1 | +172 | **−456** | 60% |
| Z≥3.0, impact≤0.4 | 1.1 | −360 | **−1423** | 33% |

**Every configuration has a negative mean** while medians are positive — many small wins
paid for by occasional large losses. Worse, the signal gets *worse* as the criteria get
stricter: Z≥3.0 is the weakest row in the table. That is the signature of noise, not edge.

Caveats in both directions: 8 days is a short sample, one instrument, in-sample, one fixed
exit, no costs, and the delta leg is degraded. Practitioners also use absorption as
**context at a level**, never as a standalone mechanical entry. But nothing here supports
treating a marker as a reason to trade.

**Use it as an annotation** — it reliably marks "unusual volume, little movement, close
rejected one end", which is worth seeing while you read the chart. Do not treat it as a
signal until it is tested on a feed with real bid/ask volume.

### v1.10 changes (2026-09-13)

- **Time-of-day baseline** — `InpBaselineMode` (default **Time of day**). The volume Z-score
  and the impact baseline for a 14:00 bar come from the 14:00 bars of the previous
  `InpBaselineDays` (20) trading days, not from the last 200 bars of mostly thin Asian
  tape. Missing days (weekends, holidays) are skipped, never counted as zero. Fewer than
  `InpBaselineMinSamples` (10) → that bar falls back to the rolling window, and status
  line 2 counts how many did. Rolling is still selectable. The slot is the server clock, so
  around DST changes the session drifts one slot — not solved; the CSV flags those rows.
- **Tolerances** — `InpTolMode` (default **Points**, as before) / Price / Auto, logged the same
  way as the heatmap bucket.
- **HVN source** — `InpHvnSource` (default: the chart's own timeframe). M5 absorption
  filtered against **H1** shelves is supported; a *lower* timeframe logs a warning.
  An HVN set older than `InpHvnMaxAgeSec` (300 s), removed, or still warming is not
  fresh. With `InpRequireHVN` on, `InpHvnStaleAction` = **Block** (default) suppresses
  signals and shows **HVN STALE - SIGNALS BLOCKED** in red, with one log line (and one
  alert, if alerts are on) per transition. Pass lets them through, still marked.
- **Auto-tune** — `InpAutoTune`, default **off**. The timeframe factors are guesses.
  Important: `InpMinDeltaRatio` and `InpRangeMult` only gate **Classic**, and `InpMaxImpact`
  only gates **Impact** (factor 1.0 everywhere) — on Impact or Unusual it changes nothing.
- **Measure instead of guessing** — on attach the Experts log prints p50/p90/p95/p99 of
  delta ratio, price impact and range/ATR over the lookback, and what % of bars clear each
  current threshold.
- **Status lines** — (1) warnings, signals in lookback, per-day rate and days covered, last
  24 h, volume and aggressor source; (2) baseline mode, sample sizes, fallbacks, thresholds;
  (3) HVN source timeframe and state, tolerances in price.
- **CSV** — `InpLogCSV` (default off) appends to `MQL5\Files\OF_Absorption_<sym>_<tf>.csv`
  one row per bar that passes the detection method **while attached**, including bars the
  HVN filter rejected (`hvn_filter_passed` 0). No backfill, by design. Reattach never
  duplicates rows (it reads the newest timestamp in the file first); a changed header is
  refused rather than appended to.

**Speed warning (pre-existing, not new in v1.10):** every new bar re-reads the ticks of all
`InpLookbackBars` bars. On gold M5 at the default 400 the terminal already logged "indicator
is too slow, 5734 ms". **Do not raise `InpLookbackBars` to get a steadier per-day rate** — a
few thousand bars would stall the terminal for tens of seconds every bar. The fix is caching
closed bars' tick analysis; not done yet.

## OF_Sessions — sessions and their ranges

Shades Asia, London and New York, and draws each session's high and low.

Why it matters here: volume is not spread evenly through the day, so "heavy volume" means
something different at 3am Asia than at the New York open. The session boxes stop you reading
a thin Asian range as real participation. The session highs and lows are also the levels the
next session trades against — the Asian range is the classic pool London runs.

**Times are entered in GMT** and converted with `InpServerGMT`. Your broker is **GMT+3**,
measured from the volume curve (its peak sits at 17:00 server = 14:00 GMT, the NY open). If
you change broker, check this first — every box lands in the wrong place if the offset is wrong.

**The box fill is see-through** (v1.10). `InpFillOpacity` sets it: 15% by default, 0 hides the
fill, 100 makes it solid. MT5 rectangle objects can only be solid, so the fill is painted on a
transparent canvas behind the candles, and the edge and high/low lines stay normal objects.


## Honest limits

- **Delta on gold is inferred, not measured.** No CFD feed tells you which side was the
  aggressor. The tick rule is a decent proxy and it is what every MT5 orderflow tool
  does, but it is an estimate. Treat a delta reading as evidence, not as fact.
- **This is not a footprint chart.** A real footprint needs bid/ask volume per price
  per bar from an exchange. On this feed the honest equivalent is what is built here.
- **None of this is an edge on its own.** It is a way of seeing. The signal counting
  (`OF_AbsorptionStats`, not built yet) is what would turn absorption into something
  with a measured hit rate rather than a remembered one.

## Next

1. Run `OF_Probe` on Monday during the session — settles the liquidity-heatmap question.
2. If depth is real, build `OF_DomHeatmap.mq5`.
3. Tune absorption thresholds on a few live sessions.
4. Build `OF_AbsorptionStats.mq5` to measure whether the setup actually pays.
