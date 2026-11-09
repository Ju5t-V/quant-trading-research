# Gold breakout: partial profit + breakeven rebuild (NautilusTrader study)

Status (2026-09-16 10:45): complete. **No configuration passed** the dev gates or the Dukascopy
holdout (§4.6, §5). At Jerry's choice the delivered EA is his own exits at 1% risk, with the
rollover guard that step 5 added (§4.7, §6).

## 1. Question

Jerry's bot `PDH_PDL_Breakout M1.mq5` v2.0 places a buy stop at yesterday's high and a sell stop
at yesterday's low at 00:05 server time. It trades 2.0 lots with SL/TP of 1000 pts and a 100/50
trail. Jerry asked for a rebuild that:
- tests yesterday's high/low and the Asia-session high/low side by side
- exits with real stop and limit orders: partial profit, stop to breakeven, final 1:2 RR
- keeps both buy and sell
- wins more often and makes more profit
- is backtested in NautilusTrader, so MT5 keeps running his demo EAs

On 2026-09-15 Jerry added these improvements (plan v2):
- ATR-sized stops everywhere
- an earlier first target (0.5R)
- a trailing second half past 2R
- a Friday close
- recovery-mode sizing
- sells only in a downtrend
- a final check on Dukascopy real ticks

**The winner is decided on profit plus drawdown.**

## 2. Data

| Set | Source | Coverage |
|---|---|---|
| Dev B | MetaQuotes-Demo ticks (`copy_ticks_range`, local tick base) | 2019-01 → 2020-12, 54.8M ticks |
| Dev A | same | 2025-06 → 2026-09-15, ~140M ticks (from Dec 2025 the feed ticks ~6× faster) |
| Holdout C | **Dukascopy** ticks (datafeed bi5, price ÷ 1000) | 2021-01 → 2025-04, 234.9M ticks; Oct–Dec 2020 is warm-up |
| Bars | MT5 `copy_rates_range` | D1 2015 → 2026-09, M1 2018-01 → 2026-09 |

MetaQuotes serves ticks only from 2025-05-27, and no tester cache holds 2021–2025. That is why the
holdout uses a second feed.

**Dukascopy checks (`verify_duka.py`, run before any holdout backtest).**
- **Coverage.** All 29,158 market hours are present; 56 transient download failures were retried
  successfully. All 55 months are there, none below 30% of the median tick count. 2023 is thinner
  (median 2.9M ticks/month vs 4.3–5.1M), which is a feed-density change, not a gap.
- **Agreement with MetaQuotes daily bars on the same server days.** Median high/low differences are
  $0.09–0.26 and p95 is $0.21–0.87; 98–100% of days are within $1. The largest single-day difference
  is $12.97 (2023-05-04).
- **Clock rule.** 98.6% of weekday reopens land within 15 minutes of the Europe/Athens prediction
  (11 one-hour offsets).
- **Cleaning** removed only 3,634 of 234.9M quotes (0.002%). This feed has none of the 01:00 reopen
  spikes MetaQuotes shows in 2026.
- **Costs are higher than on the dev windows.** Median spreads are 33–39 pts in 2020–2024 and 54 pts
  in 2025, against 15–30 pts on MetaQuotes in 2025–26. The holdout is a tougher cost test.

**Server clock.** MetaQuotes-Demo runs EET/EEST (Europe/Athens DST rules).
- The live clock reads +3.000 h (Sep 2026).
- The daily reopen lands at 22:00 or 23:00 UTC, as New York DST dictates, on 95.4% of weekdays.
- The October 2020 US/EU mismatch week rules out a New-York-close clock.
- Exceptions are the March mismatch weeks of 2019/2020 and 3 days in March 2026, when the feed
  opened an hour late. This affects only the Asia window, on about 2.5% of days.

**Checks (`verify_data.py`).**
- Tick-built server-day bid high/low equals MT5's own D1 bars on 99.4–100% of days.
- The Asia window has the full 480 M1 bars on almost every weekday.

