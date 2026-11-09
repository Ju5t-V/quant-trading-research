"""Transfer test: frozen champion (unchanged params) on US500 — untouched data."""
import sys

import numpy as np
import pandas as pd

sys.stdout.reconfigure(encoding="utf-8", errors="replace")

df = pd.read_parquet(r"E:\Documents\Quant Trading\QQQ\us500_m1.parquet")
df["dt"] = pd.to_datetime(df["time"], unit="s")
df["date"] = df["dt"].dt.date
df["mod"] = df["dt"].dt.hour * 60 + df["dt"].dt.minute
SESS_OPEN, SESS_EXIT, CUTOFF = 16 * 60 + 30, 22 * 60 + 55, 22 * 60
SLIP = 0.15   # US500 ~6300, ticks finer; scale slippage to instrument

daily = df.groupby("date").agg(hi=("high", "max"), lo=("low", "min"),
                               cl=("close", "last"), op=("open", "first"))
daily["range"] = daily["hi"] - daily["lo"]
ADR10 = daily["range"].shift(1).rolling(10, min_periods=5).mean().to_dict()
PREVDIR = np.sign(daily["cl"] - daily["op"]).shift(1).to_dict()
MA20 = (daily["cl"].shift(1) > daily["cl"].shift(1).rolling(20).mean()).to_dict()

day_data = {}
for d, g in df.groupby("date"):
    s = g[(g["mod"] >= SESS_OPEN) & (g["mod"] <= SESS_EXIT)]
    if len(s) >= 200:
        day_data[d] = dict(mod=s["mod"].values, o=s["open"].values, h=s["high"].values,
                           l=s["low"].values, c=s["close"].values, sp=s["spread"].values * 0.01)
valid_days = sorted(day_data)


def run(days):
    out = []
    for d in days:
        dd = day_data[d]
        adr = ADR10.get(d, np.nan)
        if not np.isfinite(adr) or adr <= 0:
            continue
        if PREVDIR.get(d, 0) != 1 or not MA20.get(d, False):
            continue
        mod, o, h, l, c, sp = dd["mod"], dd["o"], dd["h"], dd["l"], dd["c"], dd["sp"]
        bm = mod < SESS_OPEN + 30
        if bm.sum() < 21:
            continue
        box_hi, box_lo = h[bm].max(), l[bm].min()
        sess_open_px = o[0]
        idx = np.where((mod >= SESS_OPEN + 30) & (mod <= CUTOFF))[0]
        trade = None
        for i in idx:
            long_x, short_x = h[i] >= box_hi, l[i] <= box_lo
            if not (long_x or short_x):
                continue
            if short_x and not long_x:
                trade = "skip"; break
            if long_x and short_x and c[i] < o[i]:
                trade = "skip"; break
            entry = box_hi + sp[i] + SLIP
            if (sess_open_px + 0.5 * adr) - entry < 0.10 * adr:
                trade = "skip"; break
            stop = box_lo
            risk = entry - stop
            if risk < 1:
                trade = "skip"; break
            trade = (i, entry, stop, risk)
            break
        if trade in (None, "skip"):
            continue
        i0, entry, stop, risk = trade
        banked, frac, peak = 0.0, 1.0, entry
        exit_px = None
        j = i0
        for j in range(i0 + 1, len(mod)):
            if mod[j] > SESS_EXIT - 1:
                break
            adverse = c[j] < o[j]
            hit_stop = l[j] <= stop
            hit_bank = frac == 1.0 and h[j] >= entry + 1.0 * risk
            if adverse:
                if hit_stop: exit_px = stop; break
                if hit_bank:
                    banked, frac, stop = 0.5, 0.5, max(stop, entry)
            else:
                if hit_bank:
                    banked, frac, stop = 0.5, 0.5, max(stop, entry)
                if hit_stop: exit_px = stop; break
            if frac == 0.5:
                peak = max(peak, c[j])
                if peak - entry > 0.25 * adr:
                    stop = max(stop, peak - 0.25 * adr)
        if exit_px is None:
            exit_px = c[min(len(c) - 1, j)]
        out.append(banked + frac * (exit_px - entry) / risk - (SLIP + sp[i0]) / risk)
    r = np.array(out)
    pos, neg = r[r > 0], r[r <= 0]
    pf = pos.sum() / max(1e-9, -neg.sum()) if len(neg) else np.inf
    return dict(n=len(r), wr=round(100 * (r > 0).mean(), 1), pf=round(pf, 3),
                avgR=round(r.mean(), 3), totR=round(r.sum(), 1))


DEV_END = pd.Timestamp("2025-01-01").date()
print("US500 transfer, frozen champion:")
print("  2022-2024:", run([d for d in valid_days if d < DEV_END]))
print("  2025-2026:", run([d for d in valid_days if d >= DEV_END]))
print("  full     :", run(valid_days))
