"""Round 2 ablation: structural variants on the two promising cores from round 1.
Still DEV-ONLY selection. New dimensions: scale-out, trailing exit, trend filter,
entry cutoff, box-quality filter, direction asymmetry."""
import itertools
import sys

import numpy as np
import pandas as pd

sys.stdout.reconfigure(encoding="utf-8", errors="replace")

df = pd.read_parquet(r"E:\Documents\Quant Trading\QQQ\ustec_m1.parquet")
df["dt"] = pd.to_datetime(df["time"], unit="s")
df["date"] = df["dt"].dt.date
df["mod"] = df["dt"].dt.hour * 60 + df["dt"].dt.minute

SESS_OPEN, SESS_EXIT = 16 * 60 + 30, 22 * 60 + 55
SLIP = 0.5

daily = df.groupby("date").agg(hi=("high", "max"), lo=("low", "min"),
                               cl=("close", "last"), op=("open", "first"))
daily["range"] = daily["hi"] - daily["lo"]
daily["dirn"] = np.sign(daily["cl"] - daily["op"])
ADR10 = daily["range"].shift(1).rolling(10, min_periods=5).mean().to_dict()
PREVDIR = daily["dirn"].shift(1).to_dict()

day_data = {}
for d, g in df.groupby("date"):
    s = g[(g["mod"] >= SESS_OPEN) & (g["mod"] <= SESS_EXIT)]
    if len(s) < 200:
        continue
    day_data[d] = dict(mod=s["mod"].values, o=s["open"].values, h=s["high"].values,
                       l=s["low"].values, c=s["close"].values, sp=s["spread"].values * 0.01)
valid_days = sorted(day_data)
DEV_END = pd.Timestamp("2025-01-01").date()
dev_days = [d for d in valid_days if d < DEV_END]
hold_days = [d for d in valid_days if d >= DEV_END]


