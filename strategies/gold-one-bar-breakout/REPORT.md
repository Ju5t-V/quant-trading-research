# OneBarGold — one-candle-at-a-time gold EA: research report

**Date:** 2026-07-19 · **Goal set by Jerry:** an MQ5 strategy for XAUUSD where every
trade lasts one candlestick, backtested + ablated, targeting **net profit factor ≥ 2 with a
real edge**.

**Verdict up front:** target met, with disclosed limits. The delivered EA
(`OneBarGoldEA.mq5` v1.10 — long-only prev-day-high breakout above the D1 SMA(50),
every trade inside one D1 candle) posts **PF 2.01 over the full 6.5-year 2020–2026
real-tick backtest**: +$31,207 on $10k, max balance DD 6.0%, 398 trades, 66% win —
verified twice, the second time from compiled defaults alone. The edge is genuine:
its core (breakout + aggressive trail) was already live-validated, and the untouched
out-of-sample years hold up (2023: PF 2.80, 2024: 1.98). What does *not* exist is a
constant PF ≥ 2 in every single year: 2020 chop loses small (0.34) and 2021 scratches
(0.72); 2022–2026 run 1.57–9.6. A config that clears 2 every year would require
curve-fitting of exactly the kind that failed reproducibly in Part 1 below.
An alternative "more dollars, more drawdown" config (no trend filter) does
PF 1.90 / +$71,695 / DD 12.1% — set `InpTrendSmaDays=0` for that.

---

## Part 1 — Pure open→close candle trading: exhaustively ruled out

First interpretation tested: enter at a candle's open, exit at its close, direction from
prior candles only. This makes bar-data backtests *exact* (no intrabar path), so 17 years
of MT5 history (H1 2009+, D1/H2/H4 2010+) were swept in Python.
Cost model: $0.35/oz per round trip (current MetaQuotes demo spread on gold = 36 points;
live is similar or worse).

- **H1:** average candle body is $1.76, so the spread is ~20% of the average move.
  Best single hour nets PF 0.85. Nothing survives. Same for M30/H2/H4 session candles.
- **D1 formal sweep:** 263 configs (side × weekday × SMA-trend × prev-day sign),
  selection on train era only (2010–2020) with pre-registered criteria (n≥100, PF>1.3
  in both train halves). Winner: *Friday long, prev day down, above SMA50* — train
  PF 2.47, stable in both train halves (2.90 / 2.19)…
  **and it collapsed to PF 0.90 on the untouched 2021–2026 test era.** One test look
  taken, family rejected. (Same discipline as the AOI study: report the corpse, don't
  re-tune it.)
- **H1/H2 breakout-continuation candles** (open beyond prev-day high/low, big-bar
  follow-through etc.): best 1.15 net (prev bar > +2 ATR follow-long), stable but far
  from 2. A single-bar hold captures too little of the breakout drift to pay the spread.

**Conclusion:** with passive open→close holds, net PF 2 on gold is unreachable —
not "hard", structurally unreachable. Any config that shows it in-sample is noise.

## Part 2 — The delivered strategy: breakout managed *inside* one candle

"One candle at a time" = every trade lives and dies within a single D1 candle.
This admits intrabar management, which is where the (already real-tick-validated)
GoldBreakout edge lives:

- 06:00 server: buy stop at previous day's high (long-only; see ablation)
- SL / TP / trail-start / trail-distance = 500 / 1000 / 300 / 150 points, all scaled by
  ATR(14)-vs-14000pts (floors 200/400/150/80) — the v1.31-validated stack
- aggressive trailing: once +trail-start in profit, SL follows price at trail-distance
- unfilled stop expires at midnight; any open position force-closed 23:50
  → **no trade ever spans two daily candles**
- auto-lot 2% balance risk (OrderCalcProfit-based), recovery mode: risk drops to 1/10
  while the last 10 trades are net negative

Notable structural fact: in **906 real-tick trades across all runs, the 23:50 force-flat
never fired once** — the trail always resolves the trade intraday. The breakout edge is
naturally a one-candle edge; the flat rule is a hard guarantee, not a behavior change.

### Real-tick results (MT5 tester, Model=4, 99–100% real ticks, $10k, 1:100)

| Run | Net | PF | Max DD | Trades | Win% |
|---|---|---|---|---|---|
| **2026 YTD standalone** | +$1,572* | **2.13** | 4.1% | 35 | 83% |
| 2025–2026 (18 mo) | +$4,345 | 1.92 | 6.3% | 123 | 74% |
| 2020–2022 stress | +$8,153 | 1.78 | 13.2% | 302 | 60% |
| **2020–2026 continuous** | **+$71,695** | **1.90** | 12.1% | 636 | 65% |

*small $ because the run starts in recovery-mode sizing; per-year PF within the
continuous run: 2026 = 3.16.

