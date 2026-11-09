"""Round 2: entry-hour filter (skip thin Asian session) + tighter SL combos."""
from datetime import date

import pandas as pd

from backtest_gold import load_data, run as base_run, stats, show, POINT

m5, m1, d1 = load_data()
jan1, mar19 = date(2026, 1, 1), date(2026, 3, 19)


def run(bars, d1, entry_hour=0, **kw):
    """Wrap engine: orders are placed at entry_hour instead of day open.
    Implemented by dropping bars before entry_hour each day for order
    placement/trigger purposes is WRONG for open positions (trailing must see
    all bars), so instead we pass a mask via a pre-filter trick:
    simplest faithful approach = shift each day's 'first bar' to entry_hour by
    removing earlier bars ONLY on days where no position is open... To stay
    exact, we re-implement placement timing by filtering pendings inside the
    engine would be needed; instead we approximate exactly by noting the EA
    change: orders placed at entry_hour with gap-skip vs that bar's open.
    Trailing of positions opened SAME day is unaffected by earlier bars
    (position can't exist before its pending is placed). Overnight positions:
    they exited via engine on full bars anyway - so we must NOT drop bars.
    => engine now supports entry_hour natively (added param below)."""
    return base_run(bars, d1, entry_hour=entry_hour, **kw)


# --- add native entry_hour support to the engine ---
# (monkey-patch style would be messy; backtest_gold.run was updated instead)

rows = []

def both(label, **kw):
    rows.append(stats(base_run(m1, d1, start=mar19, **kw), label=f"M1 | {label}"))
    rows.append(stats(base_run(m5, d1, start=jan1, **kw), label=f"M5full | {label}"))

both("baseline (place 00:00)")
both("place orders 06:00", entry_hour=6)
both("place orders 08:00", entry_hour=8)
both("place 06:00 + SL500", entry_hour=6, sl_pts=500)
both("place 08:00 + SL500", entry_hour=8, sl_pts=500)
both("place 06:00 + SL500 + spread20", entry_hour=6, sl_pts=500, spread_pts=20)
both("SL500 only + spread20", sl_pts=500, spread_pts=20)

print("=" * 110)
print("ROUND 2  (M1 = Mar19-Jul3 accurate; M5full = Jan1-Jul3 optimistic)")
print("=" * 110)
show(rows)

# monthly consistency of the leading candidate on both datasets
for name, bars, st in [("M1", m1, mar19), ("M5full", m5, jan1)]:
    tr = base_run(bars, d1, start=st, entry_hour=6, sl_pts=500)
    tr["month"] = pd.to_datetime(tr["t_out"]).dt.to_period("M")
    print(f"\nMonthly net points - 'place 06:00 + SL500' on {name}:")
    print(tr.groupby("month")["pts"].agg(["count", "sum"]).to_string())