def run(days, B, tfrac, stop_mode, be, exitm, trendf, cutoff, boxq, direction):
    out = []
    for d in days:
        dd = day_data[d]
        adr = ADR10.get(d, np.nan)
        if not np.isfinite(adr) or adr <= 0:
            continue
        mod, o, h, l, c, sp = dd["mod"], dd["o"], dd["h"], dd["l"], dd["c"], dd["sp"]
        box_end = SESS_OPEN + B
        bm = mod < box_end
        if bm.sum() < B * 0.7:
            continue
        box_hi, box_lo = h[bm].max(), l[bm].min()
        if boxq is not None and (box_hi - box_lo) > boxq * adr:
            continue
        sess_open_px = o[0]
        idx = np.where((mod >= box_end) & (mod <= cutoff))[0]
        trade = None
        for i in idx:
            long_x, short_x = h[i] >= box_hi, l[i] <= box_lo
            if not (long_x or short_x):
                continue
            if long_x and short_x:
                long_x = c[i] >= o[i]; short_x = not long_x
            dirn = 1 if long_x else -1
            if direction == "long" and dirn < 0: trade = "skip"; break
            if direction == "short" and dirn > 0: trade = "skip"; break
            if trendf == "prev":
                pv = PREVDIR.get(d, 0)
                if pv == 0 or pv != dirn:
                    trade = "skip"; break
            entry = (box_hi + sp[i] + SLIP) if dirn > 0 else (box_lo - SLIP)
            tgt = sess_open_px + dirn * tfrac * adr
            if dirn * (tgt - entry) < 0.10 * adr:
                trade = "skip"; break
            if stop_mode == "mid":
                slp_ = (box_hi + box_lo) / 2
            elif stop_mode == "opp":
                slp_ = box_lo if dirn > 0 else box_hi
            else:
                slp_ = entry - dirn * 0.15 * adr
            risk = abs(entry - slp_)
            if risk < 3:
                trade = "skip"; break
            trade = (i, dirn, entry, slp_, tgt, risk)
            break
        if trade in (None, "skip"):
            continue
        i0, dirn, entry, stop, tgt, risk = trade
        halves = []            # list of R outcomes per half (or whole)
        pos_frac = 1.0
        scaled = False
        peak = entry
        exit_px = None
        j = i0
        for j in range(i0 + 1, len(mod)):
            if mod[j] > SESS_EXIT - 1:
                break
            adverse = (c[j] < o[j]) if dirn > 0 else (c[j] > o[j])
            hit_stop = (l[j] <= stop) if dirn > 0 else (h[j] >= stop)
            if exitm == "scale05" and not scaled:
                half_t = entry + dirn * 0.5 * risk
                hit_half = (h[j] >= half_t) if dirn > 0 else (l[j] <= half_t)
            else:
                hit_half = False
            hit_tgt = (h[j] >= tgt) if dirn > 0 else (l[j] <= tgt)

            def bank_half():
                nonlocal pos_frac, scaled, stop
                halves.append(0.5 * 0.5)          # half position, +0.5R
                pos_frac = 0.5
                scaled = True
                stop = entry                       # runner to breakeven

            if adverse:
                if hit_stop:
                    exit_px = stop; break
                if hit_half: bank_half()
                if hit_tgt: exit_px = tgt; break
            else:
                if hit_half: bank_half()
                if hit_tgt:
                    exit_px = tgt; break
                if hit_stop:
                    exit_px = stop; break
            if exitm == "trail":
                peak = max(peak, c[j]) if dirn > 0 else min(peak, c[j])
                if dirn * (peak - entry) > 0.35 * adr:
                    t_ = peak - dirn * 0.35 * adr
                    stop = max(stop, t_) if dirn > 0 else min(stop, t_)
            elif be and dirn * (c[j] - entry) >= risk:
                stop = max(stop, entry) if dirn > 0 else min(stop, entry)
        if exit_px is None:
            exit_px = c[min(len(c) - 1, j)]
        halves.append(pos_frac * dirn * (exit_px - entry) / risk)
        cost = (SLIP + sp[i0]) / risk
        out.append(sum(halves) - cost)
    r = np.array(out)
    if len(r) < 60:
        return None
    pos, neg = r[r > 0], r[r <= 0]
    pf = pos.sum() / max(1e-9, -neg.sum()) if len(neg) else np.inf
    return dict(n=len(r), wr=100 * (r > 0).mean(), pf=round(pf, 3),
                avgR=round(r.mean(), 3), totR=round(r.sum(), 1))


cores = [dict(B=30, tfrac=0.5, stop_mode="opp"),
         dict(B=30, tfrac=0.75, stop_mode="adr15"),
         dict(B=30, tfrac=0.75, stop_mode="opp")]
rows = []
for core in cores:
    for exitm, trendf, cutoff, boxq, dirn, be in itertools.product(
            ("fixed", "scale05", "trail"), (None, "prev"),
            (22 * 60, 19 * 60 + 30), (None, 0.35), ("both", "long", "short"),
            (True,)):
        res = run(dev_days, core["B"], core["tfrac"], core["stop_mode"], be,
                  exitm, trendf, cutoff, boxq, dirn)
        if res:
            rows.append(dict(**core, exit=exitm, trend=str(trendf),
                             cut=cutoff // 60, boxq=str(boxq), dir=dirn, **res))
R = pd.DataFrame(rows)
pd.set_option("display.width", 250)
R["score"] = np.where((R["wr"] >= 60) & (R["pf"] >= 2), 999, R["pf"] + R["wr"] / 100)
print("===== DEV round 2: top 20 by PF =====")
print(R.sort_values("pf", ascending=False).head(20).to_string(index=False))
print("\n===== DEV round 2: top 20 by WR =====")
print(R.sort_values("wr", ascending=False).head(20).to_string(index=False))
print("\n===== configs meeting BOTH goals on dev =====")
G = R[(R["wr"] >= 60) & (R["pf"] >= 2)]
print(G.to_string(index=False) if len(G) else "none")
R.to_csv(r"E:\Documents\Quant Trading\QQQ\results\ablation_dev_round2.csv", index=False)
