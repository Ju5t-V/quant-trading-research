# The Plan: From Zero to Live Trading

Four phases. Each phase has a **gate** — a concrete condition you must meet before moving to the next. Skipping gates is how accounts die. Expect the whole journey to take **6–12 months**. That sounds slow; it is much faster than losing $10k and starting over.

---

## Phase 1 — Foundations & Backtesting (now → ~2 months)

**Goal:** understand *why* a strategy makes money, and prove it on 15+ years of historical data before believing it.

What you do:
- Run the two starter strategies in this workspace (`run_backtest.bat`) and study the results. One is **trend following** (ride long moves up, step aside in downtrends), one is **mean reversion** (buy short-term panic dips inside a healthy uptrend). These are the two fundamental "edges" in swing trading — almost everything else is a variation.
- For each backtest, learn to read four numbers: **CAGR** (annual return), **Max Drawdown** (worst peak-to-valley loss — could you stomach it with real money?), **Win rate + avg win/loss** (how the profits actually arrive), and **number of trades** (fewer than ~50 trades = the result might be luck).
- Use TradingView to *look at* the trades the backtest took. Pull up SPY, add the indicators, and eyeball entries and exits. Building intuition for what the system does is as important as the statistics.
- Learn the core concepts as they come up: overfitting (a strategy tuned until the backtest looks perfect will fail live), transaction costs, and why out-of-sample testing matters.

**Recommended reading (in order):**
1. *Following the Trend* — Andreas Clenow (why systematic beats discretionary)
2. *Quantitative Trading* — Ernest Chan (the retail quant workflow, readable without heavy math)
3. *The Little Book of Common Sense Investing* — Bogle (know what you're trying to beat and why it's hard)

**Gate to Phase 2:** you can explain, out loud, why each strategy makes money, what its worst historical drawdown was, and what market conditions break it. You've seen the backtests run on data the strategy was NOT tuned on (I'll help you do this — it's built into the workflow).

---

## Phase 2 — Paper Trading (~3 months minimum)

**Goal:** run the strategy in real time with fake money and confirm live behavior matches the backtest.

What you do:
- Open a **free Alpaca paper trading account** (works from Malaysia, no deposit — it's a simulator with a real API). I can automate the daily signal → order flow for you.
- Every trading day after US close (9:30pm–5am Malaysia time — the nice thing about end-of-day: you check signals once, in the Malaysian morning, before US open): the system computes signals, you review, orders go in.
- Keep a trading journal (a simple spreadsheet — I'll set it up): every trade, why it was taken, and whether you were tempted to override the system. **The overrides are the data.** Most people fail live not because the strategy is bad but because they can't follow it.

**Gate to Phase 3:** 3+ months of paper trading where (a) your fills roughly match what the backtest predicted, (b) you followed the system ≥95% of the time, and (c) you experienced at least one losing streak without abandoning the rules.

---

## Phase 3 — Live, Small (~3–6 months)

**Goal:** trade real money small enough that mistakes are cheap.

What you do:
- Open a real brokerage account (see broker notes below). Fund it with **$2,500 — one quarter of the capital**. The rest stays in a savings account or money-market fund earning interest.
- Trade the exact system you paper traded. Same rules, same sizing (scaled to $2.5k).
- Real money feels different — this phase is about discovering whether *you* behave the same when losses are real.

**Gate to Phase 4:** 3+ months live where you followed the system, costs/slippage match expectations, and drawdown stayed within the historical envelope. Profitability in this phase is a bonus, not the gate.

---

## Phase 4 — Full Deployment (ongoing)

- Scale to the full $10k in steps ($2.5k → $5k → $10k, moving up only after each step behaves).
- Diversify: 2–3 uncorrelated strategies (e.g. trend + mean reversion) beat one strategy on more capital.
- Keep researching. Your edge decays; the process of finding and validating new edges is the actual job.

**Realistic expectations at full size:** a good retail systematic swing portfolio targets **8–15% per year** with drawdowns of 10–20%. On $10k that's $800–$1,500/year. You will not get rich on $10k — what you're building is a *skill and a verified process* that scales if you later add capital. Anyone promising more than ~20%/year sustained is selling something.

---

## Broker notes for Malaysia

| Option | Use for | Notes |
|---|---|---|
| **Alpaca (paper)** | Phase 2 | Free, sign up from anywhere, full API. Not for real money from Malaysia. |
| **Interactive Brokers** | Phase 3–4 (recommended) | Accepts Malaysian residents, ~USD 0.005/share commissions, rock-solid API for automation, access to all US ETFs. The standard choice for serious retail quants. |
| **moomoo MY (Futu)** | Alternative | Licensed by the Securities Commission Malaysia, cheap US stock trading, has an OpenAPI. Friendlier onboarding than IBKR. |

Things to know as a Malaysian trading US stocks:
- **Dividend withholding:** the US takes 30% of dividends (no US–Malaysia tax treaty). Our strategies profit mainly from price moves, so this is a minor drag, but prefer accumulating gains over high-dividend ETFs.
- **Capital gains:** Malaysia generally doesn't tax individuals on foreign share gains, but rules on foreign-source income remitted into Malaysia changed in 2022 — confirm your situation with a Malaysian tax advisor before Phase 3.
- **Currency:** your capital is MYR→USD. The USD/MYR rate will move your returns a few percent either way; convert once, keep the account in USD, don't churn currency.
- **MT5 / CFD brokers:** avoid trading US stocks as CFDs through MT5 brokers. Spreads, financing costs, and counterparty risk are all worse than owning the real shares through IBKR/moomoo.
