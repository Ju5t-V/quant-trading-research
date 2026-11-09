"""F1 screen: 15-min opening-range breakout, US500 + DE40, M5 data (2025-26 dev only;
2020-22 dev goes to the MT5 tester once the EA exists — no M5 history via API).

Locked spec: range = first 15min after cash open; stop entry at range extreme on a
later bar touch; SL = opposite extreme (pessimistic same-bar SL priority); no TP;
flat at session close. Cost 0.5 pts round trip. Sides reported separately (ablation).
"""
import pandas as pd
import numpy as np

COST = {"US500": 0.5, "DE40": 1.6}  # round-trip pts (spread + slippage margin)

def session_scan(sym):
    df = pd.read_parquet(rf"E:\Documents\Quant Trading\Index_Hunt\data\{sym}_M5.parquet")
    df["hm"] = df["time"].dt.strftime("%H:%M")
    rng = (df["high"] - df["low"]).groupby(df["hm"]).mean()
    top = rng.sort_values(ascending=False).head(8)
    print(f"{sym} biggest avg M5 ranges by time-of-day:\n{top.to_string()}\n")

def orb(sym, open_hm, close_hm, side):
    df = pd.read_parquet(rf"E:\Documents\Quant Trading\Index_Hunt\data\{sym}_M5.parquet")
    df = df[df["time"] >= "2025-01-01"].reset_index(drop=True)
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
        rng_bars = g.iloc[o:o + 3]
        if len(rng_bars) < 3:
            continue
        rh, rl = rng_bars["high"].max(), rng_bars["low"].min()
        close_idx = g.index[g["hm"] == close_hm]
        close_idx = close_idx[0] if len(close_idx) else len(g) - 1
        pos, entry = 0, 0.0
        pnl = None
        for k in range(o + 3, close_idx + 1):
            bar = g.iloc[k]
            if pos == 0:
                lb = side in ("long", "both") and bar["high"] > rh
                sb = side in ("short", "both") and bar["low"] < rl
                if lb and sb:
                    break  # ambiguous giant bar: skip day
                if lb:
                    pos, entry, sl = 1, max(rh, bar["open"]), rl
                    if bar["low"] <= sl:  # pessimistic: stopped same bar
                        pnl = sl - entry - cost
                        break
                elif sb:
                    pos, entry, sl = -1, min(rl, bar["open"]), rh
                    if bar["high"] >= sl:
                        pnl = entry - sl - cost
                        break
            elif pos == 1:
                if bar["low"] <= sl:
                    pnl = sl - entry - cost
                    break
            elif pos == -1:
                if bar["high"] >= sl:
                    pnl = entry - sl - cost
                    break
        if pos != 0 and pnl is None:
            c = g.iloc[close_idx]["open"]
            pnl = (c - entry - cost) if pos == 1 else (entry - c - cost)
        if pos != 0:
            trades.append(dict(d=d, pnl=pnl, side=pos))
    tr = pd.DataFrame(trades)
    if len(tr) == 0:
        print(f"  {sym} {side}: no trades")
        return
    w = tr.loc[tr.pnl > 0, "pnl"].sum()
    l = -tr.loc[tr.pnl <= 0, "pnl"].sum()
    pf = w / l if l > 0 else float("inf")
    print(f"  {sym} {side:5s}: n={len(tr)}  PF={pf:.2f}  win%={100*(tr.pnl>0).mean():.0f}"
          f"  net={tr.pnl.sum():+.1f}pts  avg={tr.pnl.mean():+.2f}")

for s in ("US500", "DE40"):
    session_scan(s)

print("== ORB dev 2025-26 ==")
for s, ohm, chm in (("US500", "16:30", "22:50"), ("DE40", "10:00", "18:55")):
    for side in ("long", "short", "both"):
        orb(s, ohm, chm, side)
