"""Fetch deep XAUUSD M1 (2022-07 .. 2026-07) after MaxBars unlock."""
import time
from datetime import datetime, timezone, timedelta

import MetaTrader5 as mt5
import pandas as pd

if not mt5.initialize():
    raise SystemExit("attach failed")
mt5.symbol_select("XAUUSD", True)
frames = []
cur = datetime(2022, 6, 15, tzinfo=timezone.utc)
end = datetime(2026, 7, 18, tzinfo=timezone.utc)
while cur < end:
    nxt = min(cur + timedelta(days=45), end)
    r = None
    for _ in range(8):
        r = mt5.copy_rates_range("XAUUSD", mt5.TIMEFRAME_M1, cur, nxt)
        if r is not None and len(r) > 100:
            break
        time.sleep(3)
    if r is not None and len(r):
        frames.append(pd.DataFrame(r))
    cur = nxt
mt5.shutdown()
df = pd.concat(frames, ignore_index=True).drop_duplicates("time").sort_values("time")
df["dt"] = pd.to_datetime(df["time"], unit="s")
print(f"XAUUSD M1: {len(df)} bars  {df['dt'].iloc[0]} .. {df['dt'].iloc[-1]}")
df[["time", "open", "high", "low", "close", "spread"]].to_parquet(
    r"E:\Documents\Quant Trading\QQQ\xauusd_m1_deep.parquet")
print("saved xauusd_m1_deep.parquet")
