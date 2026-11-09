"""Round 3 (final dev round): scale-out + runner hybrids on the best core.
Core: B=30, opp stop, long-only, trend-aligned, cutoff 22:00.
Dims: bank point, runner exit, trend filter strength. ~24 configs, then stop."""
import itertools
import sys

import numpy as np
import pandas as pd

sys.stdout.reconfigure(encoding="utf-8", errors="replace")

df = pd.read_parquet(r"E:\Documents\Quant Trading\QQQ\ustec_m1.parquet")
df["dt"] = pd.to_datetime(df["time"], unit="s")
df["date"] = df["dt"].dt.date
df["mod"] = df["dt"].dt.hour * 60 + df["dt"].dt.minute
SESS_OPEN, SESS_EXIT, CUTOFF = 16 * 60 + 30, 22 * 60 + 55, 22 * 60
SLIP = 0.5

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
DEV_END = pd.Timestamp("2025-01-01").date()
dev_days = [d for d in valid_days if d < DEV_END]
hold_days = [d for d in valid_days if d >= DEV_END]


def run(days, bankR, runner, trendf, B=30, tfrac=0.5):
    out = []
    for d in days:
        dd = day_data[d]
        adr = ADR10.get(d, np.nan)
        if not np.isfinite(adr) or adr <= 0:
            continue
        if trendf in ("prev", "prev+ma") and PREVDIR.get(d, 0) != 1:
            continue
        if trendf in ("ma", "prev+ma") and not MA20.get(d, False):
            continue
        mod, o, h, l, c, sp = dd["mod"], dd["o"], dd["h"], dd["l"], dd["c"], dd["sp"]
        box_end = SESS_OPEN + B
        bm = mod < box_end
        if bm.sum() < B * 0.7:
            continue
        box_hi, box_lo = h[bm].max(), l[bm].min()
        sess_open_px = o[0]
        idx = np.where((mod >= box_end) & (mod <= CUTOFF))[0]
        trade = None
        for i in idx:
            long_x, short_x = h[i] >= box_hi, l[i] <= box_lo
            if not (long_x or short_x):
                continue
            if short_x and not long_x:
                trade = "skip"; break          # long-only: short broke first
            if long_x and short_x and c[i] < o[i]:
                trade = "skip"; break
            entry = box_hi + sp[i] + SLIP
            tgt = sess_open_px + tfrac * adr
            if tgt - entry < 0.10 * adr:
                trade = "skip"; break
            stop = box_lo
            risk = entry - stop
            if risk < 3:
                trade = "skip"; break
            trade = (i, entry, stop, tgt, risk)
            break
        if trade in (None, "skip"):
            continue
        i0, entry, stop, tgt, risk = trade
        banked = 0.0
        frac = 1.0
        peak = entry
        exit_px = None
        j = i0
        for j in range(i0 + 1, len(mod)):
            if mod[j] > SESS_EXIT - 1:
                break
            adverse = c[j] < o[j]
            hit_stop = l[j] <= stop
            bank_t = entry + bankR * risk
            hit_bank = frac == 1.0 and h[j] >= bank_t
            run_t = sess_open_px + (0.75 if runner == "tgt75" else 1.0) * adr
            hit_run = runner in ("tgt75", "tgt100") and h[j] >= run_t

            def bank():
                nonlocal banked, frac, stop
                banked = 0.5 * bankR
                frac = 0.5
                stop = max(stop, entry)

            if adverse:
                if hit_stop: exit_px = stop; break
                if hit_bank: bank()
                if hit_run: exit_px = run_t; break
            else:
                if hit_bank: bank()
                if hit_run: exit_px = run_t; break
                if hit_stop: exit_px = stop; break
            if runner.startswith("trail") and frac == 0.5:
                tr = 0.25 if runner == "trail25" else 0.35
                peak = max(peak, c[j])
                if peak - entry > tr * adr:
                    stop = max(stop, peak - tr * adr)
        if exit_px is None:
            exit_px = c[min(len(c) - 1, j)]
        cost = (SLIP + sp[i0]) / risk
        out.append(banked + frac * (exit_px - entry) / risk - cost)
    r = np.array(out)
    if len(r) < 60:
        return None
    pos, neg = r[r > 0], r[r <= 0]
    pf = pos.sum() / max(1e-9, -neg.sum()) if len(neg) else np.inf
    return dict(n=len(r), wr=round(100 * (r > 0).mean(), 1), pf=round(pf, 3),
                avgR=round(r.mean(), 3), totR=round(r.sum(), 1))


rows = []
for bankR, runner, trendf in itertools.product(
        (0.5, 0.75, 1.0), ("tgt75", "tgt100", "trail25", "trail35"),
        ("prev", "ma", "prev+ma")):
    res = run(dev_days, bankR, runner, trendf)
    if res:
        rows.append(dict(bank=bankR, runner=runner, trend=trendf, **res))
R = pd.DataFrame(rows)
pd.set_option("display.width", 200)
print("===== DEV round 3 (all, sorted by PF) =====")
print(R.sort_values("pf", ascending=False).to_string(index=False))
G = R[(R["wr"] >= 60) & (R["pf"] >= 2)]
print("\n===== meets BOTH goals on dev =====")
print(G.to_string(index=False) if len(G) else "none")
R.to_csv(r"E:\Documents\Quant Trading\QQQ\results\ablation_dev_round3.csv", index=False)
