"""Fetch deep USTEC M1 history after MaxBars bump; fall back to M5 depth check."""
import time
from datetime import datetime, timezone, timedelta

import MetaTrader5 as mt5
import pandas as pd

if not mt5.initialize():
    raise SystemExit("attach failed")
mt5.symbol_select("USTEC", True)

frames = []
cur = datetime(2022, 7, 1, tzinfo=timezone.utc)
end = datetime(2026, 7, 18, tzinfo=timezone.utc)
while cur < end:
    nxt = min(cur + timedelta(days=45), end)
    r = None
    for _ in range(8):
        r = mt5.copy_rates_range("USTEC", mt5.TIMEFRAME_M1, cur, nxt)
        if r is not None and len(r) > 100:
            break
        time.sleep(3)
    n = 0 if r is None else len(r)
    print(f"{cur:%Y-%m}: {n} bars")
    if r is not None and n:
        frames.append(pd.DataFrame(r))
    cur = nxt
mt5.shutdown()

df = pd.concat(frames, ignore_index=True).drop_duplicates("time").sort_values("time").reset_index(drop=True)
df["dt"] = pd.to_datetime(df["time"], unit="s")
print(f"\nTOTAL: {len(df)} M1 bars  {df['dt'].iloc[0]} .. {df['dt'].iloc[-1]}")
df[["time", "open", "high", "low", "close", "tick_volume", "spread"]].to_parquet(
    r"E:\Documents\Quant Trading\QQQ\ustec_m1.parquet")
print("saved ustec_m1.parquet")
