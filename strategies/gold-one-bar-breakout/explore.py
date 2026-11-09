"""Stage 1: exploratory conditioning of single-candle open->close returns.
TRAIN ERA ONLY (< 2021-01-01). Test era untouched.
Cost model: $0.35/oz per round-trip trade (current demo spread 36 pts).
"""
import pandas as pd
import numpy as np
from pathlib import Path

DATA = Path(__file__).parent / "data"
COST = 0.35
SPLIT = pd.Timestamp("2021-01-01")


def load(tf):
    df = pd.read_parquet(DATA / f"XAUUSD_{tf}.parquet")
    df["ret"] = df["close"] - df["open"]          # $ per oz, one-candle hold
    df["hour"] = df["time"].dt.hour
    df["dow"] = df["time"].dt.dayofweek
    return df


def pf(x, side=1, cost=COST):
    """Profit factor of trading every row long (side=1) or short (-1), net of cost."""
    p = side * x - cost
    w, l = p[p > 0].sum(), -p[p <= 0].sum()
    return w / l if l > 0 else np.inf


def gross_pf(x, side=1):
    return pf(x, side, cost=0.0)


h1 = load("H1")
tr = h1[h1["time"] < SPLIT]
print(f"H1 train: {len(tr)} bars  {tr['time'].iloc[0].date()} -> {tr['time'].iloc[-1].date()}")
print(f"avg |close-open| = {tr['ret'].abs().mean():.2f} $/oz   cost = {COST}")

# --- hour of day (server time), split into two train sub-eras for stability ---
e1 = tr[tr["time"] < "2015-01-01"]
e2 = tr[tr["time"] >= "2015-01-01"]
print("\nHour | n | mean$ | grossPF_L e1 / e2 | netPF_L | netPF_S")
rows = []
for h in range(24):
    a, b, full = e1[e1["hour"] == h]["ret"], e2[e2["hour"] == h]["ret"], tr[tr["hour"] == h]["ret"]
    if len(full) < 100:
        continue
    rows.append((h, len(full), full.mean(), gross_pf(a), gross_pf(b),
                 pf(full, 1), pf(full, -1)))
for r in rows:
    print(f"{r[0]:4d} | {r[1]:5d} | {r[2]:+.3f} | {r[3]:.3f} / {r[4]:.3f} | {r[5]:.3f} | {r[6]:.3f}")

# --- weekday on D1 ---
d1 = load("D1")
trd = d1[d1["time"] < SPLIT]
print("\nD1 weekday | n | mean$ | grossPF_L | netPF_L | netPF_S")
for d in range(5):
    x = trd[trd["dow"] == d]["ret"]
    print(f"{d} | {len(x):4d} | {x.mean():+.2f} | {gross_pf(x):.3f} | {pf(x,1):.3f} | {pf(x,-1):.3f}")

# --- prev-bar momentum on H1 (all hours) ---
tr2 = tr.copy()
tr2["prev"] = tr2["ret"].shift(1)
up = tr2[tr2["prev"] > 0]["ret"]
dn = tr2[tr2["prev"] < 0]["ret"]
print(f"\nH1 after up-bar:  n={len(up)} mean={up.mean():+.3f} netPF_L={pf(up,1):.3f} netPF_S={pf(up,-1):.3f}")
print(f"H1 after dn-bar:  n={len(dn)} mean={dn.mean():+.3f} netPF_L={pf(dn,1):.3f} netPF_S={pf(dn,-1):.3f}")

# --- trend filter: open vs SMA of last N closes (D1 and H1) ---
for tf, df in [("D1", trd.copy()), ("H1", tr.copy())]:
    for n in (20, 50, 100):
        sma = df["close"].rolling(n).mean().shift(1)
        above = df[df["open"] > sma]["ret"]
        below = df[df["open"] < sma]["ret"]
        print(f"{tf} SMA{n}: above n={len(above)} mean={above.mean():+.3f} netPF_L={pf(above,1):.3f} | "
              f"below n={len(below)} mean={below.mean():+.3f} netPF_S={pf(below,-1):.3f}")

# --- H2/H4 hour-of-day (bigger candles, cost amortized better) ---
for tf in ("H2", "H4"):
    df = load(tf)
    t = df[df["time"] < SPLIT]
    print(f"\n{tf} train avg|ret|={t['ret'].abs().mean():.2f}")
    print(f"{tf} hour | n | mean$ | netPF_L | netPF_S")
    for h in sorted(t["hour"].unique()):
        x = t[t["hour"] == h]["ret"]
        if len(x) < 100:
            continue
        print(f"{h:4d} | {len(x):5d} | {x.mean():+.3f} | {pf(x,1):.3f} | {pf(x,-1):.3f}")
