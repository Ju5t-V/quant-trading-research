"""Formal sweep of the D1 one-candle rule family. Selection on TRAIN only.
Pre-registered: family = side x weekday-set x trend-filter x prev-day-sign.
Criteria: n_train >= 100, netPF > 1.3 in BOTH train sub-eras (<2015 / >=2015),
rank by train net PF. Winner gets ONE test look (2021+).
"""
import pandas as pd
import numpy as np
from pathlib import Path
from itertools import product

DATA = Path(__file__).parent / "data"
COST = 0.35
SPLIT = pd.Timestamp("2021-01-01")
E1CUT = pd.Timestamp("2015-01-01")

d1 = pd.read_parquet(DATA / "XAUUSD_D1.parquet")
d1["ret"] = d1["close"] - d1["open"]
d1["dow"] = d1["time"].dt.dayofweek
d1["prev"] = d1["ret"].shift(1)
for n in (20, 50, 100, 200):
    d1[f"sma{n}"] = d1["close"].rolling(n).mean().shift(1)
d1 = d1[d1["time"] >= "2010-06-01"].reset_index(drop=True)


def pf(x, side, cost=COST):
    p = side * x - cost
    w, l = p[p > 0].sum(), -p[p <= 0].sum()
    return w / l if l > 0 else np.inf


DOWSETS = {"Mon": [0], "Tue": [1], "Wed": [2], "Thu": [3], "Fri": [4],
           "MonTue": [0, 1], "MonWed": [0, 2], "ThuFri": [3, 4], "All": [0, 1, 2, 3, 4]}
TRENDS = ["none", "sma20", "sma50", "sma100", "sma200"]
PREVS = ["none", "dn", "up"]

rows = []
for side_name, side in [("L", 1), ("S", -1)]:
    for dset, trend, prev in product(DOWSETS, TRENDS, PREVS):
        mask = d1["dow"].isin(DOWSETS[dset])
        if trend != "none":
            sma = d1[trend]
            mask &= (d1["open"] > sma) if side == 1 else (d1["open"] < sma)
        if prev == "dn":
            mask &= d1["prev"] < 0
        elif prev == "up":
            mask &= d1["prev"] > 0
        tr_mask = mask & (d1["time"] < SPLIT)
        x = d1.loc[tr_mask, "ret"]
        if len(x) < 100:
            continue
        a = d1.loc[tr_mask & (d1["time"] < E1CUT), "ret"]
        b = d1.loc[tr_mask & (d1["time"] >= E1CUT), "ret"]
        pfa, pfb = pf(a, side), pf(b, side)
        rows.append(dict(side=side_name, dow=dset, trend=trend, prev=prev,
                         n=len(x), pf_train=pf(x, side), pf_e1=pfa, pf_e2=pfb,
                         qualifies=(pfa > 1.3 and pfb > 1.3)))

df = pd.DataFrame(rows).sort_values("pf_train", ascending=False)
print(f"total configs evaluated: {len(df)}")
print("\n=== TOP 12 by train net PF ===")
print(df.head(12).to_string(index=False, float_format=lambda v: f"{v:.3f}"))
q = df[df["qualifies"]]
print(f"\n=== QUALIFYING (both sub-eras > 1.3): {len(q)} ===")
print(q.to_string(index=False, float_format=lambda v: f"{v:.3f}"))

if len(q):
    w = q.iloc[0]
    print(f"\n*** WINNER (frozen): {w['side']} {w['dow']} {w['trend']} prev={w['prev']} ***")
    mask = d1["dow"].isin(DOWSETS[w["dow"]])
    if w["trend"] != "none":
        sma = d1[w["trend"]]
        mask &= (d1["open"] > sma) if w["side"] == "L" else (d1["open"] < sma)
    if w["prev"] == "dn":
        mask &= d1["prev"] < 0
    elif w["prev"] == "up":
        mask &= d1["prev"] > 0
    side = 1 if w["side"] == "L" else -1
    te = d1.loc[mask & (d1["time"] >= SPLIT), "ret"]
    trx = d1.loc[mask & (d1["time"] < SPLIT), "ret"]
    print(f"TRAIN: n={len(trx)} netPF={pf(trx,side):.3f}")
    print(f"TEST (2021-2026.5, single look): n={len(te)} netPF={pf(te,side):.3f} "
          f"mean={side*te.mean():+.2f} wr={((side*te-COST)>0).mean():.2f}")
    # yearly
    sub = d1.loc[mask].copy()
    sub["year"] = sub["time"].dt.year
    sub["pnl"] = side * sub["ret"] - COST
    print("\nyear  n  netPF  sum$")
    for y, g in sub.groupby("year"):
        print(f"{y}  {len(g):3d}  {pf(g['ret'],side):5.2f}  {g['pnl'].sum():+8.1f}")
