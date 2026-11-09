"""F1 cell 2: literature-exact 5-min ORB (Zarattini/Aziz QQQ rule) on US500/DE40.
Enter at 2nd bar open in direction of 1st 5-min bar; stop = 1st bar opposite extreme
(cell a) or capped at 10% of ATR(14,D1) (cell b); exit at session close; no re-entry.
Dev 2025-26 only (M5 depth). PF computed on R-normalized returns (paper sizes by risk).
"""
import pandas as pd
import numpy as np

COST = {"US500": 0.5, "DE40": 1.6}

def run(sym, open_hm, close_hm, stop_mode, side_filter):
    df = pd.read_parquet(rf"E:\Documents\Quant Trading\Index_Hunt\data\{sym}_M5.parquet")
    df = df[df["time"] >= "2025-01-01"].reset_index(drop=True)
    d1 = pd.read_parquet(rf"E:\Documents\Quant Trading\Index_Hunt\data\{sym}_D1.parquet")
    d1["atr"] = (d1["high"] - d1["low"]).rolling(14).mean()
    atr_by_date = dict(zip(d1["time"].dt.date, d1["atr"].shift(1)))
    df["date"] = df["time"].dt.date
    df["hm"] = df["time"].dt.strftime("%H:%M")
    cost = COST[sym]
    trades = []
    for d, g in df.groupby("date"):
        g = g.reset_index(drop=True)
        o = g.index[g["hm"] == open_hm]
        if len(o) == 0:
            continue
        o = o[0]
        b1 = g.iloc[o]
        if o + 1 >= len(g):
            continue
        direction = 1 if b1["close"] > b1["open"] else -1 if b1["close"] < b1["open"] else 0
        if direction == 0 or (side_filter == "long" and direction < 0) \
           or (side_filter == "short" and direction > 0):
            continue
        entry = g.iloc[o + 1]["open"]
        atr = atr_by_date.get(d, np.nan)
        if stop_mode == "range":
            sl = b1["low"] if direction == 1 else b1["high"]
        else:
            if not np.isfinite(atr):
                continue
            slDist = 0.10 * atr
            sl = entry - direction * slDist
        risk = abs(entry - sl)
        if risk <= 0:
            continue
        close_idx = g.index[g["hm"] == close_hm]
        close_idx = close_idx[0] if len(close_idx) else len(g) - 1
        pnl = None
        for k in range(o + 1, close_idx + 1):
            bar = g.iloc[k]
            if direction == 1 and bar["low"] <= sl:
                pnl = sl - entry
                break
            if direction == -1 and bar["high"] >= sl:
                pnl = entry - sl
                break
        if pnl is None:
            c = g.iloc[close_idx]["open"]
            pnl = direction * (c - entry)
        pnl -= cost
        trades.append(dict(d=d, r=pnl / risk, pnl=pnl))
    tr = pd.DataFrame(trades)
    if len(tr) == 0:
        return
    w = tr.loc[tr.r > 0, "r"].sum()
    l = -tr.loc[tr.r <= 0, "r"].sum()
    pf = w / l if l > 0 else float("inf")
    print(f"  {sym} {stop_mode:5s} {side_filter:5s}: n={len(tr)}  PF(R)={pf:.2f}"
          f"  win%={100*(tr.r>0).mean():.0f}  sumR={tr.r.sum():+.1f}  netPts={tr.pnl.sum():+.1f}")

print("== 5-min ORB, paper-faithful, dev 2025-26 ==")
for sym, ohm, chm in (("US500", "16:30", "22:50"), ("DE40", "10:00", "18:55")):
    for stop_mode in ("range", "atr10"):
        for side in ("both", "long", "short"):
            run(sym, ohm, chm, stop_mode, side)
