# Quant Trading Research

My systematic trading research: strategy ideas taken from hypothesis to backtest, ablation, out-of-sample holdout and real-tick validation in MetaTrader 5. Most ideas **failed**, and each report says so plainly. Rejecting a strategy honestly is part of the process.

**Tools:** Python (pandas, NumPy, backtesting.py, NautilusTrader), MQL5 / MetaTrader 5 Strategy Tester, Dukascopy tick data

## Structure

```
docs/          Roadmap, risk rules, and the research prompt template I use
etf-swing/     Starter end-of-day swing backtests on SPY (trend following vs mean reversion)
indicators/    Custom MT5 indicators (order-flow heatmap, absorption, sessions, Fibonacci BOS, MomoRider)
strategies/    One folder per research project, each with code, tester configs and a REPORT.md
```

## Strategy projects

| Folder | Market | Question | Outcome |
|---|---|---|---|
| `gold-pdh-pdl-breakout` | XAUUSD | Previous-day high/low stop-order breakout, with ATR scaling and recovery mode | ✅ Baseline EA, validated on real ticks 2020–22 and 2026 |
| `gold-one-bar-breakout` | XAUUSD | One-candle trades targeting a net profit factor ≥ 2 | ✅ Target met, with disclosed limits |
| `gold-level-partial-breakeven` | XAUUSD | Do partial take-profit and breakeven exits improve the breakout? (NautilusTrader) | ❌ No configuration passed the holdout |
| `high-volatility-breakout` | High-volatility pairs | Same method, targeting PF ≥ 2.5 | ❌ Not achievable honestly |
| `aoi-mean-reversion` | FX | Reproduce an "area of interest" mean-reversion system | ❌ No edge after fixing a lookahead bug |
| `eurusd-structure` | EURUSD | Mechanize an H4 market-structure continuation style | ❌ PF < 1 in every era |
| `nasdaq-qqq` | QQQ / US100 | End-of-day golden-cross trend following, plus intraday variants | ✅ Golden cross kept, dip-buying rejected |
| `index-strategy-hunt` | Indices | Pre-registered ORB, dip-buy and Donchian screens | Mixed. See report. |
| `ml-scalp-screen` | Multiple | Can machine learning find a scalping edge after costs? | ❌ No |
| `orderflow-futures` | MNQ / CFDs | Order-flow toolkit and an evidence-graded trading guide | Toolkit built. CFD volume found near-worthless. |

Raw market data and tick files are not included. Scripts reference local paths from my machine.

> ⚠️ Research and educational code only. Not financial advice. Backtests are not a promise of future results.
