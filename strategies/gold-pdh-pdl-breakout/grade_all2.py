"""Grade all Smith signals, each year on the finest data available:
2022-2026 -> M15, 2021 -> H1 (coarser, flagged). Raw + managed."""
import json
import sys
import time
from datetime import datetime, timezone, timedelta

import MetaTrader5 as mt5
import numpy as np
import pandas as pd

sys.stdout.reconfigure(encoding="utf-8", errors="replace")
sig = json.load(open(r"E:\Documents\Quant Trading\MT5\smith_signals.json"))
if not mt5.initialize():
    raise SystemExit("attach failed")
mt5.symbol_select("XAUUSD", True)


def pull(tf, a, b):
    frames = []
    cur = a
    while cur < b:
        nxt = min(cur + timedelta(days=160), b)
        r = None
        for _ in range(6):
            r = mt5.copy_rates_range("XAUUSD", tf, cur, nxt)
            if r is not None and len(r) > 5:
                break
            time.sleep(2)
        if r is not None and len(r):
            frames.append(pd.DataFrame(r))
        cur = nxt
    d = pd.concat(frames, ignore_index=True).drop_duplicates("time").sort_values("time").reset_index(drop=True)
    d["dt"] = pd.to_datetime(d["time"], unit="s")
    return d


d15 = pull(mt5.TIMEFRAME_M15, datetime(2022, 1, 1, tzinfo=timezone.utc), datetime(2026, 7, 18, tzinfo=timezone.utc))
d1h = pull(mt5.TIMEFRAME_H1, datetime(2021, 1, 1, tzinfo=timezone.utc), datetime(2022, 1, 10, tzinfo=timezone.utc))
mt5.shutdown()
print(f"M15: {d15['dt'].iloc[0]} .. {d15['dt'].iloc[-1]} ({len(d15)})")
print(f"H1 : {d1h['dt'].iloc[0]} .. {d1h['dt'].iloc[-1]} ({len(d1h)})")

DS = {}
for name, d in [("m15", d15), ("h1", d1h)]:
    DS[name] = dict(dt=d["dt"].values, hi=d["high"].values, lo=d["low"].values,
                    cl=d["close"].values, op=d["open"].values, tab=d)


def eu_dst(dt):
    y = dt.year
    mar = max(dd for dd in range(25, 32) if datetime(y, 3, dd).weekday() == 6)
    oc = max(dd for dd in range(25, 32) if datetime(y, 10, dd).weekday() == 6)
    return datetime(y, 3, mar, 1) <= dt < datetime(y, 10, oc, 1)


def grade(s, managed):
    ds = DS["h1"] if s["dt"][:4] == "2021" else DS["m15"]
    d, entry, sl, tps = s["dir"], s["entry"], s["sl"], list(s["tps"])
    while len(tps) < 4:
        tps.append(None)
    tps = tps[:4]
    utc = datetime.fromtimestamp(s["utc"], timezone.utc).replace(tzinfo=None)
    srv = utc + timedelta(hours=3 if eu_dst(utc) else 2)
    i0 = ds["tab"]["dt"].searchsorted(pd.Timestamp(srv))
    n = len(ds["hi"])
    if i0 >= n:
        return None
    lo_w = ds["lo"][max(0, i0 - 2):i0 + 3].min()
    hi_w = ds["hi"][max(0, i0 - 2):i0 + 3].max()
    entry_ok = lo_w - 3 <= entry <= hi_w + 3
    risk = abs(entry - sl)
    if risk <= 0:
        return None
    span = 288 if ds is DS["m15"] else 72   # ~3 days
    banked = [None] * 4
    eff = sl
    exit_lvl = None
    for j in range(i0, min(i0 + span, n)):
        hi, lo, cl, op = ds["hi"][j], ds["lo"][j], ds["cl"][j], ds["op"][j]
        fav = (cl >= op and d > 0) or (cl < op and d < 0)

        def do_tp(eff):
            for k, tp in enumerate(tps):
                if tp is not None and banked[k] is None and ((d > 0 and hi >= tp) or (d < 0 and lo <= tp)):
                    banked[k] = d * (tp - entry) / risk
                    if managed:
                        lvl = entry if k == 0 else tps[k - 1]
                        if lvl is not None:
                            eff = max(eff, lvl) if d > 0 else min(eff, lvl)
            return eff

        def hit(L):
            return (d > 0 and lo <= L) or (d < 0 and hi >= L)
        if fav:
            eff = do_tp(eff)
            if hit(eff):
                exit_lvl = eff; break
        else:
            if hit(eff):
                exit_lvl = eff; break
            eff = do_tp(eff)
    last = ds["cl"][min(i0 + span, n) - 1]
    q = []
    for k, tp in enumerate(tps):
        if banked[k] is not None:
            q.append(banked[k])
        elif exit_lvl is not None:
            q.append(d * (exit_lvl - entry) / risk)
        else:
            q.append(d * (last - entry) / risk)
    return {"yr": s["dt"][:4], "netR": sum(q) / 4 - 0.30 / risk,
            "tp1": banked[0] is not None, "ok": entry_ok}


for managed in (False, True):
    recs = [grade(s, managed) for s in sig]
    R = pd.DataFrame([r for r in recs if r])
    R = R[R["ok"]]   # only trades whose entry matched market (valid alignment)
    lbl = "MANAGED (breakeven after TP1 + trail)" if managed else "RAW (SL as posted)"
    print(f"\n===== {lbl} =====  valid graded: {len(R)}")
    print(f"  TP1 hit before stop : {R['tp1'].mean()*100:.0f}%")
    print(f"  net-positive trades : {(R['netR']>0).mean()*100:.0f}%")
    print(f"  avg net R / trade   : {R['netR'].mean():.3f} R")
    print(f"  TOTAL R             : {R['netR'].sum():.1f} R  (= {R['netR'].sum():.0f}% at 1% risk)")
    print(R.groupby("yr")["netR"].agg(["count", "sum", "mean"]).round(2).to_string())
