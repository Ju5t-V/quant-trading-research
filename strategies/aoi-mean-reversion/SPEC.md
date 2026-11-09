# AOI Mean-Reversion Strategy — Full Spec & Ablation Plan

**Source:** Revelio Trading videos dissecting Alex Gonzalez (FX Alex G) "Set and Forget":
- Video 1: "I Coded fxalexg's Trading Strategy. Does It Work?" (nFIJ0z8_01w) — base rules, original results
- Video 2: "I Tried to Improve fxalexg's Trading Strategy" (HzVSi9ux1NU) — ablation, final improved strategy

**Goal:** Reproduce his methodology honestly (Python engine → ablation → train/test → costs), then implement the winner as an MQL5 EA and validate in the MT5 strategy tester. Report truthfully even if we find no edge.

---

## 1. Universe & Data

- **16 pairs** (from video 1 results table): AUDCAD, AUDCHF, AUDJPY, EURAUD, EURGBP, EURJPY, EURUSD, GBPAUD, GBPCAD, GBPCHF, GBPNZD, GBPUSD, NZDCAD, NZDUSD, USDCAD, USDCHF
- **Period:** Jan 2016 – May 2026 (need ~2014+ data for AOI lookback warm-up)
- **Train:** Jan 2016 – Dec 2021. **Test (locked):** Jan 2022 – May 2026
- **Timeframes:** D1 + W1 (zones & structure), entry TFs H4, H2, H1, M30, M15
- **Data source:** MT5 MetaQuotes-Demo via Python API (server tz = EET, daily close = 17:00 NY ≈ same daily candles as his charts)
- Pip = 0.0001 (0.01 for JPY pairs)

## 2. Base strategy — Alex's original rules (video 1)

### 2.1 Structure/trend engine (BODIES ONLY — closes/opens, wicks ignored)
- Swing points on the **close line** of the TF being analyzed
- Uptrend = active leg (HL, HH). Price between them = no change (noise)
- Body-close **break of HH** → uptrend continues: new HH = new swing high; new HL = most recent swing low
- Body-close **break of HL** → downtrend: broken low's swing = LL... trend flips; leg becomes (LH, LL); mirror logic for downtrends
- Trend TFs: W1, D1, H4. **Confirmed trend requires 2 consecutive TFs agreeing: (W1+D1) or (D1+H4)**

### 2.2 Areas of Interest (AOI)
- Support/resistance zones from candle **bodies**, drawn on **W1 and D1**
- Level must be **touched ≥ 3 times** (body touches)
- Zone width: **min 5 pips, max 60 pips**
- Validity: **W1 zones 5 years, D1 zones 2 years** (age-based expiry)
- No AOI → no trade

### 2.3 Original entry (all filters ON)
- Trend direction (2.1) gives trade direction; price must be **inside an AOI**
- Trigger: candlestick pattern from Alex's list —
  **Used:** Hammer, Inverted Hammer, Bullish Engulfing, Morning Star, Morning Doji Star; Shooting Star, Hanging Man, Gravestone Doji, Bearish Engulfing, Evening Star, Evening Doji Star
  **Excluded (crossed out):** Dragonfly Doji, Piercing Line, Three White Soldiers, Dark Cloud Cover, Three Black Crows
- SL: 5–7 pips beyond the AOI. TP: nearest structure level, min RR 1:2 (ideal 1:4)
- Set and forget: no partials, no breakeven, no management
- Video 1 result: avg −4%/config over 10y; ~21% win rate; avg realized RR ≈ 1:3.5; $10k → $21 compounding across configs

## 3. Ablation design (video 2) — 200 configs

| Rule | Variants |
|---|---|
| 1. Higher-TF bias | OFF / PAIR (Alex: W+D or D+H4) / WEEKLY / DAILY / 4-HOUR |
| 2. Trend on traded chart must agree | ON / OFF |
| 3. Candlestick pattern trigger | ON / OFF |
| 4. Retest of the level | ON / OFF |
| 5. Session | ASIA / LONDON / NEWYORK / OVERLAP / ALL |

5 × 2 × 2 × 2 × 5 = **200**. Ranking metric: **profit factor**, computed **costs-excluded at 2% fixed risk**, on **train set only**, all TFs/pairs aggregated per config.

**His training-set anchors (validation targets for our reproduction):**
- #1 PF 1.180 off/on/on/on/asia
- #2 PF 1.139 all-off/asia · #6 PF 1.128 all-off/overlap · #9 PF 1.103 all-off/all(≈)
- Whole-period: winner = all-off/overlap; all-off ranks #5 asia, #8 london, #16 all — all PF > 1
- Bias hurts: first config using Alex's PAIR bias is rank #38, PF barely > 1

## 4. Final improved strategy (video 2 recap screen, verbatim)

1. **AOI:** Daily TF only, exactly as Alex teaches: 5–60 pips wide, 2-year expiration (weekly zones DROPPED)
2. **Entry TFs:** 2H / 1H / 30M / 15M (4H dropped; lower = better: D1-zone PF by TF — 4H 1.00, 2H 1.17, 1H 1.19, 30M 1.33, 15M 1.35 all-sessions)
3. **Sessions:** ALL sessions 24/5 (overlap variant also valid: PF 1.38 on 15M)
4. **Entry:** FIRST candle that closes inside a daily area. No trend/bias/pattern/retest. **Buy at support, sell at resistance**
5. **SL:** 5 pips beyond the zone (below support for buys, above resistance for sells)
6. **TP:** nearest **daily swing point**; if target < 2R → **skip trade**; if > 4R → **cap at 4R**
7. **One open trade per pair** at a time
8. **Risk:** 0.5% of high-water-mark balance

