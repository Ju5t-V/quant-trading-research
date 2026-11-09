"""Fetch XAUUSD M1 history from MT5 in monthly chunks (stays under max-bars limit)."""
import sys
import time
from datetime import datetime, timezone

import MetaTrader5 as mt5
import pandas as pd

if not mt5.initialize():
    print("initialize() failed:", mt5.last_error())
    sys.exit(1)

symbol = "XAUUSD"
mt5.symbol_select(symbol, True)

months = [
    (datetime(2025, 12, 20, tzinfo=timezone.utc), datetime(2026, 1, 1, tzinfo=timezone.utc)),
    (datetime(2026, 1, 1, tzinfo=timezone.utc), datetime(2026, 2, 1, tzinfo=timezone.utc)),
    (datetime(2026, 2, 1, tzinfo=timezone.utc), datetime(2026, 3, 1, tzinfo=timezone.utc)),
    (datetime(2026, 3, 1, tzinfo=timezone.utc), datetime(2026, 4, 1, tzinfo=timezone.utc)),
    (datetime(2026, 4, 1, tzinfo=timezone.utc), datetime(2026, 5, 1, tzinfo=timezone.utc)),
    (datetime(2026, 5, 1, tzinfo=timezone.utc), datetime(2026, 6, 1, tzinfo=timezone.utc)),
    (datetime(2026, 6, 1, tzinfo=timezone.utc), datetime(2026, 7, 1, tzinfo=timezone.utc)),
    (datetime(2026, 7, 1, tzinfo=timezone.utc), datetime(2026, 7, 6, tzinfo=timezone.utc)),
]

frames = []
for start, end in months:
    rates = None
    for attempt in range(8):
        rates = mt5.copy_rates_range(symbol, mt5.TIMEFRAME_M1, start, end)
        if rates is not None and len(rates) > 0:
            break
        time.sleep(4)  # give the terminal time to download from server
    n = 0 if rates is None else len(rates)
    print(f"{start:%Y-%m}: {n} bars  (last_error={mt5.last_error()})")
    if rates is not None and n > 0:
        frames.append(pd.DataFrame(rates))

mt5.shutdown()

if not frames:
    print("No data at all.")
    sys.exit(1)

df = pd.concat(frames, ignore_index=True).drop_duplicates(subset="time").sort_values("time")
df["time"] = pd.to_datetime(df["time"], unit="s")
print(f"\nTotal bars: {len(df)} | from {df['time'].iloc[0]} to {df['time'].iloc[-1]}")
weekday = df.loc[df["time"].dt.dayofweek < 5, "spread"]
print(f"Median spread: {weekday.median()} pts | Price range: {df['low'].min():.2f} - {df['high'].max():.2f}")
df.to_csv(r"E:\Documents\Quant Trading\MT5\xauusd_m1.csv", index=False)
print("Saved to xauusd_m1.csv")
