# Real Orderflow on Nasdaq Futures (MNQ) — Project Plan

Goal: trade genuine orderflow (order book depth, volume delta, footprints) on the
Micro E-mini Nasdaq-100 (MNQ) at CME — the real exchange data MT5 CFDs cannot provide.

## The instrument: MNQ (Micro E-mini Nasdaq-100)

- $2 per index point (Nasdaq ~29,800 → ~$60k notional per contract)
- Tick 0.25 pt = $0.50
- Day-trading margin at discount brokers: ~$100/contract — but margin is NOT risk;
  a 100-point stop = $200 = 2% of a $10k account. Size by stop, like always.
- NEVER hold overnight in this project (overnight margin ~$3,700 and gap risk).
- US session = 9:30 PM – 4:00 AM Malaysia time. The prime orderflow window is the
  first 1–2 hours: 9:30 PM – 11:30 PM MYT — realistic evening hours.

## The stack (recommended)

| Piece | Choice | Cost | Notes |
|---|---|---|---|
| Platform | Sierra Chart, package 11 or 12 | $46–56/mo | Pkg 12 adds Market-by-Order (see individual orders in the book). Programmable (I write the code), light on RAM. |
| Data | Denali feed + CME exchange (non-pro, with depth) | ~$16/mo CME fee + small feed fee | Covers MNQ/NQ/MES/ES. Real depth + real volume with aggressor side. |
| Broker (later, live phase only) | AMP Futures | $0/mo, $100 min deposit | Accepts Malaysian residents. Commissions ~$1.5–2.5 per round trip all-in on MNQ. |
| **Sim-phase total** | | **~$70–90/month** | No broker needed to start: Sierra has full trade simulation on live data. |

Alternative platform: NinjaTrader (free with brokerage, has an orderflow suite) —
fallback if Sierra feels too raw. Sierra chosen for programmability + MBO depth.

## Phases and gates (same discipline as the gold bot)

### Phase 0 — Decide the budget (before anything)
This project costs ~$80/month BEFORE any trading profit. That's ~10% of a $10k
account per year in fixed costs. The edge must clear data costs + commissions +
spread. Commit to a 3-month trial (~$250) and a written stop-loss on the project
itself: if after 3 months of sim there is no documented edge, the subscriptions end.

### Phase 1 — Setup + observation (2–4 weeks)
- Jerry opens the Sierra Chart account and data subscriptions (accounts/payments
  are yours to do; Claude helps configure everything after).
- Build the workspace: DOM, footprint (bid/ask volume per price), cumulative
  delta, session VWAP, volume profile.
- Watch the US open (9:30–11:30 PM MYT) live several nights/week. Journal what
  you see. No trading, not even sim. Goal: learn to read the tape slowly.

### Phase 2 — Sim trading + systematization (1–2 months minimum)
- Trade Sierra's simulator ONLY, on the live feed, during the open.
- Define 1–2 written setups max (e.g., delta divergence at VWAP; absorption at a
  prior high/low). Every sim trade journaled against the written rules.
- In parallel, Claude codes measurable versions of the setups (ACSIL studies) so
  the rules' hit-rate can be counted rather than remembered. Honest caveat:
  full depth-based backtesting is limited — much of the validation here is
  FORWARD sim results, which is slower but more truthful.
- Gate to Phase 3: 2+ months of sim with positive expectancy after realistic
  costs, ≥100 sim trades, and rule-following ≥95%.

### Phase 3 — Live, tiny (only after the gate)
- Open AMP, fund $2,000–3,000 maximum (the rest never touches futures).
- 1 MNQ contract, same written setups, hard daily loss limit (e.g., $100 = ~3
  losers), stop for the day when hit. No overnight positions, ever.
- Gate to scaling: 3 months live matching sim expectancy.

## What Claude does vs what Jerry does

- Jerry: opens accounts, pays subscriptions, does the screen time (orderflow
  reading is partly a human skill), keeps the journal.
- Claude: configures Sierra, writes any indicator/automation code (ACSIL),
  analyzes the journal + sim fills statistically, builds the daily review
  process, and keeps the honesty gates enforced.

## Standing warnings

1. This is the most competitive arena in trading — HFT firms monetize raw
   orderflow signals faster than any human or retail bot can. The realistic
   retail edge, if any, is discretionary context + patience, not speed.
2. Fixed costs are the silent killer at this account size. $80/mo needs ~10%/yr
   return just to break even on data.
3. The existing systems continue: gold bot forward test (MT5) and the USTEC
   scalper verification are unaffected and remain the most likely sources of a
   validated edge. This project is a skill investment, not a replacement.
