"""Variant experiments for GoldBreakoutEA, run on M1 data (most accurate)."""
from datetime import date

import pandas as pd

from backtest_gold import load_data, run, stats, show

m5, m1, d1 = load_data()
jan1, mar19 = date(2026, 1, 1), date(2026, 3, 19)

# ---------------- loss anatomy on the baseline ----------------
tr = run(m1, d1, start=mar19)
tr["hour"] = pd.to_datetime(tr["t_in"]).dt.hour
tr["dow"] = pd.to_datetime(tr["t_in"]).dt.dayofweek
tr["win"] = tr["pts"] > 0

print("Baseline M1: PnL (points) by ENTRY HOUR (server time):")
byh = tr.groupby("hour")["pts"].agg(["count", "sum"]).rename(columns={"sum": "net_pts"})
print(byh.to_string())
print("\nPnL by DAY OF WEEK (0=Mon):")
print(tr.groupby("dow")["pts"].agg(["count", "sum"]).to_string())
print("\nPnL by DIRECTION:")
print(tr.groupby("dir")["pts"].agg(["count", "sum"]).to_string())
print("\nLosing trades:")
losers = tr[~tr["win"]].copy()
losers["t_in"] = pd.to_datetime(losers["t_in"])
print(losers[["t_in", "dir", "entry", "pts", "reason"]].to_string(index=False))

# ---------------- variant grid ----------------
rows = []

def both(label, **kw):
    """Run variant on M1 (accurate window) and M5 (full period)."""
    rows.append(stats(run(m1, d1, start=mar19, **kw), label=f"M1 | {label}"))
    rows.append(stats(run(m5, d1, start=jan1, **kw), label=f"M5full | {label}"))

both("baseline trail 100/50")
both("trail 200/100", trail_start=200, trail_dist=100)
both("trail 300/150", trail_start=300, trail_dist=150)
both("trail 500/250", trail_start=500, trail_dist=250)
both("trail 800/400", trail_start=800, trail_dist=400)
both("no trail (pure 1:1)", trail_start=10**9)
both("OCO (cancel other side)", oco=True)
both("SL 500 (tighter, TP 1000)", sl_pts=500)
both("SL 1500 TP 1500", sl_pts=1500, tp_pts=1500)
both("long only", allow_short=False)
both("trend filter MA20", trend_ma=20)
both("trend MA20 + trail 300/150", trend_ma=20, trail_start=300, trail_dist=150)
both("OCO + trail 300/150", oco=True, trail_start=300, trail_dist=150)

print("\n" + "=" * 110)
print("VARIANT GRID  (M1 rows = Mar19-Jul3, trustworthy; M5full rows = Jan1-Jul3, optimistic bias)")
print("=" * 110)
show(rows)
