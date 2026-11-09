# QQQ Trend Strategy

Standalone project: systematic end-of-day trading of QQQ (Nasdaq-100 ETF),
$10,000 starting capital, long only, no leverage.

## The strategy (Golden Cross trend following)

- **Hold QQQ while its 50-day average is above its 200-day average.**
- **Move to cash when the 50-day drops below the 200-day.**
- Signals are checked once per day after the US close; any trade executes at
  the next day's open. Expect roughly 1 trade per year.

Why it works: bull markets in the Nasdaq last years, and the worst crashes
(2008: -51%, 2022: -33%) happen almost entirely below the 200-day average.
Standing aside in downtrends keeps most of the upside while skipping the
worst of the damage. The cost is a lag at every turn: it re-enters late after
bottoms and gives back profit at tops.

## Backtest results (real QQQ data, next-open fills, 0.1% cost per side)

| Section | GoldenCross | Buy & Hold | GC drawdown | B&H drawdown |
|---|---|---|---|---|
| 2020-2022 | **+48.9%** | +25.5% | -27.1% | -34.1% |
| 2023-2024 | +74.6% | +88.5% | -13.0% | -13.1% |
| 2025-now | +20.7% | +38.8% | -21.0% | -21.0% |
| Full 2005-2026 | +948% (11.5%/yr) | +1,944% (15.1%/yr) | **-27.4%** | **-51.5%** |

Honest summary: buy-and-hold makes more in raw return over a full cycle.
The strategy's product is the drawdown column - roughly half the worst-case
loss - and its outperformance in bear-market eras (2020-2022). It is a
"sleep at night" version of owning the Nasdaq, not a money printer.

Alternatives tested and rejected (see `results/qqq_summary.csv`):
- SMA200Band (faster trend filter): similar, slightly lower return, lowest
  drawdowns; the runner-up.
- Momentum12m (12-month momentum, monthly check): similar to GoldenCross.
- DipBuyer (RSI-2 mean reversion): weak on QQQ (+1.1%/yr full period) -
  Nasdaq dips run too deep and trend too hard for tight mean reversion.

## Files

- `qqq_backtest.py` - downloads data, runs all strategies across all sections
- `results/qqq_sections.png` - equity curves per section
- `results/qqq_summary.csv` - all stats

Run with: `..\.venv\Scripts\python.exe qqq_backtest.py`

## Caveats

- ~14 trades in 21 years: the edge rests on the long-documented trend
  premium across markets, not statistical significance of this one sample.
- Backtest assumes fills at the open with 0.1% cost; real spreads on QQQ are
  tighter than that (conservative).
- No strategy here beats a strong bull market while holding cash part-time.
  The goal is surviving the next 2008/2022 with half the loss.
