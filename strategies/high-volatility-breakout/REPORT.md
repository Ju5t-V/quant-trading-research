# HighVol_Breakout — PF 2.5 hunt on a high-liquidity/high-volatility pair

**Date:** 2026-07-19 · **Goal set by Jerry:** same methodology as OneBarGold
(systematic sweeps, train/dev vs holdout separation, real-tick MT5 validation,
ablation — note: not machine learning, and none was used), on a high-liquidity /
high-volatility instrument, targeting **net PF ≥ 2.5**.

**Verdict up front: PF 2.5 does not exist honestly in this strategy family, on any
instrument tested.** The candidate pair (silver) produced PF 1.44 on its best
development window and then **failed the untouched 2023–24 holdout at PF 0.78** and
breakeven (1.04) over the full 6.5 years. The dev-window number was a bull-market
artifact — precisely the kind of result the methodology exists to catch. For
comparison, gold — the best instrument found so far — tops out at a true PF ≈ 1.9–2.0
across 6.5 years. Recommendation at the end.

## 1. Instrument selection (data-driven)

Scanned 25+ liquid symbols on MetaQuotes-Demo for daily ATR and ATR-to-spread ratio:

- Highest raw volatility: **XAGUSD 6.4%/day**, XPT 4.8%, XAU 2.7%; FX majors 0.4–0.9%.
- Best vol-to-cost: EURCAD 345×, EURJPY 332×, CHFJPY 304×, XAUUSD 297×; XAGUSD 76×.
- Python screen of the gross breakout→EOD drift (the effect the EA harvests), train
  era <2021 vs test era, gold as positive control: silver shows the same gross drift
  signature as gold (1.15/1.07 vs gold 1.12/1.22) but the 4×-heavier relative spread
  nets it to ~0.8; EURJPY's drift decayed to ~1.0 net after 2021 (consistent with the
  EURUSD-AlexG and AOI findings: no FX day-trade edge net of costs).

**Chosen: XAGUSD** (only instrument combining high liquidity, extreme volatility, and
structural similarity to the validated gold edge). EURJPY dropped after the screen.

## 2. EA

`OneBarBreakoutEA.mq5` v1.0 — symbol-generic port of OneBarGoldEA v1.10 (one-candle
rule: prev-day-high buy stop at 06:00, ATR(14)-scaled SL/TP/trail, force-flat 23:50,
long-only + D1 SMA(50) filter, 2% auto-lot, recovery mode). Gold's hardcoded floor
distances became inputs (`InpMinSlPts/TpPts/StartPts/DistPts`) because silver's
spread-to-ATR geometry is 4× worse.

## 3. Calibration (declared, dev window 2025.01–2026.07 only, real ticks)

9-cell grid (SL × trail-distance, TP=2·SL, start=2·dist, floors=40%), then a 4-cell
gradient extension + 2 ablations:

| Cell (SL/dist, silver points) | PF | Net |
|---|---|---|
| 150/any | 0.51 | −$800..−$1,200 (silver noise eats tight stops) |
| 300/75 · 300/150 | 1.06 · 1.18 | |
| **300/250–350 (best, plateau)** | **1.41–1.44** | +$2,847..+$3,384 |
| 300/500 | identical to 350 — trail stops binding | |
| 450/250 · 450/350 | 1.13 · 0.64 | wider SL hurts |
| best + entry 14:00 | 0.69 | US-session entry much worse |
| best + no SMA filter | 1.28 | filter helps silver too |

Dev-window ceiling: **PF 1.44** — far below gold's 1.92 at the identical stage.

## 4. Freeze → holdout → full period (the verdict)

Config frozen at SL300/TP600/trail 700/350/ATR-ref 3500, long-only + SMA50:

| Window | Net | PF | Win% | Reading |
|---|---|---|---|---|
| 2025–26 (dev) | +$3,384 | 1.44 | — | the number that tempted |
| 2020–22 | −$1,052 | 0.70 | 29% | fails |
| **2023–24 (untouched holdout)** | **−$950** | **0.78** | 30% | **FAILS — edge is not real** |
| Full 2020–2026 | +$537 | 1.04 | 33% | breakeven; all profit from 2025–26 |

The silver breakout day-trade has no robust edge. The 1.44 was the 2025–26 silver
squeeze, not a strategy. Same shelf as EURUSD-AlexG and AOI: researched and rejected.

## 5. Why PF 2.5 was never realistic here (so this doesn't get re-run by hope)

- PF 2.5 net at ~100 trades/year survives nowhere in 6 projects of real-tick evidence:
  gold's genuine, live-validated edge — the best found — sustains ≈1.9–2.0 across
  regimes, and only era-slices (2022/2023/2026) exceed 2.
- Higher instrument volatility does not help unless spread shrinks proportionally;
  silver has 2.4× gold's volatility but 5× its relative spread. Cost geometry, not
  excitement, decides day-trade viability.
- Every configuration that displayed PF ≥ 2.4 in-sample during these projects
  (Friday-dip gold: 2.47; various AOI cells) collapsed on unseen data. In-sample
  PF 2.5 is a warning sign, not a target achieved.

## 6. Recommendation

Trade the thing that survived everything: **OneBarGoldEA v1.10 on XAUUSD**
(PF 2.01 full-period headline with its disclosed era-dependence, or the unfiltered
long-only variant at PF 1.90 with steadier era coverage). Silver: do not trade;
keep the EA for future re-tests if silver's spread regime ever improves.

## Files

- `OneBarBreakoutEA.mq5` (compiled in terminal) · `tester_run.ps1` / `grid_batch.ps1`
- `export_screen.py` (pair screen) · `scan_symbols2.py` (liquidity/vol scan, in OneBar_Gold)
- `tester/` — all 21 real-tick reports · `data/` — bar exports
