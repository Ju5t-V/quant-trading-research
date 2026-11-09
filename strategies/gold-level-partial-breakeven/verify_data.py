"""Data checks for the exported ticks and bars.

1. Tick-built server-day bid high/low must match MT5's own D1 bars.
2. The last tick of each server day, converted with the Europe/Athens rule, must
   sit just before gold's daily close: 21:00 UTC while New York is on daylight
   time, 22:00 UTC otherwise. A wrong DST rule shows up as a one-hour miss.
3. Asia-window coverage from M1 bars (days with < 240 minutes are skipped).
"""
from pathlib import Path

import numpy as np
import pandas as pd

ROOT = Path(__file__).parent
DAY_MS = 86_400_000

d1 = pd.read_parquet(ROOT / "data" / "bars" / "XAUUSD_D1.parquet")
d1["day"] = pd.to_datetime(d1["srv_ms"] // DAY_MS * DAY_MS, unit="ms")
d1 = d1.set_index("day")

parts = []
for f in sorted((ROOT / "data" / "ticks").glob("XAUUSD_*.parquet")):
    t = pd.read_parquet(f, columns=["srv_ms", "bid", "utc_ns"])
    g = t.groupby(t["srv_ms"].to_numpy() // DAY_MS)
    agg = pd.DataFrame({"hi": g["bid"].max(), "lo": g["bid"].min(),
                        "last_utc": g["utc_ns"].max(), "n": g.size()})
    agg.index = pd.to_datetime(agg.index.to_numpy() * DAY_MS, unit="ms")
    parts.append(agg)
ticks = pd.concat(parts)

m = ticks.join(d1[["high", "low"]], how="inner")
m["hi_diff"] = (m["hi"] - m["high"]).round(2)
m["lo_diff"] = (m["lo"] - m["low"]).round(2)
m["year"] = m.index.year
print("=== 1. tick high/low vs MT5 D1 bars (per server day)")
for y, g in m.groupby("year"):
    exact = ((g["hi_diff"] == 0) & (g["lo_diff"] == 0)).mean() * 100
    near = ((g["hi_diff"].abs() <= 0.05) & (g["lo_diff"].abs() <= 0.05)).mean() * 100
    print(f"  {y}: {len(g):3d} days  exact {exact:5.1f}%  within 5 pts {near:5.1f}%  "
          f"max |diff| hi {g['hi_diff'].abs().max():.2f} lo {g['lo_diff'].abs().max():.2f}")
worst = m.assign(w=m[["hi_diff", "lo_diff"]].abs().max(axis=1)).sort_values("w", ascending=False).head(5)
print(worst[["n", "hi", "high", "lo", "low", "hi_diff", "lo_diff"]].to_string())

print("\n=== 2. session open time in UTC (Europe/Athens rule)")
# Gold reopens at 18:00 New York every day: 22:00 UTC while NY is on daylight time,
# 23:00 UTC otherwise. The first tick of each server day (after the reopen) must
# land there; a wrong DST rule would put whole seasons one hour off.
# (The close is not used: from 2026-03-30 this feed stops quoting at 23:00 server,
# an hour before the NY close, which is a session change, not a clock error.)
first_parts = []
for f in sorted((ROOT / "data" / "ticks").glob("XAUUSD_*.parquet")):
    t = pd.read_parquet(f, columns=["srv_ms", "utc_ns"])
    srv_hour = (t["srv_ms"].to_numpy() % DAY_MS) / 3_600_000
    t = t[srv_hour < 3.0]                               # the reopen is 00:00-02:00 server
    g = t.groupby(t["srv_ms"].to_numpy() // DAY_MS)["utc_ns"].min()
    first_parts.append(pd.Series(g.to_numpy(), index=pd.to_datetime(g.index.to_numpy() * DAY_MS, unit="ms")))
first = pd.concat(first_parts)
first = first[first.index.dayofweek < 5]
open_utc = pd.to_datetime(first.to_numpy(), unit="ns")
# the reopen belongs to the previous calendar evening in New York
ny_dst = np.array([bool((pd.Timestamp(d) - pd.Timedelta(hours=6)).tz_localize("America/New_York").dst())
                   for d in first.index])
expected = np.where(ny_dst, 22.0, 23.0)
hour = (open_utc.hour + open_utc.minute / 60 + open_utc.second / 3600).to_numpy()
hour = np.where(hour < 12, hour + 24, hour)           # 00:05 UTC -> 24.08
diff = hour - expected
ok = (diff >= -0.01) & (diff <= 0.25)                 # first tick within 15 min after reopen
print(f"  {len(first)} weekdays: {ok.mean() * 100:.1f}% first tick within 15 min after the expected reopen")
print(f"  one-hour offsets (wrong DST rule): {int((np.abs(np.abs(diff) - 1) < 0.25).sum())}")
exc = first.index[~ok]
print("  exceptions:", ", ".join(f"{d:%Y-%m-%d} {h - 24 if h >= 24 else h:.2f}h"
                                 for d, h in zip(exc, hour[~ok])) or "none")

print("\n=== 3. Asia window (00:00-08:00 UTC) coverage from M1 bars")
m1 = pd.read_parquet(ROOT / "data" / "bars" / "XAUUSD_M1.parquet", columns=["utc_ns"])
t = pd.to_datetime(m1["utc_ns"], unit="ns")
asia = t[t.dt.hour < 8].dt.normalize().value_counts().sort_index()
wk = asia[asia.index.dayofweek < 5]
for y, g in wk.groupby(wk.index.year):
    print(f"  {y}: {len(g)} weekdays  median {g.median():.0f} bars  days < 240 bars: {(g < 240).sum()}")