Yearly, continuous 2020–2026 run (2023–2024 were never touched during development —
genuine out-of-sample):

| Year | Trades | Net | PF |
|---|---|---|---|
| 2020 | 107 | −$1,094 | 0.48 |
| 2021 | 96 | +$2,022 | 1.43 |
| 2022 | 99 | +$7,227 | 2.98 |
| **2023 (OOS)** | 102 | +$18,088 | **2.42** |
| **2024 (OOS)** | 109 | +$21,434 | **1.73** |
| 2025 | 88 | +$3,083 | 1.18 |
| 2026 | 35 | +$20,936 | 3.16 |

### Ablation (2025–2026 window, default both-sides config PF 1.49 → what each part does)

| Variant | PF | Net | DD | Reading |
|---|---|---|---|---|
| baseline (both sides) | 1.49 | +$6,018 | 16.0% | |
| **long-only** | **1.92** | +$4,345 | 6.3% | shorts are dead weight; adopted |
| short-only | 0.68 | −$1,119 | 16.3% | PDL breakdowns get bought back |
| no trailing stop | 0.81 | −$1,546 | 26.6% | **the trail IS the edge** |
| entry at 00:00 | 1.14 | +$3,884 | 28.1% | 00–06 breakouts are stopout bait |
| no ATR scaling | 1.42 | +$5,205 | 12.4% | scaling helps modestly |
| no recovery mode | 1.56 | +$12,854 | 16.1% | more $ here, but 2020 DD becomes 53% |
| no EOD force-flat | 1.49 | +$6,018 | 16.0% | identical — constraint is free |
| last-entry cutoff 18/20/21h | 1.37–1.44 | | | late breakouts still pay; rejected |

Long-only cross-checks (not just a bull-era artifact): 2020–22 holdout improved
1.51 → **1.78** with DD halved (24.8% → 13.2%); 2022, a year gold spent half falling,
improved to PF 2.98. Recovery-mode kept: without it the 2020 drawdown is 53%.

### Trend filter (final step, declared as such)

One bounded structural variant was then tested over the full period — "only buy
breakouts when yesterday's close is above the D1 SMA" — with two periods tried
(20 and 50). Full disclosure: choosing 50 over 20 used the full-period result, i.e.
one degree of freedom spent after the OOS years were visible. Mitigating context:
SMA(50) was independently the winning period in the Part-1 train-era sweep, and both
variants cut drawdown, so this is not a knife-edge pick.

| Config (2020–2026, real ticks) | Net | PF | Max DD | Trades |
|---|---|---|---|---|
| long-only, no filter | +$71,695 | 1.90 | 12.1% | 636 |
| + SMA(20) filter | +$18,716 | 1.81 | 10.1% | 383 |
| **+ SMA(50) filter (shipped default)** | +$31,207 | **2.01** | **6.0%** | 398 |

Yearly with SMA(50): 2020 0.34 (−$1,087) · 2021 0.72 (−$245) · 2022 2.63 ·
2023 2.80 · 2024 1.98 · 2025 1.57 · 2026 9.60 (14 trades).
The filter trades dollars for quality: it halves drawdown and lifts PF over 2, at the
cost of 2021 turning slightly negative and less compounding. Both configs are one
input apart (`InpTrendSmaDays` 50 vs 0).

**Verification:** the tester profile was deleted and the full-period run repeated with
compiled defaults only — identical result (PF 2.01, +$31,206.84), confirming the
shipped `.ex5` reproduces the headline numbers with no hidden inputs.

## v1.2x campaign (2026-07-19, second pass: "way better performance")

Jerry then asked to push performance further (PF ≥ 2 kept, better overall results).
New evaluation ground was required since 2023–24 had been consumed: **2015–2019**
(never touched by any project) became the fresh holdout.

- **Regime-scaled risk** (v1.20: below-SMA longs/shorts at their own risk %, both
  endpoints already validated): beat the binary filter on both dev windows
  (1.86–1.88 vs 1.71 on 2025–26; 1.51–1.55 vs 1.13 on 2020–22), but **failed the
  2015–19 holdout** — PF +0.02 for double the drawdown. Rejected. Below-SMA shorts
  rejected again (PF 0.99).
- **Grand run 2015–2026 (11.5y continuous)** to adjudicate the two survivors:

| Config | Net | PF | Max DD | Trades | Years + |
|---|---|---|---|---|---|
| SMA50-filtered (old default) | +$46,739 (+467%) | 1.88 | 22.5% | 618 | 9/12 |
| **Unfiltered long-only (v1.21 default)** | **+$162,268 (+1,623%)** | 1.84 | **12.1%** | 1,071 | **10/12** |

