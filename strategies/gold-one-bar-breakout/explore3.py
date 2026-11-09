"""Stage 2 exploration: breakout-continuation one-candle rules on H1/H2. TRAIN only (<2021).
Prior: prev-day H/L breakout momentum is the validated persistent gold edge.
"""
import pandas as pd
import numpy as np
from pathlib import Path

DATA = Path(__file__).parent / "data"
COST = 0.35
SPLIT = pd.Timestamp("2021-01-01")
E1CUT = pd.Timestamp("2015-01-01")


def pf(x, side, cost=COST):
    p = side * x - cost
    w, l = p[p > 0].sum(), -p[p <= 0].sum()
    return w / l if l > 0 else np.inf


def prep(tf):
    df = pd.read_parquet(DATA / f"XAUUSD_{tf}.parquet")
    df["ret"] = df["close"] - df["open"]
    df["hour"] = df["time"].dt.hour
    df["date"] = df["time"].dt.date
    # previous day's high/low from D1
    d1 = pd.read_parquet(DATA / "XAUUSD_D1.parquet")
    d1["date"] = d1["time"].dt.date
    d1["pdh"] = d1["high"].shift(1)
    d1["pdl"] = d1["low"].shift(1)
    d1["pdc"] = d1["close"].shift(1)
    df = df.merge(d1[["date", "pdh", "pdl", "pdc"]], on="date", how="left")
    df["atr_h"] = (df["high"] - df["low"]).rolling(24).mean().shift(1)
    return df


def show(df, label, mask, side, era_col="time"):
    tr = mask & (df["time"] < SPLIT) & (df["time"] >= pd.Timestamp("2010-06-01"))
    x = df.loc[tr, "ret"]
    if len(x) < 80:
        print(f"{label:60s} n={len(x)} (too few)")
        return
    a = df.loc[tr & (df["time"] < E1CUT), "ret"]
    b = df.loc[tr & (df["time"] >= E1CUT), "ret"]
    print(f"{label:60s} n={len(x):5d} mean={side*x.mean():+.3f} avg|r|={x.abs().mean():.2f} "
          f"netPF={pf(x,side):.3f} [e1 {pf(a,side):.2f} | e2 {pf(b,side):.2f}]")


h1 = prep("H1")
# fresh breakout: this bar OPENS beyond prev-day extreme AND previous bar's open did not
h1["prev_open"] = h1["open"].shift(1)
h1["prev_close"] = h1["close"].shift(1)
h1["prev_ret"] = h1["ret"].shift(1)

up_now = h1["open"] > h1["pdh"]
up_fresh = up_now & ~(h1["prev_open"] > h1["pdh"])          # first hour opening above
up_any = up_now
dn_now = h1["open"] < h1["pdl"]
dn_fresh = dn_now & ~(h1["prev_open"] < h1["pdl"])

# close-based cross: prev bar CLOSED above pdh (breakout close), enter next bar
up_x = (h1["prev_close"] > h1["pdh"]) & (h1["open"] > h1["pdh"])
dn_x = (h1["prev_close"] < h1["pdl"]) & (h1["open"] < h1["pdl"])

daytime = h1["hour"].between(6, 21)   # EA lesson: 00-05 breakouts were the stopouts

print("=== H1 breakout continuation LONGS (train) ===")
show(h1, "open>PDH any hour", up_any, 1)
show(h1, "open>PDH fresh", up_fresh, 1)
show(h1, "open>PDH fresh & h6-21", up_fresh & daytime, 1)
show(h1, "prevclose>PDH & open>PDH (cross-confirm)", up_x, 1)
show(h1, "cross-confirm & h6-21", up_x & daytime, 1)
show(h1, "cross-confirm & prev bar up", up_x & (h1["prev_ret"] > 0), 1)
show(h1, "cross-confirm & bigmove prev(>0.5atr)", up_x & (h1["prev_ret"] > 0.5 * h1["atr_h"]), 1)

print("\n=== H1 breakout continuation SHORTS (train) ===")
show(h1, "open<PDL any hour", dn_now, -1)
show(h1, "open<PDL fresh", dn_fresh, -1)
show(h1, "open<PDL fresh & h6-21", dn_fresh & daytime, -1)
show(h1, "prevclose<PDL & open<PDL", dn_x, -1)
show(h1, "cross-confirm & h6-21", dn_x & daytime, -1)
show(h1, "cross-confirm & prev bar dn", dn_x & (h1["prev_ret"] < 0), -1)

print("\n=== H1 big-bar continuation (vol thrust) ===")
big_up = h1["prev_ret"] > 1.0 * h1["atr_h"]
big_dn = h1["prev_ret"] < -1.0 * h1["atr_h"]
show(h1, "prev bar > +1 ATRh: follow long", big_up, 1)
show(h1, "prev bar > +1 ATRh: fade short", big_up, -1)
show(h1, "prev bar < -1 ATRh: follow short", big_dn, -1)
show(h1, "prev bar < -1 ATRh: fade long", big_dn, 1)
big_up2 = h1["prev_ret"] > 2.0 * h1["atr_h"]
big_dn2 = h1["prev_ret"] < -2.0 * h1["atr_h"]
show(h1, "prev bar > +2 ATRh: follow long", big_up2, 1)
show(h1, "prev bar < -2 ATRh: follow short", big_dn2, -1)
show(h1, "prev bar > +2 ATRh: fade short", big_up2, -1)
show(h1, "prev bar < -2 ATRh: fade long", big_dn2, 1)

h2 = prep("H2")
h2["prev_close"] = h2["close"].shift(1)
h2["prev_ret"] = h2["ret"].shift(1)
up2 = (h2["prev_close"] > h2["pdh"]) & (h2["open"] > h2["pdh"])
dn2 = (h2["prev_close"] < h2["pdl"]) & (h2["open"] < h2["pdl"])
print("\n=== H2 breakout continuation ===")
show(h2, "H2 cross-confirm long", up2, 1)
show(h2, "H2 cross-confirm short", dn2, -1)
show(h2, "H2 open>PDH long", h2["open"] > h2["pdh"], 1)
show(h2, "H2 open<PDL short", h2["open"] < h2["pdl"], -1)
