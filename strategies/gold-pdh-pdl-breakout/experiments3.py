"""Round 3: trail distances wide enough to survive tick noise.
Real-tick test showed 50pt trail distance = consumed by spread/noise in seconds.
Wider trails (>=150pt dist) are much less distorted in bar sims, so screen here,
then validate winners on real ticks in the MT5 tester."""
from datetime import date

from backtest_gold import load_data, run, stats, show

m5, m1, d1 = load_data()
jan1, mar19 = date(2026, 1, 1), date(2026, 3, 19)

rows = []

def both(label, **kw):
    kw.setdefault("entry_hour", 6)
    kw.setdefault("sl_pts", 500)
    rows.append(stats(run(m1, d1, start=mar19, **kw), lots=1.0, label=f"M1 | {label}"))
    rows.append(stats(run(m5, d1, start=jan1, **kw), lots=1.0, label=f"M5f | {label}"))

both("trail 100/50 (v1.10 - tick test showed inflated)")
both("trail 200/100", trail_start=200, trail_dist=100)
both("trail 300/150", trail_start=300, trail_dist=150)
both("trail 400/200", trail_start=400, trail_dist=200)
both("trail 500/250", trail_start=500, trail_dist=250)
both("trail 300/200", trail_start=300, trail_dist=200)
both("trail 500/300", trail_start=500, trail_dist=300)
both("trail 200/150", trail_start=200, trail_dist=150)
both("no trail, TP1000 SL500 (2:1 RR)", trail_start=10**9)
both("no trail, TP1500 SL500 (3:1 RR)", trail_start=10**9, tp_pts=1500)
both("no trail, TP2000 SL500 (4:1)", trail_start=10**9, tp_pts=2000)

print("=" * 115)
print("ROUND 3 - all with entry_hour=6, SL500  ($ figures at 1.0 lot; M1=Mar19-Jul3, M5f=Jan1-Jul3)")
print("=" * 115)
show(rows)
