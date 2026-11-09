# AOI Mean-Reversion — Reproduction Verdict (2026-07-18)

> **CORRECTION (same day, supersedes §"sole survivor" below):** a 1-day lookahead was found in the
> engine (D1 swing fractals were usable at the confirm bar's OPEN instead of its CLOSE — zones and
> TP levels appeared one day early). After the fix, the V4-asia "survivor" collapses:
> train net PF 1.028→**0.963**, test 1.124→**1.018**, full-period equity −29%, DD −91%.
> **Final verdict: NO configuration has a tradeable edge net of costs. None.** Gross PFs of
> 1.03-1.11 show a real but tiny mean-reversion tendency at daily S/R; friction eats all of it.
> Numbers below marked (pre-fix) are retained for the record of how the artifact looked.

**Question:** Does the "improved fxalexg strategy" from Revelio Trading's video 2 (+493% net, PF 1.25,
−28.8% DD) survive an independent, faithful reproduction with honest costs?

**Answer: No for his headline all-sessions version. A weak relative — Asia-session with a 25-pip
minimum stop — survives, but it is not tradeable by this project's standards.**

## What we reproduced (agrees with his findings)
- Win rate ~26-30%, average RR ~3.0 (his: ~21%, ~3.5) ✓
- Asia = best session, by far, in both train eras ✓ (his train #1-#3 were all Asia)
- Retest rule adds nothing ✓ (his 4-0 verdict)
- Test era (2022+) stronger than train era ✓ (his "edge increasing since 2021")
- All-off/asia profitable gross in train AND test (his training #2) ✓

## What did NOT reproduce
- **His winner (everything-off / London-NY overlap):** in our engine, overlap is the WORST session
  (train PF 0.85-0.98 across variants). His #1 cell is our #63.
- **"Bias hurts":** our top train cells include W/PAIR-bias configs (small n≈270 — likely grid luck,
  exactly the danger he warned about; our high-n cells agree bias adds nothing, but not that it hurts).
- **The 4H→15M "lower is better" gradient:** disappeared after we fixed exit resolution to H1
  granularity. Coarse-bar exit modeling (same-bar SL+TP ambiguity) manufactures exactly this
  gradient — his may suffer the same artifact.
- **Absolute PFs:** his net 1.25 (all-sessions) vs our net 0.84 (his exact recap rules incl.
  SL 5 pips beyond zone). His trade count (1,868) is ~4x sparser than ours — his zone book and
  SL distances (never mechanically published) differ materially from any honest reconstruction.

## The decisive mechanism: costs vs SL distance
His recap rule (SL 5 pips beyond a zone) + our zones ⇒ avg SL ≈ 18 pips ⇒ spread+commission
= 6-18% of risk per trade ⇒ no configuration survives costs (best net PF 0.92).
Pre-registered 5-variant sensitivity sweep found ONE lever that matters: minimum SL distance 25 pips
(deviation R1 from his recap). Zone width/strength variants changed nothing.

## The sole survivor: V4-asia (D1 zones, everything off, Asia session, SL floor 25p)
| metric | value |
|---|---|
| Net PF full period (H4+H2, 3,589 trades) | **1.066** (gross 1.161) |
| Train 2016-21 / Test 2022-26 net PF | **1.028 / 1.124** (one look, passed) |
| 0.5% HWM equity | +140% (CAGR 8.8%), **maxDD −45%** |
| 1% HWM | +471% (CAGR 18.2%), **maxDD −90%** |
| Pairs net-profitable | **9/16** (carried by AUDCHF 1.62, EURUSD 1.57, NZDCAD 1.28) |
| Finer TFs | H1 1.024, M30 1.03, M15 1.08 (consistent, small) |
| Losing years | 2016, 2019 (−22%), 2020, 2022 — 4 of 11 |

**Why this is NOT a green light:** edge is thin (2-7 cents per dollar risked), drawdown/return ratio
is terrible (−45% DD for 8.8%/yr at minimal risk; gold EA does ~35%/yr at −25% DD), profits
concentrate in 3 pairs, and the strongest years are the recent regime (2024-25) — the same
regime-concentration we flagged in his results.

## Method lessons (the real value)
1. **Published rules ≠ reproducible edge.** Two faithful engines (his and ours) implementing the same
   stated rules disagree on the winner. The edge, if any, lives in unpublished implementation details
   (zone drawing, SL placement).
2. **Exit-resolution granularity is a silent killer** in multi-TF backtests: same-bar SL+TP handling
   alone created/destroyed the "lower TF is better" conclusion.
3. **Cost survival is a function of SL distance**, not zone quality. Any S/R-touch strategy with
   sub-20-pip stops pays 6-18% of risk per trade in friction.
4. **Ablation works** — but grid winners with n<300 trades are luck until proven otherwise (both his
   grid and ours produced small-n "winners" at the top).
5. His train→test improvement replicates, meaning the favourable regime is real but recent —
   exactly the thing that mean-reverts.

## MT5 EA cross-validation (2026-07-18, tester 1-min OHLC, H2, Asia config, 2016-2026)
`AOI_MeanReversionEA.mq5` v1.01 (0 errors/0 warnings) reproduces the Python engine's structure:
| pair | MT5 net | MT5 PF | trades | win% | Python net PF (pre-fix ref) |
|---|---|---|---|---|---|
| AUDCHF | +$1,668 | 1.79 | 69 | 42% | 1.62 |
| EURUSD | +$1,070 | 1.22 | 134 | 31% | 1.57 |
| GBPAUD | −$1,083 | 0.90 | 290 | 24% | 0.98 |

Ordering, trade density, and PF magnitudes agree (MT5 includes spread but NO commission — sits
between our gross and net models). History quality 98-99%. The EA is a faithful implementation;
3 good/bad pairs do not overturn the 16-pair aggregate verdict (net ~0.96-0.99).

## Improvement pass (pre-registered, train-only selection, 2026-07-18)
Baseline V4-asia train net PF 0.963. Threshold to advance: +0.03.
| variant | mechanism | train net PF | Δ |
|---|---|---|---|
| I1a/I1b time-stop 5d/10d | thesis decay | 0.965 / 0.964 | +0.002 / +0.001 |
| I2a/I2b TP cap 3R/2.5R | shallow reversion | 0.955 / 0.961 | −0.008 / −0.002 |
| I3 SL 15p beyond band | stop-hunt buffer | 0.986 | **+0.023** |
| I4 zone quality (≥4 touch, ≥15p) | established levels | 0.955 | −0.008 |
| I5 skip ATR>p90 days | blowouts break S/R | 0.982 | **+0.019** |

**None qualified. No combo, no test look — the improvement pass concludes NEGATIVE per its own
pre-registration.** The edge is not parameter-starved; it is structurally too small for friction.

## Final status
Project CLOSED as researched-and-rejected (same shelf as the EURUSD Alex G EA). Deliverables:
full reproduction study, working MQL5 EA (usable for demo experiments, not recommended for live),
tester harness (`tester_run.ps1`), and the method lessons above — the durable value.

## Files
- `SPEC.md` — full ruleset + assumptions A1-A14, deviation R1
- `engine.py` — candidates/zones/structure/patterns/outcomes (env-tunable zone params)
- `ablation.py` — 200-config grid, train/test | `sweep_zones.py` — 5-variant sensitivity
- `final_eval.py` — costs + HWM equity sims | `export_data*.py` — MT5 data pulls
- `data/candidates.parquet` — current build = V4 (SL floor 25p)
- `results/ablation_train.csv` — full 200-config train ranking
