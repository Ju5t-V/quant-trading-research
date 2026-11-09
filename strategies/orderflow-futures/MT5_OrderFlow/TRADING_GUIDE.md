# Reading the Orderflow Toolkit — and Trading With It

> **Superseded 2026-09-13 by `ORDERFLOW_PLAYBOOK.html` — do not trade from this file.**
> Its central claim, "price lingers 1.7× longer at HVN than LVN", failed a distance control:
> levels mirrored across the next open show the same gap (volume-attributable difference
> −0.2 bars). The 43.9% in §4 is a touch rate measured with no stop, not a win rate, so the
> $3/$9 arithmetic there does not follow. All results are in-sample.

A working manual for the three MT5 indicators. Written for the gold chart during the
US session (9:30 PM – 4:00 AM Malaysia).

**Read this first.** I tested every rule in this guide on 7 years of XAUUSD M5 data
(1,834 sessions) before writing it, and most of the popular ones do not survive. The
honest summary:

> These tools are excellent for deciding **where** to put stops and targets, and for
> understanding **context**. They are weak as entry triggers. The edge, if you find one,
> will come from selection and risk-reward — not from the patterns themselves.

Every rule below carries its measured result so you know which parts are evidence and
which are craft.

---

## 1. Chart setup (do this once)

| Setting | Value | Why |
|---|---|---|
| Symbol | XAUUSD | |
| Timeframe | **M5** | Fine enough to see structure, slow enough to think. M1 is noise at this stage. |
| `OF_Heatmap` → `InpScope` | `SCOPE_SESSION` | Profiles the developing day. |
| `OF_Heatmap` → `InpBucketPoints` | 10 | $0.10 rows — right for gold. |
| `OF_Heatmap` → `InpHvnAsZone` | true | You want the bands, not hairlines. |
| `OF_Absorption` → `InpMethod` | `Z-score + impact` | The delta-free method. |
| `OF_Absorption` → `InpMarkerStyle` | `Bubble` | Size = volume. |

**Server time is UTC+3.** Your broker's "day" starts at **5:00 AM Malaysia time**. That
is *after* your session ends, which is what you want: when you sit down at 9:30 PM MYT,
the session profile already contains the full Asian and European day, and it will not
reset underneath you mid-trade.

---

## 2. The five-minute pre-session routine

Do this at ~9:15 PM MYT, before the New York open.

1. **Note yesterday's levels.** Set `InpScope` to `SCOPE_ROLLING` with `InpRollingBars`
   = 288 (one full day of M5) to see the prior day's structure, then switch back to
   `SCOPE_SESSION`. Write down prior POC, VAH, VAL.
2. **Locate price relative to value.** Three possibilities, and they dictate everything:
   - **Inside value** → balanced, expect rotation. Fades are on, breakouts usually fail.
   - **Above VAH** → buyers in control. Do not short into strength.
   - **Below VAL** → sellers in control. Do not buy into weakness.
3. **Mark the HVN bands and LVN lines** the indicator drew. These are your target and
   stop furniture for the night.
4. **Write your maximum loss for the session on paper** before the first trade.

---

## 3. Reading the picture

**The heatmap.** Bright cells = where volume actually transacted. A long candle with one
bright shelf and a lot of dark space is *not* a strong move — price passed through most
of that range without trade. The shelf is the real level; the wick is noise.

**The gold bands (HVN).** Shelves of heavy trade. Measured on 1,834 sessions: price
spends **1.7× longer** inside an HVN band than an LVN band of the same width (median 25
vs 15 M5 bars). That is the single most robust finding in this whole toolkit, and it is
about *time*, not direction. Consequences:

- Good place to **take profit** — price will linger and give you the fill.
- Bad place to **enter a breakout** — you will sit in chop.
- Bad place for a **stop** — it will get grazed.

**The grey dotted lines (LVN).** Air pockets between shelves. Price crosses them fast.