**His final numbers (validation targets):**
- Gross: ALL PF 1.36 (1,868 trades) / OVERLAP PF 1.31 (1,043)
- Net of IC Markets costs: ALL **PF 1.25**; 0.5% HWM → **+493%, −28.8% maxDD** (≈18.7%/yr; ~39%/yr since 2021); 1% HWM +3,282%/−57.6%; 2% +30,122%/−74.0%
- Pairs: profitable 14/16 (ALL) / 13/16 (OVERLAP). Timeframes: worst of 16 zone-TF×TF combos PF 0.95
- Edge concentrated post-2020 (flagged as robustness concern)

## 5. Mechanical definitions HE never fully specifies (OUR documented choices)

These are the degrees of freedom in any reproduction. Chosen once, before running, and frozen:

- **A1. Swing point:** fractal on closes of the analysis TF: close[i] is a swing high if it's the strict max of closes[i−k..i+k] (swing low = strict min), **k = 2**. Confirmation lags k bars (no lookahead: swings usable only after confirmation).
- **A2. AOI construction (D1/W1):** cluster confirmed swing closes: a new confirmed swing level L joins an existing zone if it fits within the zone's span ≤ 60 pips (span = max−min of member levels, floored to 5 pips min); else starts a new candidate zone. Zone becomes ACTIVE at its 3rd member touch. Zone band = [min member, max member] (±0 padding; the 5-pip floor is applied symmetrically around the mean when span < 5 pips).
- **A3. Touch definition:** the candle's **body extreme** (close for swing bars) falling inside/at the band. Members must be swing bars (that's what "market keeps reacting to" means mechanically).
- **A4. Zone lifecycle:** zone timestamp = time of 3rd touch; expires 2y (D1) / 5y (W1) after **last touch** (refreshed on each new touch — assumption; alternative "after creation" noted for sensitivity check).
- **A5. Support vs resistance:** determined at signal time: if the entry-TF candle entered the zone **from above** (prior close above band top) → support → BUY; **from below** → resistance → SELL. Inside-out chop: no signal until price fully exits the band and re-enters.
- **A6. Signal:** first entry-TF candle whose **close** lands inside the band per A5, while flat on that pair. Re-arm only after price closes fully outside the band. Enter at next candle open.
- **A7. TP "nearest daily swing point":** most recent confirmed D1 swing high above entry (buys) / swing low below (sells). RR computed vs SL distance; < 2R skip, > 4R cap at 4R.
- **A8. Retest (rule 4, ablation only):** after a signal zone touch, require price to leave the band and return once before entry (one full exit-return cycle) — creator's own note: it added nothing.
- **A9. Sessions (server time EET/EEST, MT5):** Asia 01:00–10:00, London 10:00–19:00, NY 15:00–24:00, Overlap 15:00–19:00, All = 24/5. (≈ Tokyo/London/NY in UTC+2/3.) Entry-candle close time decides session membership.
- **A10. Trend-on-traded-chart (rule 2):** structure engine (2.1) run on the entry TF; direction must match trade direction.
- **A11. Costs (IC Markets Raw-like):** commission $7/lot round-turn; spread per pair (typical raw medians, pips): EURUSD 0.10, GBPUSD 0.25, USDCHF 0.30, USDCAD 0.30, NZDUSD 0.40, AUDJPY 0.40, EURJPY 0.40, EURGBP 0.40, AUDCHF 0.60, AUDCAD 0.60, EURAUD 0.70, GBPCHF 0.90, GBPCAD 1.00, GBPAUD 1.00, NZDCAD 0.90, GBPNZD 1.80; swap ignored in ranking, modeled flat −$0.4/lot/night (triple Wed) in final net run — documented approximation.
- **A12. Sizing:** risk% × equity-base / (SL distance in account currency per lot); account USD, $10,000 start; margin/leverage 1:100 cap enforced.
- **A13. Fills:** stop/TP evaluated intrabar on entry-TF OHLC (conservative: if both SL and TP touched in same candle → count as LOSS). Entry at open of candle after signal with spread applied.

## 6. Execution plan

1. Export MT5 data (M15 + H1 + H4 + D1 + W1; M30/H2 resampled from M15) — validate depth per pair
2. Python engine (`engine.py`): zones, structure, signals, fills, costs, HWM sizing — all 5 rules toggleable
3. Reproduce video-1 original strategy first (sanity anchor: expect ~20% win rate, avg RR ~3.5, negative return, USDCHF best / AUDCAD worst pattern)
4. Ablation: 200 configs × 16 pairs × 5 entry TFs on TRAIN (2016–2021, 2% risk, no costs) → rank by PF → compare against his anchor table
5. Winners → locked TEST set (2022–May 2026): survive?
6. Robustness: per-TF, per-pair, per-year, costs on, HWM variants; sensitivity of A1 k∈{2,3}, A4 expiry-from-creation
7. MQL5 EA (`AOI_MeanReversionEA.mq5`): final config + toggles; MT5 tester validation vs Python (M15, 1-min OHLC then real ticks on 2–3 pairs)
8. Verdict: honest go/no-go vs Jerry's gates

## 7. Honest-skeptic notes (carried from analysis)

- His edge is concentrated post-2020 (~39%/yr since 2021 vs ~flat before) — regime-dependence risk; our test must report per-year
- His TF/weekly-drop/HWM choices were made after seeing full-period data → mild selection leakage; we keep the test set locked until the very end
- 20% win rate @ ~3R is psychologically brutal live; DD −28.8% even at 0.5% HWM
- Different data feed + our A1–A13 choices ≠ his exact numbers; we validate direction/shape, not decimals
