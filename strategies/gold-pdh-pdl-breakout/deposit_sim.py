"""Simulate monthly $100 deposits riding the bot's actual backtest trade sequence.

Each backtest trade is converted to a % return on the balance at that moment
(valid because auto-lot risks a fixed % of balance and recovery mode depends
only on the win/loss sequence, not on account size). That % sequence is then
replayed on an account receiving deposits.
"""
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
import pandas as pd

BASE = r"E:\Documents\Quant Trading\MT5"


def load_trades(csv):
    df = pd.read_csv(csv)
    df = df[df["Direction"].astype(str).str.strip() == "out"].copy()
    df["Profit"] = pd.to_numeric(df["Profit"].astype(str).str.replace(" ", "", regex=False),
                                 errors="coerce")
    df["Time"] = pd.to_datetime(df["Time"], format="%Y.%m.%d %H:%M:%S", errors="coerce")
    df = df.dropna(subset=["Time", "Profit"]).sort_values("Time")
    # % return of each trade on the balance it was taken with (original test: $10k start)
    bal = 10_000.0
    rets = []
    for p in df["Profit"]:
        rets.append(p / bal)
        bal += p
    df["ret"] = rets
    return df[["Time", "ret"]]


def simulate(trades, start=100.0, monthly=100.0):
    bal = start
    deposited = start
    cur_month = None
    rows = []
    worst_gap = 0.0  # most underwater vs money put in
    for t, r in zip(trades["Time"], trades["ret"]):
        m = (t.year, t.month)
        if cur_month is None:
            cur_month = m
        elif m != cur_month:
            # deposit on the 1st of each new month
            steps = (m[0] - cur_month[0]) * 12 + (m[1] - cur_month[1])
            for _ in range(steps):
                bal += monthly
                deposited += monthly
            cur_month = m
        bal *= (1 + r)
        worst_gap = min(worst_gap, bal - deposited)
        rows.append((t, bal, deposited))
    path = pd.DataFrame(rows, columns=["time", "balance", "deposited"])
    return path, worst_gap


def report(label, csv):
    trades = load_trades(csv)
    print(f"\n===== {label} =====")
    print(f"{'start':>8} {'monthly':>8} {'months':>7} {'deposited':>10} {'final':>10} "
          f"{'trading P/L':>12} {'worst gap':>10}")
    results = {}
    for start in (100.0, 500.0, 1000.0):
        path, gap = simulate(trades, start=start, monthly=100.0)
        months = path["time"].dt.to_period("M").nunique()
        dep = path["deposited"].iloc[-1]
        fin = path["balance"].iloc[-1]
        print(f"{start:>8.0f} {100:>8.0f} {months:>7d} {dep:>10.0f} {fin:>10.2f} "
              f"{fin - dep:>+12.2f} {gap:>+10.2f}")
        results[start] = path
    return results


res_2025 = report("2025-01 to 2026-07 (realistic mix, 18 months)", rf"{BASE}\deals_2025.csv")
res_2020 = report("2020-2022 (worst era, 36 months)", rf"{BASE}\deals_2020_v131.csv")

# monthly path of the headline scenario: start $100 + $100/month, 2025-26
path = res_2025[100.0].copy()
path["ym"] = path["time"].dt.to_period("M")
monthly = path.groupby("ym").last()[["balance", "deposited"]].round(2)
print("\nMonth-end path - start $100, +$100/month, 2025-2026 era:")
print(monthly.to_string())

# chart: balance vs money put in, both eras (start $100 + $100/month)
fig, axes = plt.subplots(1, 2, figsize=(13, 4.5))
for ax, (res, title) in zip(axes, [(res_2025, "2025-01 - 2026-07 era"),
                                   (res_2020, "2020-2022 era (worst case)")]):
    p = res[100.0]
    ax.plot(p["time"], p["balance"], label="Account balance", color="goldenrod", lw=1.6)
    ax.plot(p["time"], p["deposited"], label="Money you put in", color="gray", ls="--", lw=1.4)
    ax.fill_between(p["time"], p["deposited"], p["balance"],
                    where=p["balance"] >= p["deposited"], alpha=0.25, color="green")
    ax.fill_between(p["time"], p["deposited"], p["balance"],
                    where=p["balance"] < p["deposited"], alpha=0.25, color="red")
    ax.set_title(f"USD 100 start + 100/month - {title}")
    ax.legend()
    ax.grid(alpha=0.3)
fig.tight_layout()
out = rf"{BASE}\deposit_sim.png"
fig.savefig(out, dpi=110)
print(f"\nChart saved: {out}")
