"""
Backtesting engine — tests two classic end-of-day swing strategies on real data.

You don't need to edit this file. Run it with run_backtest.bat.

What it does:
  1. Downloads ~20 years of daily SPY data (the S&P 500 ETF) from Yahoo Finance.
  2. Tests two strategies, each starting with $10,000:
       - TrendFollowing : own SPY while its 50-day average is above its 200-day
                          average (a "golden cross"); move to cash otherwise.
       - MeanReversion  : in a healthy uptrend (price above 200-day average),
                          buy 2-day RSI panic dips (<10) and sell the bounce
                          (close back above the 5-day average).
  3. Prints a comparison against simply buying-and-holding SPY.
  4. Saves full stats, the list of every trade, and an interactive chart for
     each strategy into the results folder.

Realism settings: trades execute at the NEXT day's open (you can't act on a
close you haven't seen yet), and every trade pays 0.1% commission/slippage.
"""

import sys
import warnings
from pathlib import Path

import pandas as pd
import yfinance as yf
from backtesting import Backtest, Strategy
from backtesting.lib import crossover

warnings.filterwarnings("ignore")

HERE = Path(__file__).parent
RESULTS = HERE / "results"
RESULTS.mkdir(exist_ok=True)

TICKER = "SPY"
START = "2005-01-01"          # includes 2008, 2020 and 2022 bear markets
STARTING_CASH = 10_000
COMMISSION = 0.001            # 0.1% per side — conservative for IBKR/moomoo


# ---------------------------------------------------------------- indicators

def SMA(values, n):
    """Simple moving average of the last n days."""
    return pd.Series(values).rolling(n).mean()


def RSI(values, n):
    """Wilder's RSI: 0-100 gauge of how overbought (high) / oversold (low)
    the last n days have been."""
    close = pd.Series(values)
    delta = close.diff()
    gain = delta.clip(lower=0).ewm(alpha=1 / n, min_periods=n).mean()
    loss = (-delta.clip(upper=0)).ewm(alpha=1 / n, min_periods=n).mean()
    return 100 - 100 / (1 + gain / loss)


# ---------------------------------------------------------------- strategies

class TrendFollowing(Strategy):
    """Golden cross trend following.

    Edge: big bull markets last years; big bear markets happen below the
    200-day average. Holding only when trend is up keeps most of the upside
    while skipping the worst crashes. Trades rarely (a few times a decade).
    """
    fast, slow = 50, 200

    def init(self):
        self.sma_fast = self.I(SMA, self.data.Close, self.fast)
        self.sma_slow = self.I(SMA, self.data.Close, self.slow)

    def next(self):
        if crossover(self.sma_fast, self.sma_slow):
            self.buy(size=0.95)                      # invest 95%, keep cash buffer
        elif crossover(self.sma_slow, self.sma_fast):
            self.position.close()


class MeanReversion(Strategy):
    """RSI(2) dip buying (Larry Connors style).

    Edge: in an uptrend, sharp 2-3 day selloffs in a broad index usually
    snap back within days. Only trades WITH the long-term trend (price above
    200-day average) — buying dips in a bear market is catching knives.
    Many small quick trades; high win rate, small average win.
    """
    rsi_buy_below = 10

    def init(self):
        self.sma200 = self.I(SMA, self.data.Close, 200)
        self.sma5 = self.I(SMA, self.data.Close, 5)
        self.rsi2 = self.I(RSI, self.data.Close, 2)

    def next(self):
        price = self.data.Close[-1]
        if not self.position:
            if price > self.sma200[-1] and self.rsi2[-1] < self.rsi_buy_below:
                self.buy(size=0.95)
        elif price > self.sma5[-1]:                  # bounce done — take it
            self.position.close()


# ------------------------------------------------------------------- helpers

def get_data(ticker):
    print(f"Downloading {ticker} daily data since {START} ...")
    df = yf.download(ticker, start=START, auto_adjust=True, progress=False)
    if df is None or df.empty:
        sys.exit("Download failed — check your internet connection and retry.")
    if isinstance(df.columns, pd.MultiIndex):        # newer yfinance format
        df.columns = df.columns.get_level_values(0)
    df = df[["Open", "High", "Low", "Close", "Volume"]].dropna()
    print(f"Got {len(df)} trading days ({df.index[0].date()} to {df.index[-1].date()}).\n")
    return df


def run(strategy_cls, data, name):
    bt = Backtest(data, strategy_cls, cash=STARTING_CASH,
                  commission=COMMISSION, exclusive_orders=True)
    stats = bt.run()

    # save everything for later study
    (RESULTS / f"{name}_stats.txt").write_text(str(stats), encoding="utf-8")
    stats._trades.to_csv(RESULTS / f"{name}_trades.csv", index=False)
    try:
        bt.plot(filename=str(RESULTS / f"{name}_chart.html"), open_browser=False)
    except Exception as e:
        print(f"  (chart for {name} skipped: {e})")
    return stats


def row(stats, key, fmt="{:,.1f}"):
    try:
        return fmt.format(stats[key])
    except (KeyError, ValueError, TypeError):
        return "n/a"


def main():
    data = get_data(TICKER)

    results = {}
    for cls, name in [(TrendFollowing, "TrendFollowing"),
                      (MeanReversion, "MeanReversion")]:
        print(f"Backtesting {name} ...")
        results[name] = run(cls, data, name)

    bh_return = results["TrendFollowing"]["Buy & Hold Return [%]"]
    bh_final = STARTING_CASH * (1 + bh_return / 100)

    print("\n" + "=" * 78)
    print(f"  RESULTS - {TICKER}, $10,000 starting capital, "
          f"{data.index[0].year}-{data.index[-1].year}, costs included")
    print("=" * 78)
    header = f"  {'':28}{'TrendFollowing':>16}{'MeanReversion':>16}{'Buy & Hold':>14}"
    print(header)
    print("  " + "-" * 74)

    def line(label, key, fmt="{:,.1f}", bh=""):
        a = row(results['TrendFollowing'], key, fmt)
        b = row(results['MeanReversion'], key, fmt)
        print(f"  {label:28}{a:>16}{b:>16}{str(bh):>14}")

    line("Final equity ($)", "Equity Final [$]", "{:,.0f}", f"{bh_final:,.0f}")
    line("Total return (%)", "Return [%]", "{:,.1f}", f"{bh_return:,.1f}")
    line("Annual return / CAGR (%)", "Return (Ann.) [%]")
    line("Worst drawdown (%)", "Max. Drawdown [%]")
    line("Number of trades", "# Trades", "{:,.0f}")
    line("Win rate (%)", "Win Rate [%]")
    line("Sharpe ratio", "Sharpe Ratio", "{:,.2f}")
    line("Time in market (%)", "Exposure Time [%]")

    print("\n  Full stats:   results\\<name>_stats.txt")
    print("  Every trade:  results\\<name>_trades.csv")
    print("  Charts:       results\\<name>_chart.html  (open in your browser)")


if __name__ == "__main__":
    main()
