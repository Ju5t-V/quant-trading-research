"""Checks for the Dukascopy holdout data (run after convert, clean and bars).

1. Ticks per month (clean files) and anything missing.
2. Dukascopy vs MetaQuotes daily bars on the same server days (2021 - Apr 2025):
   typical high / low / close differences by year. Two feeds never match exactly,
   but a level-setting study needs them within cents-to-a-dollar, not tens of dollars.
3. Median spread by year (the holdout's cost level).
4. Session reopen time in UTC via the Europe/Athens server rule, as verify_data.py:
   gold reopens 22:00 UTC while New York is on daylight time, 23:00 UTC otherwise.
5. Hours still missing after the download retries.
"""
from pathlib import Path

import numpy as np
import pandas as pd
import pyarrow.parquet as pq

ROOT = Path(__file__).parent
CLEAN = ROOT / "data" / "duka_ticks_clean"
DAY_MS = 86_400_000

print("=== 1. ticks per month (clean)")
rows = []
for f in sorted(CLEAN.glob("XAUUSD_*.parquet")):
    rows.append(dict(month=f.stem[-6:], ticks=pq.ParquetFile(f).metadata.num_rows))
months = pd.DataFrame(rows)
if months.empty:
    raise SystemExit("no clean Dukascopy files yet")
months["year"] = months["month"].str[:4]
print(months.groupby("year")["ticks"].agg(["count", "sum", "min", "median"]).to_string())
low = months[months["ticks"] < months["ticks"].median() * 0.3]
print("months with < 30% of the median tick count:", ", ".join(low["month"]) or "none")
log = ROOT / "results" / "cleaning_log_duka.csv"
if log.exists():
    c = pd.read_csv(log, dtype={"month": str})
    print(f"cleaning removed {c['removed'].sum():,} of {c['ticks'].sum():,} ticks "
          f"({100 * c['removed'].sum() / c['ticks'].sum():.3f}%); worst month "
          f"{c.loc[c['removed_pct'].idxmax(), 'month']} ({c['removed_pct'].max():.3f}%)")

print("\n=== 2. Dukascopy vs MetaQuotes daily bars (same server day)")
def d1(path: Path) -> pd.DataFrame:
    d = pd.read_parquet(path, columns=["srv_ms", "high", "low", "close"])
    d.index = pd.to_datetime(d["srv_ms"] // DAY_MS * DAY_MS, unit="ms")
    return d[["high", "low", "close"]]
duka = d1(ROOT / "data" / "duka_bars" / "XAUUSD_D1.parquet")
mt5 = d1(ROOT / "data" / "bars" / "XAUUSD_D1.parquet")
m = duka.join(mt5, lsuffix="_duka", rsuffix="_mt5", how="inner")
m = m[(m.index >= "2021-01-01") & (m.index < "2025-05-01")]
for k in ("high", "low", "close"):
    m[f"d_{k}"] = (m[f"{k}_duka"] - m[f"{k}_mt5"]).abs()
m["year"] = m.index.year
out = m.groupby("year").agg(days=("d_high", "size"),
                            high_med=("d_high", "median"), high_p95=("d_high", lambda x: x.quantile(0.95)),
                            low_med=("d_low", "median"), low_p95=("d_low", lambda x: x.quantile(0.95)),
                            close_med=("d_close", "median"),
                            within_1usd_pct=("d_high", lambda x: 100 * (x <= 1.0).mean()))
print(out.round(2).to_string())
worst = m.assign(w=m[["d_high", "d_low"]].max(axis=1)).sort_values("w", ascending=False).head(5)
print("largest daily differences:")
print(worst[["high_duka", "high_mt5", "low_duka", "low_mt5", "w"]].round(2).to_string())

print("\n=== 3. median spread by year (points)")
sp = {}
for f in sorted(CLEAN.glob("XAUUSD_*.parquet")):
    t = pd.read_parquet(f, columns=["bid", "ask"])
    sp.setdefault(f.stem[-6:-2], []).append(float(((t["ask"] - t["bid"]) / 0.01).median()))
print({y: round(float(np.median(v)), 1) for y, v in sp.items()})

print("\n=== 4. session reopen time in UTC (Europe/Athens server rule)")
first = []
for f in sorted(CLEAN.glob("XAUUSD_*.parquet")):
    t = pd.read_parquet(f, columns=["srv_ms", "utc_ns"])
    srv_hour = (t["srv_ms"].to_numpy() % DAY_MS) / 3_600_000
    t = t[srv_hour < 3.0]
    g = t.groupby(t["srv_ms"].to_numpy() // DAY_MS)["utc_ns"].min()
    first.append(pd.Series(g.to_numpy(), index=pd.to_datetime(g.index.to_numpy() * DAY_MS, unit="ms")))
first = pd.concat(first)
first = first[(first.index.dayofweek < 5) & (first.index >= "2021-01-01")]
open_utc = pd.to_datetime(first.to_numpy(), unit="ns")
ny_dst = np.array([bool((pd.Timestamp(d) - pd.Timedelta(hours=6)).tz_localize("America/New_York").dst())
                   for d in first.index])
expected = np.where(ny_dst, 22.0, 23.0)
hour = (open_utc.hour + open_utc.minute / 60).to_numpy()
hour = np.where(hour < 12, hour + 24, hour)
diff = hour - expected
ok = (diff >= -0.01) & (diff <= 0.25)
print(f"{len(first)} weekdays: {ok.mean() * 100:.1f}% first tick within 15 min after the expected reopen; "
      f"one-hour offsets: {int((np.abs(np.abs(diff) - 1) < 0.25).sum())}")

print("\n=== 5. hours still missing after retries")
failed = ROOT / "results" / "duka_failed_hours.txt"
lines = [ln for ln in failed.read_text().splitlines() if ln.strip()] if failed.exists() else []
print(f"{len(lines)} failed hours" + (": " + ", ".join(lines[:10]) + (" ..." if len(lines) > 10 else "") if lines else ""))
