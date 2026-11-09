"""Fetch US500 M1 for the frozen-champion transfer test."""
import time
from datetime import datetime, timezone, timedelta

import MetaTrader5 as mt5
import pandas as pd

if not mt5.initialize():
    raise SystemExit("attach failed")
mt5.symbol_select("US500", True)
frames = []
cur = datetime(2022, 7, 1, tzinfo=timezone.utc)
end = datetime(2026, 7, 18, tzinfo=timezone.utc)
while cur < end:
    nxt = min(cur + timedelta(days=60), end)
    r = None
    for _ in range(6):
        r = mt5.copy_rates_range("US500", mt5.TIMEFRAME_M1, cur, nxt)
        if r is not None and len(r) > 100:
            break
        time.sleep(2)
    if r is not None and len(r):
        frames.append(pd.DataFrame(r))
    cur = nxt
mt5.shutdown()
df = pd.concat(frames, ignore_index=True).drop_duplicates("time").sort_values("time")
df["dt"] = pd.to_datetime(df["time"], unit="s")
print(f"US500 M1: {len(df)} bars {df['dt'].iloc[0]} .. {df['dt'].iloc[-1]}")
df[["time", "open", "high", "low", "close", "tick_volume", "spread"]].to_parquet(
    r"E:\Documents\Quant Trading\QQQ\us500_m1.parquet")