- Good place to put a **stop just beyond** — less likely to be touched and recover.
- Bad place for a **target** — price does not hang around to fill you.

**POC (red).** The most-traded price. Useful as a reference and a realistic target.
**It is not a magnet** — I tested it: the next session trades through the prior POC 66.7%
of the time, but a mirrored level the same distance from the open gets touched 66.2% of
the time. The excess is +0.4 points, i.e. nothing. Price covers ground; the POC is not
pulling it.

**The bubbles (absorption).** Unusual volume that did not move price, with the close
rejecting one end. Size = the bar's volume. Treat as **context only** — see §7.

---

## 4. Setup 1 — Value-Area Fill (the "80% rule")

The only setup here with a measured edge over its base rate.

**Context:** the session opens *outside* the prior day's value area.

**Trigger:** price re-enters the value area and **holds for 30 minutes** — six
consecutive M5 closes between VAL and VAH.

**Entry:** market, on the close of the sixth bar inside.

**Stop:** just back outside the value edge you came through, plus a buffer past the
nearest LVN. Typically $2–4 on gold.

**Target:** the *opposite* value-area boundary. Scale out at POC if it is on the way.

**Measured:** the setup appears on **30% of sessions** (545 of 1,833). It reaches the far
side **43.9%** of the time, against a base rate of **35.4%** for any session covering the
whole prior value area. So the real edge is **+8.4 percentage points** — not the 80% the
textbooks claim.

**What that means for you:** at 44% you need the target to be worth clearly more than the
stop. If your stop is $3 and your target is $9, 44% wins is strongly profitable. At 1:1 it
is a losing trade. **This setup only works if you respect the reward-to-risk.**

---

## 5. Setup 2 — LVN Traverse

Built directly on the 1.7× lingering result.

**Context:** price is leaving an HVN band and heading into an LVN.

**Trigger:** an M5 bar closes clear of the HVN band edge, moving toward the LVN.

**Entry:** market on that close.

**Stop:** back inside the HVN band it just left — if price re-enters the shelf, the move
has failed.

**Target:** the **far side** of the LVN, at the next HVN band. Never inside the gap.

**Measured:** the traverse behaviour is real (price does not linger in LVNs). I have
**not** tested this as a mechanical entry, so treat the entry timing as unproven; the
target and stop logic is the part with evidence behind it.

---

## 6. Setup 3 — HVN / Value-Edge Rejection (discretionary)

**Context:** price pushes into a prior-day value edge or a thick HVN band from inside and
stalls.

**Trigger:** a bar closes back inside, ideally with an absorption bubble at the level.

**Entry:** market on the rejection close, or a limit order back at the level.

**Stop:** beyond the extreme of the rejection bar, past the nearest LVN.

**Target:** POC, then the far value edge.

**Measured — and this is the uncomfortable part.** Mechanically, taking every first touch
of a prior value edge and holding one hour:

| | n | mean (gross) | after 36-pt spread | win % |
|---|---|---|---|---|
| Fade short at VAH | 1,143 | −57 pts | worse | 50% |
| Fade long at VAL | 1,082 | +72 pts | +36 pts | 56% |

The long side looks good until you split it by year:

| 2020 | 2021 | 2022 | 2023 | 2024 | 2025 | 2026 |
|---|---|---|---|---|---|---|
| −67 | +20 | −13 | −22 | −21 | +38 | **+368** |

*(net points after spread)*

**Five of seven years are flat or negative. The entire edge is 2026** — and 2026 is the
year gold's volatility exploded, which inflates every point-based figure. Strip that year
and there is nothing here.

So: this setup is **not validated**. Trade it in sim only, and only when the context is
strongly in its favour (balanced day, clean rejection, absorption present). This is where
discretion has to earn its keep — my test takes every touch blindly, which is exactly what
you should not do.

---

## 7. Where absorption fits

Not as a trigger. I tested it separately: every threshold configuration produced a
**negative mean**, and results got *worse* as the criteria tightened, which is the
signature of noise. (Detail in `README.md`.)