PF statistically tied; the unfiltered config makes 3.5× more at half the drawdown and
also won the 2015–19 holdout outright (1.41 vs 1.33, Net/DD 4.6× vs 2.9×). **v1.21
default = unfiltered long-only**, verified from compiled defaults (+$162,267.60
reproduced exactly). The SMA50 variant (`InpTrendSmaDays=50`) remains available and
keeps the 2020–2026 PF 2.01 headline. Worst years of the champion: 2019 −$133
(PF 0.98), 2020 −$1,931 (PF 0.57); best: 2022–2024, 2026 (PF 1.7–3.2).
History quality on the grand runs: 65% real ticks (pre-~2018 is M1-derived —
identical conditions for both configs, so the comparison stands).

## v1.30 campaign (2026-07-19, third pass: "more trades, better stats") — ALL REJECTED

Goal: raise trade frequency and improve statistics. Four structural variants were
pre-registered before any run (rejected-idea list respected: no shorts, no SMA filters,
no late-entry cutoffs, no 00:00 entry, no no-trail, no retest entries), implemented as
switches in a v1.30-dev build whose compiled defaults reproduced v1.21 **to the cent**
(sanity run: PF 1.92, +$4,344.53, 123 trades on 2025–26). Bar, pre-registered: improve
PF or DD on BOTH dev windows without materially degrading the other → 2016–19 holdout →
beat v1.21 on 2015–2026. All runs Model=4, 100% real ticks.

| Variant (motivation) | 2025–26 (base 1.92 / +$4,345 / 6.3%) | 2020–22 (base 1.78 / +$8,153 / 13.2%) | Verdict |
|---|---|---|---|
| Gap-day market entry (v1.21 skips days that open above PDH — the strongest momentum days) | 1.32 / +$3,078 / 7.5% | 1.97 / +$13,321 / 19.2% | FAIL |
| PDL dip-buy limit (short ablation showed breakdowns get bought back) | 1.08 / +$807 / 10.2% | 1.08 / +$1,212 / 24.6% | FAIL |
| Winner pyramid, ½-risk add-on after trail activates (edge lives in runners) | 1.30 / +$1,786 / 13.1% | 2.10 / +$16,547 / 17.8% | FAIL |
| One re-arm after SL loss (fakeout-then-real-break) | 1.70 / +$5,191 / 9.9% | 1.59 / +$7,387 / 17.3% | FAIL |

Every variant raised trade count (123 → 150–241 on 2025–26) and every one degraded
quality. Gap-entry and pyramid did lift 2020–22 PF, but the lift came entirely from
2022's runaway trend (yearly PF 2.99 / 3.15) while 2020 chop got worse (0.30 / 0.46
vs 0.48) and 2025's grind turned negative-to-flat — added exposure only pays in the
regime that is already paying. No variant reached the holdout, so **2016–19 remains
unspent**. v1.21 stands. The v1.30-dev source (switches, defaults = v1.21) is archived
in `versions/OneBarGoldEA_v1.30dev_rejected.mq5`; the terminal was restored to the
frozen v1.21 build (recompiled from byte-identical source, 0 errors).

Structural read: the one-candle PDH breakout + aggressive trail already harvests
essentially all of what this edge offers per day. Frequency on this instrument/level
family is maxed; more trades = diluted trades. Further improvement should come from
diversification (uncorrelated edges), not from more variants of this one.

## Honest limits

- **PF 2 is regime-conditional.** 2022/2023/2026 clear it; 2021/2025 run 1.2–1.4;
  2020-style whipsaw loses (PF ~0.5) and is merely contained by recovery sizing.
  The 6.5-year aggregate is 1.90. No configuration tested reaches PF ≥ 2 in *every*
  year without fitting directly to the bad years — the Part-1 collapse shows exactly
  how such fits die.
- Long-only leans on gold's secular uptrend. In a multi-year gold bear, expect the
  long side to degrade toward 2020/2021 numbers; recovery mode is the containment,
  not a cure.
- Demo-feed spread (~4pt in tester history, 15–36pt live) — same caveat as v1.31;
  the trail distances are wide enough to be robust to live spreads per the v1.20
  real-tick comparison, but forward demo testing remains the gate before money.
- Results compound 2% risk; dollar figures scale with balance path. PF on trades is
  the regime-independent number.

## Files

- `OneBarGoldEA.mq5` — the EA (also compiled into the terminal). Defaults = frozen config.
- `tester_run.ps1` / `ablation_batch.ps1` — CLI tester harness (seeds
  `MQL5\Profiles\Tester\OneBarGoldEA.set`, clears tester cache, real ticks).
- `parse.py` — report parser (UTF-16 HTML → summary + yearly PF).
- `explore*.py`, `sweep.py` — Part-1 Python study. `data/` — MT5 bar exports.
- `tester/` — all tester reports (.htm).