**Cleaning (`clean_ticks.py`, rule fixed before any strategy result).** A quote is dropped if either:
1. its spread is wider than max($3, 10 × that server day's median spread), or
2. its bid lies outside the broker's own M1 bar for that minute (MetaQuotes only).

What it removes, and why:
- **2019-02-27 02:56–03:02 server:** spreads of $10–$29, when the normal spread was $0.28. One broken
  quote filled both stop orders; later ones stopped four positions out.
- **Jul–Sep 2026, 01:00 server reopen:** the ask explodes for 20–40 s almost daily, up to **$149**.
- **Total:** 34,914 of 195.4M ticks (0.018%).
- **Kept:** March 2020 COVID spreads survive, because that month's daily medians were wide too.
- Raw ticks stay available (`--raw`), and the finalist is re-run on them.

**Fidelity check (Q1 2019, fixed-stop partial config).**

| Data | Win | PF | Net |
|---|---|---|---|
| Raw ticks | 45.6% | 0.80 | −7.1R |
| **Clean ticks** | 49.1% | 1.08 | +2.3R |
| M1 bars | 50.0% | 1.04 | +1.1R |

The raw-vs-bars gap was the 2019-02-27 glitch. Once it is removed, bars and ticks agree closely.

**Live-trading note.** The 01:00 reopen spikes are on the demo feed today. Any resting stop order
(entry or stop loss) can be filled by them on MT5. Orders armed before 01:00 server are the most
exposed.

## 3. Method

**Engine.**
- NautilusTrader 1.231.0 on L1 quote ticks, streamed in ≤1.5M-tick chunks.
- Hedging margin account. Cost is the recorded bid/ask spread (no commission on this feed).
- Stop orders are rejected if already in the market when placed, as in MT5.
- Scripted price paths (`test_orders.py`, 15 checks) verify every exit type. Per-trade P&L matches
  Nautilus's own position report to the cent.

**Strategy (`gold_level_breakout.py`).**

*Levels:*
- `PDH_PDL`: the previous server-day D1 high/low, armed at a server time. Unfilled orders expire at
  the next server midnight.
- `ASIA`: the M1 high/low for 00:00–08:00 UTC, armed at 08:00 UTC; orders expire 20:00 UTC.
- Arming waits while the spread is above 80 pts (as v2.0).

*Exits (all resting orders):*
- `ORIGINAL`: SL 1000 + TP 1000 + a trailing stop that activates at +100 pts and trails 50.
- `PARTIAL_BE`: SL on the full size at 1R; TP1 limit for 50%; TP2 limit for 50% at 2R. When TP1
  fills, the SL moves to the fill price + 10 pts.
  - Option `runner_mode=TRAIL`: TP2 is replaced by a trailing stop 1R behind price.
- `TRAIL_REF`: the GoldBreakoutEA v1.31 exit (SL 500 / TP 1000 / trail 300-150, ATR-scaled).

*Options:*
- `weekend_flat`: close everything Friday 22:30 server.
- `sell_filter`: sell stops only when yesterday closed below the D1 SMA(50).

*Sizing:* $100 risk per trade (1% of $10k), with results in R. Run 0a replays the exact 2.0 lots.

*Swap:* estimated from current MetaQuotes rates and reported, but not deducted.

**Plan v2 (fixed before any stage-1 result was read).**

ATR-sized 1R = 1000 pts × D1 ATR(14) ÷ 14,000 (clamped 0.1–2, floor 200 pts).

What this calibration means in each dev year. It was computed from D1 bars and tick spreads
before any step-2a result was read; the rule itself was not changed.

| Year | Median ATR | Median 1R | Days on the 200-pt floor | Median spread | Spread as % of 1R | Days sells allowed (SMA50 filter) |
|---|---|---|---|---|---|---|
| 2019 | $12.9 | $2.00 | 100% | 28 pts | 14% | 39% |
| 2020 | $27.4 | $2.00 | 54% | 25 pts | 12% | 28% |
| 2025 (Jun–Dec) | $56.1 | $4.00 | 0% | 17 pts | 4% | 12% |
| 2026 | $111 | $7.93 | 0% | 17 pts | 2% | 54% |

In 2019–20 the ATR stop sits on its $2 floor, and the spread costs 12–14% of every 1R. With the
fixed $10 stop it was 3–4%. Window B therefore carries a real cost handicap under this calibration.

| Step | Configs | Runs |
|---|---|---|
| 2a | 1A yesterday 00:05 · 2A Asia 08:00 UTC · 3A yesterday 06:00 — partial + BE, ATR stop | A, B |
| 2b | on the best base B*: E1 TP1 0.5R · E2 trail second half 1R · E3 Friday close · E4 sell filter · R reference | A, B |
| 2c | F = B* + every E that beat B* in both windows | A, B |
| 3 | +20-pt spread stress for gated configs; raw ticks for F and 0b | A, B |
| 4 | holdout on Dukascopy ticks: winner, 0b, R, run once | C |

**Metric: profit at equal drawdown.** Ratio = net R ÷ max drawdown R, per window.

**Gates, in each dev window:**
- net R > 0
- PF ≥ 1.3
- ratio ≥ the original's (0b)
- PF ≥ 1.1 with spreads +20 pts

**Winner:** F if gated; otherwise the gated config with the best min(ratio A, ratio B).

**Holdout pass:** PF ≥ 1.2, net R > 0, ratio ≥ 0b's.

**Recovery mode:** risk 0.1% while the last 10 closed trades are net negative. It is simulated on the
trade lists, compounding from $10k.

## 4. Results

### 4.1 Stage 1: reference runs (fixed $10 stop, clean MetaQuotes ticks)

| Config | Window | Trades | Win % | PF | Net R | Max DD R | Ratio | Buys R | Sells R | Median hold |
|---|---|---|---|---|---|---|---|---|---|---|
| 0b original, 1% | A | 318 | 86.8 | 1.45 | +15.2 | 4.2 | **3.60** | +14.9 | +0.3 | 0.3 min |
| 0b original, 1% | B | 485 | 87.0 | 0.79 | −12.6 | 24.3 | −0.52 | −4.9 | −7.7 | 24 min |
| 1 yesterday 00:05 | A | 318 | 49.7 | 0.97 | −5.1 | 28.0 | −0.18 | +17.9 | −23.0 | 28 min |
| 1 yesterday 00:05 | B | 484 | 49.4 | 0.96 | −10.1 | 33.4 | −0.30 | +36.8 | −46.9 | 858 min |
| 2 Asia 08:00 UTC | A | 376 | 51.9 | 1.03 | +5.2 | 29.3 | 0.18 | +13.8 | −8.7 | 38 min |
| 2 Asia 08:00 UTC | B | 651 | 51.0 | 1.05 | +17.8 | 24.8 | 0.72 | +57.3 | −39.5 | 1,192 min |
| 3 yesterday 06:00 | A | 216 | 54.2 | 1.15 | +15.0 | 17.7 | 0.85 | +15.9 | −0.9 | 37 min |
| 3 yesterday 06:00 | B | 373 | 51.5 | 1.06 | +11.0 | 17.4 | 0.63 | +36.0 | −25.0 | 887 min |

**What stage 1 shows:**

- **The original bot is regime-bound.**
  - 2025–26: +15.2R, PF 1.45, max DD only 4.2R.
  - 2019–20: −12.6R, PF 0.79, DD 24.3R.
  - Its 87% "wins" average +0.11–0.18R, while a loss costs −0.81 to −0.95R.
- **The exact bot (0a, 2.0 lots from $10k) is not survivable.** Its equity falls below zero on
  **2019-11-05**, and MT5 would have rejected 295 of its 485 fills for margin. In 2025–26 it had no
  margin problem.
- **Partial profit + breakeven with a fixed $10 stop is not convincing.**
  - PF ranges 0.96–1.15.
  - Every yesterday-level variant loses money in 2026.
  - In 2019–20 trades are held 14–20 h (median), about half overnight, with estimated swap of
    −5.6 to −10.8R.
- **Sells lose in every config and window (−0.9 to −46.9R); buys earn in every one (+13.8 to +57.3R).**
- **Arming at 06:00 beats 00:05 in both windows:** +15.0 vs −5.1R, and +11.0 vs −10.1R.
- **Recovery mode on the original (compounding from $10k):**
  - 2019–20: loss cut from −12.1% to −2.2%, drawdown from 21.8% to 9.5%.
  - 2025–26: return drops from 16.1% to 13.8%, drawdown from 4.2% to 3.7%.
- **The original's 2025–26 ratio of 3.6 is the bar every plan-v2 candidate must reach in window A.**

### 4.2 Step 2a: ATR-sized stops

| Config | Window | Trades | Win % | PF | Net R | Max DD R | Ratio | Buys R | Sells R | Median 1R | Spread % of 1R | Median hold |
|---|---|---|---|---|---|---|---|---|---|---|---|---|
| 1A yesterday 00:05 | A | 318 | 55.3 | 1.23 | +31.7 | 22.8 | 1.39 | +28.7 | +3.0 | 659 pts | 5.2 | 7 min |
| 1A yesterday 00:05 | B | 485 | 45.4 | 0.73 | −76.4 | 101.6 | −0.75 | −34.0 | −42.4 | 200 pts | 17.0 | 21 min |
| 2A Asia 08:00 UTC | A | 376 | 51.1 | 0.97 | −6.7 | 32.2 | −0.21 | −5.8 | −0.9 | 658 pts | 3.0 | 14 min |
| 2A Asia 08:00 UTC | B | 652 | 46.9 | 0.78 | −82.0 | 93.5 | −0.88 | −11.8 | −70.2 | 200 pts | 13.5 | 26 min |
| 3A yesterday 06:00 | A | 216 | 54.6 | 1.23 | +21.6 | 18.9 | 1.14 | +9.1 | +12.5 | 649 pts | 3.5 | 10 min |
| 3A yesterday 06:00 | B | 374 | 44.4 | 0.72 | −63.1 | 76.7 | −0.82 | −40.6 | −22.5 | 200 pts | 14.0 | 21 min |

By year:
- **1A:** 2025 +40.9R (PF 1.76), 2026 −9.2R (0.89), 2019 −23.4R, 2020 −53.0R.
- **3A:** 2025 +32.7R (1.78), 2026 −11.2R (0.82), 2019 −17.1R, 2020 −46.0R.
- **2A:** 2025 +0.5R, 2026 −7.2R, 2019 −55.6R, 2020 −26.4R.

What 2a shows:
- **ATR sizing fixed the hold problem.** Trades last minutes, and about 1% cross midnight, where the fixed stop in 2019–20 held 47–58% overnight.
- **It also exposed the cost handicap flagged in §3.** In 2019–20 the stop sits on its $2 floor and the spread costs 13–17% of every 1R. All three variants lose −63 to −82R there.
- **2025 was strong and 2026 weak for every variant.**

**B\*** = 1A: the best min(ratio A, ratio B), at −0.75 vs 3A −0.82 and 2A −0.88.

### 4.3 Step 2b: one improvement at a time on B\* (yesterday's levels, 00:05, ATR stop)

| Config | Ratio A | Ratio B | Net R A | Net R B | PF A | PF B | Win % A | Win % B | Notes |
|---|---|---|---|---|---|---|---|---|---|
| B\* = 1A | 1.39 | −0.75 | +31.7 | −76.4 | 1.23 | 0.73 | 55.3 | 45.4 | |
| E1 first target 0.5R | **4.80** | −0.95 | +36.2 | −93.1 | 1.45 | 0.57 | **72.3** | 55.9 | Max DD A 7.5R; 2025 +27.3R, 2026 +8.9R |
| E2 trail second half 1R | 1.42 | −0.82 | +31.9 | −82.2 | 1.24 | 0.71 | 55.3 | 45.4 | 166 / 193 runner trail exits |
| E3 Friday close 22:30 | 1.39 | −0.75 | +31.7 | −75.3 | 1.23 | 0.74 | 55.3 | 45.5 | No effect: trades close within minutes |
| E4 sell only below SMA50 | 0.47 | −0.69 | +10.7 | −51.5 | 1.11 | 0.75 | 52.4 | 46.5 | Sells A −18.1R (base +3.0R); B −17.5R (base −42.4R) |
| R v1.31 trail exit (reference) | **4.93** | −0.86 | +46.8 | −84.8 | 1.38 | 0.70 | 65.7 | 49.3 | Positive in 2025 (+28.7R) and 2026 (+18.1R) |

### 4.4 Step 2c verdict

- **No improvement beat B\* in both windows**, so F = 1A and there are no new runs.
- **No config passes the dev gates.** Every window-B result is negative.
- **So far there is no winner.**

In the 2025–26 regime, two exits clearly beat the original bot's profit-per-drawdown ratio (3.60):
- the earlier first target (E1): 4.80, with a 72% win rate
- the v1.31 trail exit (R): 4.93

Both collapse in 2019–20, where the $2 floor stop cannot cover the spread. The plan requires both windows, so neither is selected.

Steps 3 (stress and raw ticks) and 4 (Dukascopy holdout: F, 0b, R) run as planned, for information.

### 4.5 Step 3: wider spreads and uncleaned ticks

| Run | Window | Trades | Win % | PF | Net R | Max DD R | vs clean |
|---|---|---|---|---|---|---|---|
| F = 1A, spread +20 pts | A | 317 | 54.3 | 1.16 | +23.3 | 23.3 | −8.4R |
| F = 1A, spread +20 pts | B | 483 | 42.2 | 0.67 | −98.7 | 116.2 | −22.3R |
| F = 1A, uncleaned ticks | A | 325 | 50.2 | 0.49 | −174.1 | 226.1 | **−205.8R** |
| F = 1A, uncleaned ticks | B | 485 | 45.2 | 0.70 | −87.2 | 101.6 | −10.9R |
| 0b original bot, uncleaned ticks | A | 325 | 79.1 | 0.25 | −139.9 | 157.2 | **−155.1R** |
| 0b original bot, uncleaned ticks | B | 485 | 86.8 | 0.75 | −15.5 | 24.3 | −3.0R |

**Spread stress.** Adding 20 points cuts F's 2025–26 result from +31.7R to +23.3R. Its PF of 1.16 clears the 1.1 stress floor. By year, 2025 made +33.8R and 2026 −10.5R. In 2019–20 the loss deepens to −98.7R (PF 0.67). F had already failed the dev gates, so this changes nothing.

**The 01:00 reopen spikes are the biggest single risk found in this study.** On the uncleaned Jun 2025 – Sep 2026 feed:
- **F:** 72 trades filled more than $1 beyond their order price, costing −176.6R. 47 of them were entered between 00:00 and 01:59 server (−177.3R).
- **The original bot (armed at 00:05):** 70 such trades cost −142.5R, 45 of them entered 00:00–01:59 (−144.5R). Its clean +15.2R becomes −139.9R.
- **Worst single trades:**
  - 2026-08-17 01:00: a sell stop at 4310.73 filled at 4276.43 and was closed at 4415.62 (−19.1R).
  - 2026-09-02 01:00: a buy stop at 4461.33 filled at 4469.17 and was closed at 4320.26 (−18.1R at F size, −14.9R for the original).
- **2019–20 is barely affected** (−3 to −11R), so the spikes are a 2026 behaviour of this feed.

**Implication for any EA on this feed.** Pending stop orders and protective stops that are live across 01:00 server can fill $10–150 away from the market. MT5's real-tick tester replays these same ticks, and a live broker may show the same rollover behaviour. A **rollover guard** is strongly indicated, whatever the exit: no pending orders from about 00:55 to 01:15 server, and arming only after the reopen. It was not one of Jerry's plan-v2 picks, so it is **recommended but untested**.

### 4.6 Step 4: Dukascopy holdout, Jan 2021 – Apr 2025 (run once)

As planned, F (= 1A), 0b and R each ran once on the clean Dukascopy ticks: 222.8M quotes over 1,116
trading days. Every run had 1,053 fills: 2,232 orders placed, 1,143 expired unfilled, and 36 rejected
because price was already beyond the level when placed.

| Run | Trades | Win % | PF | Net R | Max DD R | Ratio | Buys R | Sells R | Median 1R | Spread % of 1R | Worst losing streak |
|---|---|---|---|---|---|---|---|---|---|---|---|
| 0b original bot, 1% | 1,053 | 89.0 | 1.06 | +6.6 | 10.2 | 0.64 | +4.3 | +2.3 | 1000 pts | 5.7 | 2 |
| F = 1A partial + BE, ATR stop | 1,053 | 47.3 | 0.77 | −135.5 | 140.0 | −0.97 | −57.3 | −78.1 | 200 pts | 26.0 | 11 |
| R v1.31 trail exit | 1,053 | 51.8 | 0.80 | −115.0 | 117.3 | −0.98 | −50.9 | −64.1 | 200 pts | 28.5 | 9 |

**Holdout pass for F (information only, since there was no winner).**
- PF 0.77, needed ≥ 1.2: fail.
- Net R −135.5, needed > 0: fail.
- Ratio −0.97, needed ≥ 0b's 0.64: fail.

R fails all three as well.

By year (net R, with PF in brackets):

| Year | 0b original, 1% | F = 1A | R |
|---|---|---|---|
| 2021 | −2.4 (0.92) | −39.6 (0.72) | −29.3 (0.78) |
| 2022 | +6.1 (1.27) | −17.8 (0.86) | −17.8 (0.86) |
| 2023 | −3.4 (0.89) | −51.0 (0.65) | −33.7 (0.75) |
| 2024 | +4.9 (1.20) | −26.3 (0.81) | −26.4 (0.80) |
| 2025 Jan–Apr | +1.3 (1.21) | −0.7 (0.98) | −7.8 (0.79) |

What the holdout shows:
- **The original bot is about break-even on a second feed.** It made +6.6R in 4.3 years, with small losing and winning years alternating. Wins average +0.13R and losses −0.99R. With a fixed $10 stop, the spread is only about 6% of 1R.
- **Both ATR-stop designs lose in every year.** The 1R sat on its 200-pt ($2) floor on most days: F's median was 200 pts in 2021–23 and 237–281 pts in 2024–25. The spread at arming was 24–29% of 1R. This is window B's cost handicap again, now across 4.3 more years and on a different feed.
- **Across all three windows, the ATR designs made money only in Jun 2025 – Sep 2026**, when gold's daily ATR was $56–111. Even inside that window, F lost in 2026.
- **Sells lost more than buys** for both ATR designs, as in the earlier windows.
- **The market-close fallback exits were legitimate** (11 F trades, −7.0R in total):
  - 8 entries slipped past 1R. TP1 filled at once, and the breakeven stop was already in the market.
  - 3 were news or headline gaps where the stop loss was already crossed when placed (2024-06-12 15:30, 2025-02-07 15:30, 2025-04-03 01:07). They closed at −1.2 to −1.5R (−1.5 to −1.8R for R).
- **A lead, not a result: entries at the reopen were the weakest bucket for the ATR designs, even on this spike-free feed.**
  - Entries from 00:00–01:59 server made PF 0.49 for F and 0.47 for R, against 0.76–1.23 at other hours.
  - In window B the same bucket made PF 0.45–0.67 for all three configs.
  - This breakdown was examined after scoring, so it has no holdout confirmation.

**Recovery mode.** Compounding from $10k at 1% risk, dropping to 0.1% while the last 10 closed trades are net negative:

| Run | Window | Fixed 1%: return / max DD | Recovery: return / max DD | Trades at reduced risk |
|---|---|---|---|---|
| 0b | A | +16.1% / 4.2% | +13.8% / 3.7% | 128 of 318 |
| 0b | B | −12.1% / 21.8% | −2.2% / 9.5% | 281 of 485 |
| 0b | C | +6.0% / 9.9% | +0.3% / 9.2% | 582 of 1,053 |
| F = 1A | A | +34.8% / 20.8% | +14.3% / 9.7% | 180 of 318 |
| F = 1A | B | −54.8% / 64.5% | −0.4% / 20.4% | 382 of 485 |
| F = 1A | C | −75.7% / 76.8% | −34.3% / 34.4% | 875 of 1,053 |
| R | A | +57.0% / 9.1% | +23.4% / 6.3% | 165 of 318 |
| R | B | −58.4% / 63.5% | −15.2% / 21.2% | 407 of 485 |
| R | C | −70.1% / 70.7% | −14.4% / 18.3% | 783 of 1,053 |

- **Plan rule:** recovery mode becomes the EA default only if it cuts max DD % in both dev windows without lowering return ÷ max DD % in either.
- **Result:** drawdown fell everywhere, but return ÷ DD fell in window A for all three (0b 3.84 → 3.77, F 1.67 → 1.48, R 6.26 → 3.74).
- **So it is not the default.** It limits damage in losing periods and gives up profit in winning ones.

### 4.7 Step 5: the rollover guard (added after the holdout, at Jerry's request)

Jerry chose his original exits at 1% risk as the EA default and asked for the rollover guard to be
tested first. **G** is that exact config with its orders placed at **01:15 server** instead of 00:05,
i.e. after the 01:00 reopen. Dev windows only — the holdout was spent at step 4.

| Run | Data | Trades | Win % | PF | Net R | Max DD R | Ratio | Big-slip trades |
|---|---|---|---|---|---|---|---|---|
| 0b arm 00:05 | A clean | 318 | 86.8 | 1.45 | +15.2 | 4.2 | 3.60 | 50 (+2.3R) |
| **G arm 01:15** | A clean | 290 | 88.3 | 1.51 | +15.0 | 4.2 | 3.62 | 29 (+2.4R) |
| 0b arm 00:05 | B clean | 485 | 87.0 | 0.79 | −12.6 | 24.3 | −0.52 | 32 (−6.9R) |
| **G arm 01:15** | B clean | 462 | 87.7 | 0.81 | −10.9 | 21.5 | −0.51 | 22 (−5.8R) |
| 0b arm 00:05 | A **uncleaned** | 325 | 79.1 | 0.25 | **−139.9** | 157.2 | −0.89 | 70 (−142.5R) |
| **G arm 01:15** | A **uncleaned** | 290 | 88.3 | 1.51 | **+15.0** | 4.2 | 3.62 | 29 (+2.4R) |
| 0b arm 00:05 | B uncleaned | 485 | 86.8 | 0.75 | −15.5 | 24.3 | −0.64 | 34 (−10.8R) |
| **G arm 01:15** | B uncleaned | 462 | 87.4 | 0.77 | −13.9 | 21.5 | −0.64 | 24 (−9.8R) |

- **On clean ticks the guard costs nothing.** 2025–26: +15.0R against +15.2R, with a better PF (1.51 vs 1.45) and the same 4.2R drawdown. 2019–20: −10.9R against −12.6R, with drawdown 21.5R against 24.3R. The win rate rises in both windows (86.8 → 88.3 and 87.0 → 87.7).
- **On uncleaned ticks it removes the whole spike exposure:** 2025–26 goes from −139.9R to +15.0R.
- **The guarded 2025–26 run is identical on clean and uncleaned ticks, to the decimal.** That is the mechanism confirming itself: trades last 0.3 min (median) and orders expire at midnight, so nothing is armed or open across 01:00 and the spike quotes never touch the strategy.
- **It trades less:** 28 fewer trades in A and 23 in B, because by 01:15 price has already passed the level more often (sides skipped: 6 → 35 in A, 9 → 31 in B).
- **It does not create an edge.** 2019–20 still loses (−10.9R), and 2025–26 still rests on the same regime.
- **Dev-window evidence only.** The holdout was spent at step 4, so the guard has no independent confirmation. It is a risk control against a documented feed defect, not a new edge.

**Decision: 01:15 server becomes the EA's default arm time.**

## 5. Verdict

**No configuration passed.** Nothing cleared the dev gates. On untouched Dukascopy data (2021 – Apr 2025), both improved exits lost money in every year.

| Idea | What the tests showed |
|---|---|
| Partial profit + breakeven, final 1:2 | Fixed $10 stop: PF 0.96–1.15 (stage 1). ATR stop: profitable only Jun–Dec 2025; lost in 2019–2024 and in 2026 |
| Asia-session levels | Worse than yesterday's levels with ATR stops (−6.7R / −82.0R). Fixed stop: PF 1.03–1.05 |
| Earlier first target (0.5R) | 72% win rate and ratio 4.80 in 2025–26, but −93.1R in 2019–20 |
| Trail the second half | Almost no change (ratio A 1.42 vs 1.39; B −82.2R vs −76.4R) |
| Friday close | No effect: trades close within minutes |
| Sells only in a downtrend | Helped 2019–20 (−51.5R vs −76.4R), hurt 2025–26 (+10.7R vs +31.7R) |
| Recovery-mode sizing | Cuts drawdown everywhere and cuts profit in 2025–26; not a default by the plan rule |

**Why partial + breakeven fails here.** Every stop-out costs a full 1R plus the spread, and the first half banks only after a full 1R move. That trade-off needs costs that are small next to 1R. At a $2 stop, the spread takes 13–29% of every 1R. The design worked only when gold's daily range was about $50 or more.

**What the study supports for any version of this bot:**
1. **Size by risk, not fixed lots.** 2.0 lots from $10k went below zero on 2019-11-05 (0a).
2. **Keep resting orders away from the 01:00 server reopen on MetaQuotes feeds.** Reopen spikes turned the original's +15.2R into −139.9R on uncleaned 2025–26 ticks. Arming at 01:15 instead of 00:05 removes that exposure completely and costs nothing on clean ticks (§4.7), so it is now the EA default — on dev-window evidence only.
3. **Expect the original exits to be about break-even outside a high-volatility regime:** −12.6R in 2019–20, +6.6R in 2021 – Apr 2025, and +15.2R in Jun 2025 – Sep 2026.

## 6. MQ5 EA

`mq5/GoldBreakout_PartialBE.mq5` v3.20 compiles with 0 errors and 0 warnings and is delivered to
`C:\Users\V\Downloads\GoldBreakout_PartialBE.mq5`.

**Defaults (Jerry's choice, 2026-09-16): his own exits at 1% risk, with the rollover guard.**

| Input | Value | Why |
|---|---|---|
| `InpExitMode` | `EXIT_TRAIL` | The only setup that did not lose on the holdout (0b) |
| `InpAtrScaling` | `false` | 0b uses the fixed 1000-pt stop |
| `InpStopLossPts` / `InpTakeProfitPts` | 1000 / 1000 | As v2.0 |
| `InpTrailStartPts` / `InpTrailDistPts` | 100 / 50 | As v2.0 |
| `InpAutoLot` / `InpRiskPercent` | `true` / 1.0 | 2.0 fixed lots went below zero in 2019 (§4.1) |
| `InpArmHour` / `InpArmMinute` | 1 / 15 | Rollover guard (§4.7) |
| `InpLevelMode` | `LEVELS_PREV_DAY` | Asia levels were not better (§4.2) |
| `InpSellTrendFilter` | `false` | Helped 2019–20, hurt 2025–26 (§4.3) |
| `InpFridayClose` | `false` | No effect (§4.3) |
| `InpRecoveryMode` | `false` | Fails the plan rule (§4.6); switch it on to trade smaller after losses |

**Parity with the backtest**, checked line by line for the trail exit: one order per side; stop and
target at the level ∓/± 1000 pts (`price=mk(level_px + s * tp_px)` in the strategy); the trail arming
at +100 pts from the entry price and then following 50 pts behind; and the same ATR floors
(200/400/150/80) as `gold_level_breakout.py` when scaling is switched on.

The other tested designs are still reachable from the inputs:
- **Partial profit + breakeven (1A):** `InpExitMode = EXIT_PARTIAL_BE`, `InpAtrScaling = true`.
- **v1.31 trail exit (R):** `InpExitMode = EXIT_TRAIL`, `InpAtrScaling = true`, SL 500, TP 1000, trail 300/150.

**Neither passed the study's gates, and the delivered default did not either** — it was about
break-even on 2021 – Apr 2025. Demo only.
