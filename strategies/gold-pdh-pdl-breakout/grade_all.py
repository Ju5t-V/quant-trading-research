"""Grade all 420 Smith signals against historical gold price (raw + managed)."""
import json
import sys
import time
from datetime import datetime, timezone, timedelta

import MetaTrader5 as mt5
import pandas as pd

sys.stdout.reconfigure(encoding="utf-8", errors="replace")
sig = json.load(open(r"E:\Documents\Quant Trading\MT5\smith_signals.json"))

if not mt5.initialize():
    raise SystemExit("attach failed")
mt5.symbol_select("XAUUSD", True)

# pull M5 in 6-month chunks 2021 -> now
frames = []
start = datetime(2021, 1, 1, tzinfo=timezone.utc)
end = datetime(2026, 7, 18, tzinfo=timezone.utc)
cur = start
while cur < end:
    nxt = min(cur + timedelta(days=182), end)
    r = None
    for _ in range(6):
        r = mt5.copy_rates_range("XAUUSD", mt5.TIMEFRAME_M5, cur, nxt)
        if r is not None and len(r):
            break
        time.sleep(3)
    if r is not None and len(r):
        frames.append(pd.DataFrame(r))
    cur = nxt
mt5.shutdown()

df = pd.concat(frames, ignore_index=True).drop_duplicates("time").sort_values("time").reset_index(drop=True)
df["dt"] = pd.to_datetime(df["time"], unit="s")   # server (naive) time
print(f"price data: {df['dt'].iloc[0]} .. {df['dt'].iloc[-1]}  ({len(df)} M5 bars)")
times = df["dt"].values
highs, lows, closes, opens = df["high"].values, df["low"].values, df["close"].values, df["open"].values


def eu_dst(dt):
    y = dt.year
    mar = max(d for d in range(25, 32) if datetime(y, 3, d).weekday() == 6)
    oc = max(d for d in range(25, 32) if datetime(y, 10, d).weekday() == 6)
    return datetime(y, 3, mar, 1) <= dt < datetime(y, 10, oc, 1)


def grade(s, managed):
    d, entry, sl, tps = s["dir"], s["entry"], s["sl"], s["tps"]
    while len(tps) < 4:
        tps = tps + [None]
    tps = tps[:4]
    utc = datetime.fromtimestamp(s["utc"], timezone.utc).replace(tzinfo=None)
    srv = utc + timedelta(hours=3 if eu_dst(utc) else 2)
    i0 = df["dt"].searchsorted(pd.Timestamp(srv))
    if i0 >= len(df):
        return None, None, None
    # entry validation window +-2 bars
    lo_w = lows[max(0, i0 - 2):i0 + 3].min()
    hi_w = highs[max(0, i0 - 2):i0 + 3].max()
    entry_ok = lo_w - 2 <= entry <= hi_w + 2
    risk = abs(entry - sl)
    if risk <= 0:
        return None, None, None
    banked = [None] * 4
    eff = sl
    exit_lvl = None
    n = len(df)
    for j in range(i0, min(i0 + 864, n)):
        hi, lo, cl, op = highs[j], lows[j], closes[j], opens[j]
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

        def hit(level):
            return (d > 0 and lo <= level) or (d < 0 and hi >= level)

        if fav:
            eff = do_tp(eff)
            if hit(eff):
                exit_lvl = eff; break
        else:
            if hit(eff):
                exit_lvl = eff; break
            eff = do_tp(eff)
    last = closes[min(i0 + 864, n) - 1]
    q = []
    for k, tp in enumerate(tps):
        if banked[k] is not None:
            q.append(banked[k])
        elif exit_lvl is not None:
            q.append(d * (exit_lvl - entry) / risk)
        else:
            q.append(d * (last - entry) / risk)
    netR = sum(q) / 4.0 - 0.30 / risk
    tp1 = banked[0] is not None
    return netR, tp1, entry_ok


for managed in (False, True):
    recs = []
    for s in sig:
        nr, tp1, ok = grade(s, managed)
        if nr is None:
            continue
        recs.append({"yr": s["dt"][:4], "netR": nr, "tp1": tp1, "ok": ok})
    R = pd.DataFrame(recs)
    label = "MANAGED (breakeven after TP1)" if managed else "RAW (SL as posted)"
    print(f"\n===== {label} =====  graded {len(R)} / {len(sig)} signals")
    print(f"  entries matching market: {R['ok'].mean()*100:.0f}%")
    print(f"  TP1 hit before stop: {R['tp1'].mean()*100:.0f}%")
    print(f"  net-positive trades: {(R['netR']>0).mean()*100:.0f}%")
    print(f"  avg net R/trade: {R['netR'].mean():.3f}")
    print(f"  TOTAL R: {R['netR'].sum():.1f}")
    print(f"  -> at 1% risk/trade: {R['netR'].sum():.1f}% ; at 2%: {2*R['netR'].sum():.0f}%")
    by = R.groupby("yr")["netR"].agg(["count", "sum", "mean"]).round(2)
    print(by.to_string())
