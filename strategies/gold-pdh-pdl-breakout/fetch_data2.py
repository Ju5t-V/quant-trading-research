"""Force MT5 to fetch M1 history by requesting recent bars by position, in chunks."""
import sys
import time

import MetaTrader5 as mt5
import pandas as pd

if not mt5.initialize():
    print("initialize() failed:", mt5.last_error())
    sys.exit(1)

symbol = "XAUUSD"
mt5.symbol_select(symbol, True)

# Request most recent bars by position; MT5 pulls from the server on demand.
# Try progressively larger counts with retries while the download completes.
target = 260_000  # ~ 8 months of 23h/day M1 bars
rates = None
for attempt in range(12):
    rates = mt5.copy_rates_from_pos(symbol, mt5.TIMEFRAME_M1, 0, target)
    n = 0 if rates is None else len(rates)
    print(f"attempt {attempt + 1}: got {n} bars, last_error={mt5.last_error()}")
    if rates is not None and n >= target:
        break
    time.sleep(5)

if rates is None or len(rates) == 0:
    print("Still no data.")
    mt5.shutdown()
    sys.exit(1)

df = pd.DataFrame(rates)
df["time"] = pd.to_datetime(df["time"], unit="s")
mt5.shutdown()

print(f"Bars: {len(df)} | from {df['time'].iloc[0]} to {df['time'].iloc[-1]}")
weekday_spread = df.loc[df["time"].dt.dayofweek < 5, "spread"]
print(f"Median weekday spread: {weekday_spread.median()} pts")
df.to_csv(r"E:\Documents\Quant Trading\MT5\xauusd_m1.csv", index=False)
print("Saved.")