The reason is partly this feed: a proper absorption read needs real bid/ask trade volume,
and XAUUSD CFD has none — the delta is inferred and explains only 1.7% of a bar's price
change.

**Use bubbles as a tiebreaker, never a reason.** If you already have a level and a
rejection, a bubble at that level is mild supporting evidence. A bubble on its own is not
a trade.

---

## 8. Placing the trade in MT5

**Contract facts for your XAUUSD** (read from the terminal):

- Contract size **100 oz** → 1.00 lot = **$100 per $1 move**; 0.01 lot = **$1 per $1 move**
- Minimum lot **0.01**, step **0.01**
- Current spread **36 points = $0.36** — on a $3 stop that is 12% of your risk before you
  start. It is why small targets do not work here.

**Position size formula:**

```
lots = risk_in_dollars / (stop_distance_in_dollars x 100)
```

| Account | Risk 1% | Stop | Lots |
|---|---|---|---|
| $10,000 | $100 | $3.00 | 0.33 |
| $10,000 | $100 | $5.00 | 0.20 |
| $3,000 | $30 | $3.00 | 0.10 |

**Order steps:**

1. Press **F9** (or right-click chart → Trading → New Order).
2. Type: **Market Execution** for a rejection you are chasing; **Buy Limit / Sell Limit**
   to rest an order at a level you have marked.
3. Set **Volume** from the table above — compute it *before* the setup appears, not while
   price is moving.
4. Fill in **Stop Loss** and **Take Profit** in the same dialog. Never place the order
   intending to add the stop afterwards.
5. Check the ticket after it fills: entry price, stop, target, and that the lot size is
   what you meant.

---

## 9. Risk rules (non-negotiable)

- **1% of the account per trade**, maximum.
- **Daily stop: three losers, then stop for the night.** Close the platform.
- **Never hold through 4:00 AM MYT.** Flat before you sleep.
- **Minimum 1:2 reward-to-risk.** Given the measured hit rates, anything less is a
  losing game arithmetically.
- **No trade without a level.** If you cannot name the HVN, LVN or value edge you are
  trading against, you do not have a setup.

---

## 10. Pre-trade checklist

Say all six out loud before clicking. If any answer is missing, no trade.

1. Which **level** am I trading against?
2. Is price **inside, above or below** value — and does my trade agree with that?
3. Where exactly is my **stop**, and is it beyond an LVN rather than inside an HVN?
4. Where is my **target**, and is it at an HVN where price will actually linger?
5. Is the reward at least **twice** the risk?
6. What is my **lot size**, calculated?

---

## 11. The gate

This is sim-only until you have a documented edge. From your own project rules:

- **100 sim trades minimum**, every one journaled against the written setup
- **Positive expectancy after costs** — the $0.36 spread included
- **95% rule-following** — a profitable trade that broke your rules counts as a loss for
  this purpose

Log per trade: date/time, setup number, level traded, entry, stop, target, exit, result in
$ and in R, and one line on whether you followed the plan. When you have 100, I will
analyse them properly — expectancy by setup, by hour, and by whether you followed the
rules, which is usually the most revealing cut.

---

## What the evidence actually says — summary

| Claim | Verdict | Measured |
|---|---|---|
| Price lingers at HVN, travels through LVN | **Supported** | 1.7× (25 vs 15 M5 bars) |
| 80% rule fills the value area | **Partly** — real but much weaker | 43.9% vs 35.4% base |
| POC is a magnet | **Not supported** | 66.7% vs 66.2% control |
| Fade the value-area high | **Not supported** | −57 pts, 50% win |
| Fade the value-area low | **Not supported** — one year carries it | 5 of 7 years flat/negative |
| Absorption predicts reversal | **Not supported** | negative mean at every setting |

Use the top row for placement. Use the second for your one real setup. Treat the rest as
context to be filtered by judgement — and prove it in sim before it costs you anything.
