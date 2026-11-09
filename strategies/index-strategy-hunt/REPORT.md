# Index_Hunt — new-edge hunt beyond gold (2026-07-19)

**Goal set by Jerry:** a new strategy on anything tradable on the MetaQuotes feed that
meets the OneBarGold-style bar (real edge, good PF/winrate, decent frequency), using the
same methodology: pre-registered ideas → dev windows 2025–26 + 2020–22 → untouched
holdout → full-period adjudication → real-tick MT5 verification. No open-ended mining.

## Universe scan (done before any strategy test)

MetaQuotes-Demo feed reality:

| Symbol | History (D1/H1) | Note |
|---|---|---|
| US500, DE40, US30 | 2012-08 → now | deep enough for dev + 2015–19 holdout + grand run |
| FX majors | D1 1995, H1 ≥2010 | available; family evidence weak (see below) |
| USTEC | 2022-07 → now | **unusable** for multi-regime testing |
| UK100 | 2020-09 | unusable |
| BTC/ETH/oil/JP225 | not on feed | out |

## Families considered and DROPPED on research grounds (no tests spent)

- **Overnight drift (buy close/sell open, indices):** NY Fed 2026 update ("The
  Disappearing Overnight Drift") shows the effect ~zero since 2021; costs of daily
  round-trips erase the remainder (NightShares ETFs launched and folded on exactly this).
- **London-session / Asian-range FX breakout:** recent backtests show GBPUSD ≈
  breakeven, EURUSD flat-to-negative (some tests find *fading* the breakout better);
  FX vol-to-cost geometry already ranked worst in the 25-symbol HighVol scan.
- **Anything USTEC/UK100:** no history depth on this feed.
- Already dead from prior projects (not retried): index prev-day breakout (USTEC PF
  0.87), intraday momentum first-30min→last-30min (PF 1.05), silver breakout (holdout
  0.78), EURUSD structure-continuation (PF < 1 everywhere), QQQ RSI(2) dip-buy
  (too trendy), AOI mean reversion (PF ~0.99 after costs).

## Pre-registered families (locked 2026-07-19 BEFORE any screen was run)

**F1 — Opening-range breakout (ORB) at the cash open, US500 & DE40.**
Rationale: opening auction sets the day's directional commitment; Zarattini/Barbon/Aziz
(SSRN 4729284) document large 5-min-ORB profits on QQQ 2016–23; the mechanic (stop
entry + aggressive trail + flat by close) is exactly the machinery already real-tick
validated in the gold EA. Known risk: post-publication decay (the intraday-momentum
corpse). Spec: range = first 15 min after cash open (US500 16:30 server, DE40 10:00);
stop order at range extreme; SL = opposite range extreme (capped); trail gold-style;
flat before session close. Sides: long / short / both reported as ablation.

**F2 — US500 multi-day dip-buy (native SPX mean reversion).**
Rationale: short-term S&P mean reversion is the classic documented edge (Connors
RSI(2) family); it failed on QQQ (too deep/trendy — recorded corpse) but SPX is its
native habitat and was never tested here. High winrate by construction (Jerry's wish).
Spec: trend gate close > SMA200(D1); entry after 2 consecutive down closes or RSI(2)
< 10, at next open; exit at close > prev high or RSI(2) > 70 or 5-day time stop;
long-only; costs = spread + overnight swap (multi-day holds pay swap, modeled).

**Acceptance bar (pre-registered):**
1. Python screen on dev windows ONLY (2025-01→2026-07, 2020-01→2022-12): net PF ≥ 1.6
   in both, screen DD ≤ 15%, ≥ 40 trades/yr preferred (frequency goal).
2. Mechanize as EA → MT5 real-tick (Model=4) confirms dev windows (mean-reversion
   fill-bias lesson: bar screens overstate MR fills; ticks decide).
3. Holdout 2015–2019 (fresh for these instruments), one look: PF ≥ 1.3.
4. Full 2015–2026 continuous: PF ≥ 1.5, most years positive, DD comparable to gold EA.
Failing any stage = documented rejection. 2023–24 is never selected on (spent for the
gold projects; kept as incidental out-of-sample only).

**Honest ceiling reminder given up front:** every in-sample PF ≥ 2.4 seen across these
projects has collapsed OOS; the validated gold EA's full-period PF is 1.84. A new
uncorrelated PF ~1.5–1.8 edge is a win (diversification), not a consolation prize.

## Results — all three families REJECTED at the screen stage (2026-07-19)

No family earned an EA build, so no real-tick tester run, no holdout look, and no
grand run. 2015–19 remains unspent for these instruments; 2023–24 untouched.

**F2 — US500 dip-buy** (D1 2012–26 export, dev windows only, next-open fills):
PF 1.44 / +6.2% (2025–26) and 1.20 / +3.2% (2020–22) at feed swap; 1.34 / 1.07 at
conservative live financing (1.3 pts/night). 15–21 trades/yr. Real but thin —
far below the 1.6 bar. Not tuned further (that would be mining). REJECTED.

**F1 — Opening-range breakout, US500 + DE40** (M5, dev 2025–26 only — feed M5 depth
19 months; 2020–22 would have been tester-stage). Session opens confirmed empirically
(16:30 / 10:00 server, largest M5 ranges of the day). Three declared cells:
- 15-min range, stop-entry at extreme, SL opposite extreme, flat by close:
  US500 0.99–1.03, DE40 long 1.19.
- Literature-exact 5-min directional entry (Zarattini/Aziz), first-bar stop: US500
  0.75–1.05, DE40 1.09–1.20 (win% ~20).
- Same with 10%-ATR stop: US500 1.15–1.18, DE40 0.99–1.20.
Best cell anywhere: PF(R) 1.20. The published QQQ 2016–23 results do not exist on
2025–26 index CFDs at realistic costs — post-publication decay, same as the
intraday-momentum corpse. REJECTED.

**F3 — Donchian channel breakout (20/10, 55/20), US500 + DE40 D1** (declared final
round): 2025–26 flattered US500 20/10 long (PF 2.60 — on n=6), but 2020–22 kills every
cell (best 1.43 feed-swap / 0.82 live-swap; DE40 negative everywhere; all shorts PF
≤ 1.05 ex-one n=4 cell). Tiny samples, no cell passes both windows. REJECTED.

## Verdict

On this feed, at CFD costs, across every family with credible structural backing that
was still untested — index ORB, native-habitat SPX mean reversion, daily channel
momentum — nothing clears the pre-registered bar. Combined with the prior corpses
(index prev-day breakout, intraday momentum, session scalper ~1.1, silver, FX
structure/breakout families, AOI), the honest conclusion stands: **the validated
edge in this program remains OneBarGoldEA v1.21 on XAUUSD (PF 1.84, 11.5y real-tick),
and no second uncorrelated edge of comparable quality has been found on this feed.**
Screens were bar-exact where used (next-open fills / pessimistic same-bar stops);
none of the rejections is a fill-model artifact within realistic tolerances.

What would genuinely widen the hunt (future sessions, Jerry's call): instruments not
on this feed (oil, JP225, VIX-linked, single stocks, crypto) via a broker with deeper
multi-asset history, or the already-planned MNQ orderflow route (Sierra/Denali data),
or accepting lower-PF diversifiers (the PF ~1.4 dip-buy is real, just thin).
