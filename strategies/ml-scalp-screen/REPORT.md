# ML_Scalp — machine-learned scalping study (2026-07-19)

**Goal set by Jerry:** a profitable scalping bot, ML-driven, any tradable instrument,
same methodology and windows as prior projects.

**Honest frame given up front:** scalping is the most cost-fragile horizon (spread is
the largest fraction of the per-trade move) and ML is the highest-degrees-of-freedom
tool (maximum overfitting surface). Prior related corpses: pure candle trading on gold
(structurally unreachable PF 2 — spread ~20% of H1 body), SessionScalper M5 USTEC
(real-tick PF ~1.03–1.20, thin), every intraday index family in Index_Hunt (≤1.20).
The tester's demo spread also *understates* live spread, so even a passing backtest
overstates live viability. This study exists to measure whether any net edge exists —
a clean rejection is a valid, expected outcome.

## Pre-registered design (locked before any model was trained)

- **Instrument:** XAUUSD (best vol-to-cost on the feed, 296× ATR/spread). US500 M5
  secondary only if gold passes (its M5 depth is thinner).
- **Bars:** M5 primary; M15 as robustness view. Depth as exported (see Results).
- **Label:** direction of net forward return over 4 bars (20 min on M5), entering at
  the NEXT bar open after the signal bar closes (bar-exact, no fill bias, no intrabar
  path assumptions).
- **Features (fixed, 18):** lagged returns over 1/2/3/6/12/24 bars; rolling return
  vol 12/48; range position over 12/48 bars; close vs rolling mean 48; RSI(14);
  ATR(12)-to-daily-ATR ratio; distance to prev-day high and low in daily-ATR units;
  candle body/range; up-streak length; hour sin/cos; day-of-week.
- **Models (fixed):** logistic regression (scaled) and LightGBM classifier
  (300 trees, lr 0.05, num_leaves 31, min_child_samples 200). No tuning loops.
- **Walk-forward:** retrain each calendar month on the trailing 12 months; predict the
  following month. Every prediction is out-of-sample by construction.
- **Trading rule:** long when P(up) ≥ τ, short when P(up) ≤ 1−τ; exit at fixed
  4-bar horizon; τ ∈ {0.55, 0.60, 0.65} all declared now and all reported.
- **Costs:** 40 gold points (≈$0.40/oz) round trip base (36pt demo spread + slip);
  60 points stressed (live-spread scenario). Both always reported.
- **Selection windows (dev):** 2025-01→2026-07 and 2020-01→2022-12 only.
- **Holdout (one look, preference by data depth):** 2016–19, else 2018–19, else
  2023–24 (2023–24 was never used for any ML selection; noted as weakest option).
- **Bar to advance:** net PF ≥ 1.6 in BOTH dev windows at base cost AND ≥ 1.3 at
  stressed cost, holdout PF ≥ 1.3 → only then EA/ONNX mechanization and MT5 real-tick
  verification (which remains the final authority). Anything less = documented
  rejection. No feature/hyperparameter/threshold changes after seeing results.

## Results — REJECTED at the dev-window stage (2026-07-19)

Data: MaxBars cap raised 100k → 10M; XAUUSD M5 exported back to 2004 (1.48M bars),
so all windows incl. the 2016–19 holdout were available. The holdout was never
touched — the dev windows already decide.

**Dev 2025–26** (19 monthly retrains, every prediction out-of-sample):

| Cell | trades/day | PF @ $0.40 | PF @ $0.60 |
|---|---|---|---|
| logit τ.55 | 4.9 | 0.89 | 0.86 |
| logit τ.60 | 0.4 | 1.11 | 1.09 |
| logit τ.65 | 0.1 (n=43) | 1.32 | 1.30 |
| lgbm τ.55 | 36.6 | 0.87 | 0.80 |
| lgbm τ.60 | 16.4 | 0.92 | 0.86 |
| lgbm τ.65 | 5.9 | 1.07 | 1.01 |

**Dev 2020–22** (36 retrains): every cell loses — logit 0.68/0.74 at τ.55/.60,
best cell overall 1.09 on n=71; lgbm 0.48–0.76. The thin 2025–26 positives do not
replicate. M15 robustness view not run: a 1-hour-hold view of a dead M5 signal is
not scalping and cannot rescue the family (noted, per pre-registration it existed
only as robustness for a surviving M5 result).

**Verdict: no machine-learnable scalping edge exists on XAUUSD M5 at CFD costs in
this design space.** Every cell trading at true scalping frequency (≥5/day) has
PF ≤ 1.07 at demo costs and ≤ 1.01 at live-ish costs, in both windows. The
structural reason is arithmetic: the median 20-minute gold move is a few dollars/oz
gross, the round trip costs $0.40–0.60, so the model would need to capture a
10–20% directional edge per trade net — two orders of magnitude beyond the ~1–2%
gross tilt the walk-forward actually found (51–55% hit rates in 2025–26, and an
outright wrong 39–48% in 2020–22 regime shifts). This is the same spread-vs-move
wall that killed pure candle trading (OneBar Part 1) and SessionScalper, now
measured with ML given every fair chance: 18 features, two model classes, monthly
retraining, strictly out-of-sample.

No EA was built, no tester run, no holdout spent. The validated edge remains
OneBarGoldEA v1.21; scalping on this feed is closed as a family unless the cost
structure changes (futures with $1-tick MNQ + orderflow data — the already-scoped
Sierra/Denali route — is the honest venue for sub-hour trading, not CFDs).
