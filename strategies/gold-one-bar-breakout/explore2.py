"""Stage 1b: D1 and H4 combination conditioning, TRAIN only (<2021)."""
import pandas as pd
import numpy as np
from pathlib import Path

DATA = Path(__file__).parent / "data"
COST = 0.35
SPLIT = pd.Timestamp("2021-01-01")


def pf(x, side=1, cost=COST):
    p = side * x - cost
    w, l = p[p > 0].sum(), -p[p <= 0].sum()
    return w / l if l > 0 else np.inf


def wr(x, side=1, cost=COST):
    p = side * x - cost
    return (p > 0).mean()


d1 = pd.read_parquet(DATA / "XAUUSD_D1.parquet")
d1["ret"] = d1["close"] - d1["open"]
d1["dow"] = d1["time"].dt.dayofweek
d1["prev"] = d1["ret"].shift(1)
d1["prev2"] = d1["ret"].shift(1) + d1["ret"].shift(2)
for n in (10, 20, 50, 100, 200):
    d1[f"sma{n}"] = d1["close"].rolling(n).mean().shift(1)
d1["atr"] = (d1["high"] - d1["low"]).rolling(14).mean().shift(1)
tr = d1[(d1["time"] < SPLIT) & (d1["time"] >= "2010-06-01")].copy()
e1cut = pd.Timestamp("2015-01-01")

def show(label, mask, side):
    x = tr.loc[mask, "ret"]
    if len(x) < 60:
        return
    a = tr.loc[mask & (tr["time"] < e1cut), "ret"]
    b = tr.loc[mask & (tr["time"] >= e1cut), "ret"]
    print(f"{label:55s} n={len(x):4d} mean={side*x.mean():+.2f} "
          f"netPF={pf(x,side):.3f} wr={wr(x,side):.2f} "
          f"[e1 {pf(a,side):.2f} n{len(a)} | e2 {pf(b,side):.2f} n{len(b)}]")

print("=== D1 LONGS (train) ===")
show("Fri", tr["dow"] == 4, 1)
for n in (20, 50, 100, 200):
    show(f"Fri & above SMA{n}", (tr["dow"] == 4) & (tr["open"] > tr[f"sma{n}"]), 1)
show("Fri & prev day down", (tr["dow"] == 4) & (tr["prev"] < 0), 1)
show("Fri & prev day up", (tr["dow"] == 4) & (tr["prev"] > 0), 1)
for n in (20, 50):
    show(f"Fri & aboveSMA{n} & prev dn", (tr["dow"] == 4) & (tr["open"] > tr[f"sma{n}"]) & (tr["prev"] < 0), 1)
    show(f"Fri & aboveSMA{n} & prev up", (tr["dow"] == 4) & (tr["open"] > tr[f"sma{n}"]) & (tr["prev"] > 0), 1)
show("ThuFri & above SMA50", (tr["dow"].isin([3, 4])) & (tr["open"] > tr["sma50"]), 1)
show("above SMA50 & prev dn (dip-buy)", (tr["open"] > tr["sma50"]) & (tr["prev"] < 0), 1)
show("above SMA50 & prev2 dn", (tr["open"] > tr["sma50"]) & (tr["prev2"] < 0), 1)
show("above SMA20&50 & prev dn", (tr["open"] > tr["sma50"]) & (tr["open"] > tr["sma20"]) & (tr["prev"] < 0), 1)
show("bigdown prev(<-1atr) ", tr["prev"] < -tr["atr"], 1)
show("bigdown prev & above sma200", (tr["prev"] < -tr["atr"]) & (tr["open"] > tr["sma200"]), 1)

print("\n=== D1 SHORTS (train) ===")
show("Mon", tr["dow"] == 0, -1)
show("Wed", tr["dow"] == 2, -1)
show("MonWed", tr["dow"].isin([0, 2]), -1)
for n in (20, 50):
    show(f"MonWed & below SMA{n}", (tr["dow"].isin([0, 2])) & (tr["open"] < tr[f"sma{n}"]), -1)
    show(f"Mon & below SMA{n}", (tr["dow"] == 0) & (tr["open"] < tr[f"sma{n}"]), -1)
    show(f"Wed & below SMA{n}", (tr["dow"] == 2) & (tr["open"] < tr[f"sma{n}"]), -1)
show("MonWed & prev up", (tr["dow"].isin([0, 2])) & (tr["prev"] > 0), -1)
show("below SMA50 & prev up (fade)", (tr["open"] < tr["sma50"]) & (tr["prev"] > 0), -1)
show("bigup prev(>1atr) & below sma200", (tr["prev"] > tr["atr"]) & (tr["open"] < tr["sma200"]), -1)

# H4 with D1-trend context
h4 = pd.read_parquet(DATA / "XAUUSD_H4.parquet")
h4["ret"] = h4["close"] - h4["open"]
h4["hour"] = h4["time"].dt.hour
h4["dow"] = h4["time"].dt.dayofweek
h4["prev"] = h4["ret"].shift(1)
h4["sma"] = h4["close"].rolling(300).mean().shift(1)  # ~50 days
trh = h4[(h4["time"] < SPLIT) & (h4["time"] >= "2010-06-01")].copy()

print("\n=== H4 combos (train) ===")
for hh in (0, 4):
    show2 = trh[(trh["hour"] == hh)]
    for label, mask, side in [
        (f"H4 h{hh} L & aboveSMA300", (trh["hour"] == hh) & (trh["open"] > trh["sma"]), 1),
        (f"H4 h{hh} L & aboveSMA & prev dn", (trh["hour"] == hh) & (trh["open"] > trh["sma"]) & (trh["prev"] < 0), 1),
        (f"H4 h{hh} L & Fri", (trh["hour"] == hh) & (trh["dow"] == 4), 1),
    ]:
        x = trh.loc[mask, "ret"]
        if len(x) < 60:
            continue
        a = trh.loc[mask & (trh["time"] < e1cut), "ret"]
        b = trh.loc[mask & (trh["time"] >= e1cut), "ret"]
        print(f"{label:55s} n={len(x):4d} mean={side*x.mean():+.2f} "
              f"netPF={pf(x,side):.3f} [e1 {pf(a,side):.2f} | e2 {pf(b,side):.2f}]")
h12 = trh[trh["hour"] == 12]
print(f"H4 h12 SHORT & belowSMA: netPF={pf(trh.loc[(trh['hour']==12)&(trh['open']<trh['sma']),'ret'],-1):.3f} "
      f"n={((trh['hour']==12)&(trh['open']<trh['sma'])).sum()}")
print(f"H4 h12 SHORT & Fri: netPF={pf(trh.loc[(trh['hour']==12)&(trh['dow']==4),'ret'],-1):.3f}")
