"""Compare daily ATR across 2020-2022 vs 2026 to calibrate ATR scaling."""
import sys
import time
from datetime import datetime, timezone

import MetaTrader5 as mt5
import pandas as pd

if not mt5.initialize():
    print("initialize() failed:", mt5.last_error())
    sys.exit(1)
mt5.symbol_select("XAUUSD", True)

rates = None
for _ in range(8):
    rates = mt5.copy_rates_range("XAUUSD", mt5.TIMEFRAME_D1,
                                 datetime(2019, 11, 1, tzinfo=timezone.utc),
                                 datetime(2023, 1, 15, tzinfo=timezone.utc))
    if rates is not None and len(rates) > 0:
        break
    time.sleep(4)
mt5.shutdown()

old = pd.DataFrame(rates)
old["time"] = pd.to_datetime(old["time"], unit="s")
new = pd.read_csv(r"E:\Documents\Quant Trading\MT5\xauusd_d1.csv", parse_dates=["time"])

def add_atr(df, period=14):
    prev_close = df["close"].shift(1)
    tr = pd.concat([df["high"] - df["low"],
                    (df["high"] - prev_close).abs(),
                    (df["low"] - prev_close).abs()], axis=1).max(axis=1)
    df["atr"] = tr.rolling(period).mean()
    return df

old = add_atr(old)
new = add_atr(new)

old["year"] = old["time"].dt.year
print("ATR(14) D1 in $ (and % of price):")
for y in (2020, 2021, 2022):
    sub = old[old["year"] == y]
    print(f"  {y}: ATR ${sub['atr'].mean():.1f}  ({100 * (sub['atr'] / sub['close']).mean():.2f}% of price)  "
          f"close range {sub['close'].min():.0f}-{sub['close'].max():.0f}")
sub = new[new["time"] >= "2026-01-01"]
print(f"  2026: ATR ${sub['atr'].mean():.1f}  ({100 * (sub['atr'] / sub['close']).mean():.2f}% of price)  "
      f"close range {sub['close'].min():.0f}-{sub['close'].max():.0f}")
print(f"\n2026 mean ATR in points (point=0.01): {sub['atr'].mean() * 100:,.0f}")
