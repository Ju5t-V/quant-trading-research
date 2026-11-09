"""
QQQ (Nasdaq-100 ETF) strategy backtest - fresh project.

Rules of the test:
  - $10,000 starting capital in every section, long only, no leverage.
  - Signals computed at each day's close, executed at the NEXT day's open
    (you cannot act on a close you haven't seen yet).
  - 0.1% commission/slippage per side.
  - Real QQQ daily data from Yahoo Finance (dividends included via adjustment).

Candidate strategies:
  BuyHold     - benchmark: buy on day one, never sell.
  GoldenCross - hold while SMA50 > SMA200, else cash. Classic trend following.
  SMA200Band  - hold while close > SMA200 +1%, cash when close < SMA200 -1%.
                Same idea, reacts faster, band cuts whipsaw.
  Momentum12m - month-end check: hold if price is above where it was 12 months
                ago, else cash. Time-series momentum, very few trades.
  DipBuyer    - mean reversion: in an uptrend (close > SMA200) buy RSI(2) < 10
                panic dips at next open, sell when close > SMA5; bail out if
                trend breaks or no bounce within 10 sessions.

Sections (like the gold bot tests): 2020-2022, 2023-2024, 2025-now, full 2005-now.
"""
from pathlib import Path

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
import pandas as pd
import yfinance as yf

HERE = Path(__file__).parent
RESULTS = HERE / "results"
RESULTS.mkdir(exist_ok=True)

TICKER = "QQQ"
CASH0 = 10_000.0
COMM = 0.001

SECTIONS = [
    ("2020-2022", "2020-01-01", "2022-12-31"),
    ("2023-2024", "2023-01-01", "2024-12-31"),
    ("2025-2026", "2025-01-01", None),
    ("Full 2005-2026", "2005-01-01", None),
]


def get_data():
    print(f"Downloading {TICKER} daily data ...")
    df = yf.download(TICKER, start="2003-01-01", auto_adjust=True, progress=False)
    if isinstance(df.columns, pd.MultiIndex):
        df.columns = df.columns.get_level_values(0)
    df = df[["Open", "High", "Low", "Close", "Volume"]].dropna()
    print(f"Got {len(df)} days: {df.index[0].date()} .. {df.index[-1].date()}")

    close = df["Close"]
    df["sma5"] = close.rolling(5).mean()
    df["sma50"] = close.rolling(50).mean()
    df["sma200"] = close.rolling(200).mean()
    df["mom252"] = close / close.shift(252) - 1
    delta = close.diff()
    gain = delta.clip(lower=0).ewm(alpha=1 / 2, min_periods=2).mean()
    loss = (-delta.clip(upper=0)).ewm(alpha=1 / 2, min_periods=2).mean()
    df["rsi2"] = 100 - 100 / (1 + gain / loss)
    # last trading day of each month (for the monthly momentum check)
    df["month_end"] = df.index.to_period("M") != df.index.to_period("M").shift(-1)
    df.loc[df.index[-1], "month_end"] = True
    return df


def simulate(df, start, end, decide):
    win = df.loc[start:] if end is None else df.loc[start:end]
    cash, shares = CASH0, 0
    pending = None
    entry_val = 0.0
    days_held = 0
    eq_curve = []
    trades = []

    for _, row in win.iterrows():
        o, c = row["Open"], row["Close"]
        if pending == "buy" and shares == 0:
            shares = int(cash * 0.95 / (o * (1 + COMM)))
            if shares > 0:
                cost = shares * o * (1 + COMM)
                cash -= cost
                entry_val = cost
                days_held = 0
        elif pending == "sell" and shares > 0:
            proceeds = shares * o * (1 - COMM)
            cash += proceeds
            trades.append(proceeds - entry_val)
            shares = 0
        pending = None

        if shares > 0:
            days_held += 1
        eq_curve.append(cash + shares * c)
        pending = decide(row, shares > 0, days_held)

    if shares > 0:
        trades.append(shares * win["Close"].iloc[-1] * (1 - COMM) - entry_val)

    return pd.Series(eq_curve, index=win.index), trades


# ------------------------------------------------------------- strategies

def buy_hold(row, in_pos, days_held):
    return None if in_pos else "buy"


def golden_cross(row, in_pos, days_held):
    if not in_pos and row["sma50"] > row["sma200"]:
        return "buy"
    if in_pos and row["sma50"] < row["sma200"]:
        return "sell"
    return None


def sma200_band(row, in_pos, days_held):
    if not in_pos and row["Close"] > row["sma200"] * 1.01:
        return "buy"
    if in_pos and row["Close"] < row["sma200"] * 0.99:
        return "sell"
    return None


def momentum_12m(row, in_pos, days_held):
    if not row["month_end"] or pd.isna(row["mom252"]):
        return None
    if not in_pos and row["mom252"] > 0:
        return "buy"
    if in_pos and row["mom252"] <= 0:
        return "sell"
    return None


def dip_buyer(row, in_pos, days_held):
    if not in_pos:
        if row["Close"] > row["sma200"] and row["rsi2"] < 10:
            return "buy"
    elif (row["Close"] > row["sma5"] or row["Close"] < row["sma200"]
          or days_held >= 10):
        return "sell"
    return None


STRATEGIES = [
    ("BuyHold", buy_hold),
    ("GoldenCross", golden_cross),
    ("SMA200Band", sma200_band),
    ("Momentum12m", momentum_12m),
    ("DipBuyer", dip_buyer),
]


def stats(eq, trades, label):
    ret = eq.iloc[-1] / CASH0 - 1
    years = (eq.index[-1] - eq.index[0]).days / 365.25
    cagr = (eq.iloc[-1] / CASH0) ** (1 / years) - 1 if years > 0.5 else ret
    dd = (eq / eq.cummax() - 1).min()
    wins = [t for t in trades if t > 0]
    losses = [t for t in trades if t <= 0]
    pf = (sum(wins) / -sum(losses)) if losses and sum(losses) < 0 else float("inf")
    return {
        "strategy": label,
        "final_$": round(eq.iloc[-1]),
        "return_%": round(100 * ret, 1),
        "CAGR_%": round(100 * cagr, 1),
        "maxDD_%": round(100 * dd, 1),
        "trades": len(trades),
        "win_%": round(100 * len(wins) / len(trades)) if trades else 0,
        "PF": round(pf, 2) if pf != float("inf") else "inf",
    }


def main():
    df = get_data()
    fig, axes = plt.subplots(2, 2, figsize=(14, 8))
    all_rows = []
    for ax, (name, start, end) in zip(axes.flat, SECTIONS):
        rows = []
        for label, fn in STRATEGIES:
            eq, trades = simulate(df, start, end, fn)
            rows.append(stats(eq, trades, label))
            ax.plot(eq.index, eq, label=label, lw=1.3)
        ax.set_title(f"{name}  (start $10k)")
        ax.legend(fontsize=8)
        ax.grid(alpha=0.3)
        if name.startswith("Full"):
            ax.set_yscale("log")
        print(f"\n===== {name} =====")
        print(pd.DataFrame(rows).to_string(index=False))
        all_rows += [dict(r, section=name) for r in rows]

    fig.tight_layout()
    fig.savefig(RESULTS / "qqq_sections.png", dpi=110)
    pd.DataFrame(all_rows).to_csv(RESULTS / "qqq_summary.csv", index=False)
    print(f"\nChart: QQQ/results/qqq_sections.png")


if __name__ == "__main__":
    main()
