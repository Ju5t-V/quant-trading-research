"""Fetch XAUUSD M5 and D1 history from MT5 covering Dec 2025 - Jul 2026."""
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

def fetch(timeframe, label, start, end, chunks):
    frames = []
    bounds = pd.date_range(start, end, periods=chunks + 1)
    for i in range(chunks):
        s = bounds[i].to_pydatetime().replace(tzinfo=timezone.utc)
        e = bounds[i + 1].to_pydatetime().replace(tzinfo=timezone.utc)
        rates = None
        for _ in range(8):
            rates = mt5.copy_rates_range(symbol, timeframe, s, e)
            if rates is not None and len(rates) > 0:
                break
            time.sleep(4)
        n = 0 if rates is None else len(rates)
        print(f"{label} chunk {s:%Y-%m-%d}..{e:%Y-%m-%d}: {n} bars")
        if rates is not None and n > 0:
            frames.append(pd.DataFrame(rates))
    if not frames:
        return None
    df = pd.concat(frames, ignore_index=True).drop_duplicates(subset="time").sort_values("time")
    df["time"] = pd.to_datetime(df["time"], unit="s")
    return df

start = datetime(2025, 12, 20, tzinfo=timezone.utc)
end = datetime(2026, 7, 6, tzinfo=timezone.utc)

m5 = fetch(mt5.TIMEFRAME_M5, "M5", start, end, 4)
d1 = fetch(mt5.TIMEFRAME_D1, "D1", start, end, 1)
mt5.shutdown()

if m5 is None or d1 is None:
    print("Fetch failed.")
    sys.exit(1)

print(f"\nM5: {len(m5)} bars, {m5['time'].iloc[0]} .. {m5['time'].iloc[-1]}")
print(f"D1: {len(d1)} bars, {d1['time'].iloc[0]} .. {d1['time'].iloc[-1]}")
m5.to_csv(r"E:\Documents\Quant Trading\MT5\xauusd_m5.csv", index=False)
d1.to_csv(r"E:\Documents\Quant Trading\MT5\xauusd_d1.csv", index=False)
print("Saved xauusd_m5.csv and xauusd_d1.csv")
