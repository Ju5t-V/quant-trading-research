"""Final comparison: original settings vs improved settings. Saves equity chart + trade list."""
from datetime import date

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
import pandas as pd

from backtest_gold import load_data, run, stats, show

m5, m1, d1 = load_data()
jan1, mar19 = date(2026, 1, 1), date(2026, 3, 19)

LOTS = 0.2  # 2% auto-lot sizing on $10k with 500pt SL -> 0.4 lots; show conservative 0.2 too
BAL = 10_000

configs = {
    "Original (00:00, SL1000)": dict(),
    "Improved (06:00, SL500)": dict(entry_hour=6, sl_pts=500),
}

fig, axes = plt.subplots(1, 2, figsize=(14, 5))
rows = []
for ax, (bars, st, title) in zip(
        axes, [(m1, mar19, "M1 data (accurate), Mar 19 - Jul 3"),
               (m5, jan1, "M5 data (optimistic), Jan 1 - Jul 3")]):
    for name, kw in configs.items():
        tr = run(bars, d1, start=st, **kw)
        rows.append(stats(tr, lots=2.0, balance=BAL, label=f"{title[:2]} | {name} | 2.0 lots"))
        eq = BAL + (tr["pts"] * 2.0).cumsum()  # $1/pt/lot * 2 lots
        ax.plot(pd.to_datetime(tr["t_out"]), eq, label=name, linewidth=1.8)
    ax.set_title(title)
    ax.set_ylabel("Equity ($, 2.0 lots, closed trades)")
    ax.legend()
    ax.grid(alpha=0.3)
fig.tight_layout()
fig.savefig(r"E:\Documents\Quant Trading\MT5\equity_comparison.png", dpi=110)
print("Chart saved: equity_comparison.png\n")
show(rows)

# save improved trade list
tr = run(m5, d1, start=jan1, entry_hour=6, sl_pts=500)
tr.to_csv(r"E:\Documents\Quant Trading\MT5\trades_improved.csv", index=False)

# worst-case day check for the improved config (both sides lose same day)
tr["day"] = pd.to_datetime(tr["t_out"]).dt.date
daily = tr.groupby("day")["pts"].sum()
print(f"\nImproved config, M5 full period: worst day {daily.min():,.0f} pts, "
      f"best day {daily.max():,.0f} pts, days traded {len(daily)}")
print(f"Risk per trade at 2.0 lots with SL500: $1,000 | at 0.4 lots (2% auto): $200")
