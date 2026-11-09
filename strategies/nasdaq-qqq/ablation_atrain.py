"""Ablation study: US-session box breakout with ADR bands (atrain-style) on USTEC M1.

Strategy skeleton (from the video):
  - Daily statistical bands from ADR(N) around the session open
  - "Yellow box" = opening range of the first B minutes of the US session
  - Entry: first breakout of the box (OCO), tight stop back inside the box
  - Target: the ADR band (range support/resistance)
  - "10% odds" filter: skip if the day has already used most of its ADR
  - Flat by session close

Protocol: grid selection on DEV (Jul 2022 - Dec 2024) only;
single-shot validation of the declared champion on HOLDOUT (Jan 2025 - Jul 2026).
"""
import itertools
import sys

import numpy as np
import pandas as pd

sys.stdout.reconfigure(encoding="utf-8", errors="replace")

df = pd.read_parquet(r"E:\Documents\Quant Trading\QQQ\ustec_m1.parquet")
df["dt"] = pd.to_datetime(df["time"], unit="s")
df["date"] = df["dt"].dt.date
df["mod"] = df["dt"].dt.hour * 60 + df["dt"].dt.minute

SESS_OPEN = 16 * 60 + 30       # 16:30 server
SESS_LAST_ENTRY = 22 * 60      # no entries after 22:00
SESS_EXIT = 22 * 60 + 55       # flat by 22:55
SLIP = 0.5                     # slippage per side, index units

# ---- daily aggregates for ADR ----
daily = df.groupby("date").agg(hi=("high", "max"), lo=("low", "min"),
                               nbars=("time", "count"))
daily["range"] = daily["hi"] - daily["lo"]
dates = list(daily.index)

# precompute per-day session slices (numpy arrays for speed)
day_data = {}
for d, g in df.groupby("date"):
    s = g[(g["mod"] >= SESS_OPEN) & (g["mod"] <= SESS_EXIT)]
    if len(s) < 200:
        continue
    day_data[d] = dict(mod=s["mod"].values, o=s["open"].values, h=s["high"].values,
                       l=s["low"].values, c=s["close"].values,
                       sp=s["spread"].values * 0.01,
                       day_hi=g["high"].values, day_lo=g["low"].values,
                       day_mod=g["mod"].values)

valid_days = [d for d in dates if d in day_data]
print(f"tradeable session days: {len(valid_days)}")

# ADR lookup (prior N full-day ranges)
def adr_map(n):
    r = daily["range"].shift(1).rolling(n, min_periods=max(4, n // 2)).mean()
    return r.to_dict()

ADR = {n: adr_map(n) for n in (10,)}

DEV_END = pd.Timestamp("2025-01-01").date()


def run_config(days, B, tfrac, stop_mode, roomcap, be, direction):
    adr_d = ADR[10]
    out = []
    for d in days:
        dd = day_data[d]
        adr = adr_d.get(d, np.nan)
        if not np.isfinite(adr) or adr <= 0:
            continue
        mod, o, h, l, c, sp = dd["mod"], dd["o"], dd["h"], dd["l"], dd["c"], dd["sp"]
        box_end = SESS_OPEN + B
        bm = mod < box_end
        if bm.sum() < B * 0.7:
            continue
        box_hi, box_lo = h[bm].max(), l[bm].min()
        sess_open_px = o[0]
        tgt_up = sess_open_px + tfrac * adr
        tgt_dn = sess_open_px - tfrac * adr

        idx = np.where((mod >= box_end) & (mod <= SESS_LAST_ENTRY))[0]
        trade = None
        for i in idx:
            long_x = h[i] >= box_hi
            short_x = l[i] <= box_lo
            if not (long_x or short_x):
                continue
            if long_x and short_x:
                long_x = c[i] >= o[i]; short_x = not long_x
            dirn = 1 if long_x else -1
            if direction == "long" and dirn < 0: trade = "skip"; break
            if direction == "short" and dirn > 0: trade = "skip"; break
            entry = (box_hi + sp[i] + SLIP) if dirn > 0 else (box_lo - SLIP)
            # room filter: whole-day range used so far vs ADR
            if roomcap is not None:
                pm = dd["day_mod"] <= mod[i]
                used = dd["day_hi"][pm].max() - dd["day_lo"][pm].min()
                if used > roomcap * adr:
                    trade = "skip"; break
            tgt = tgt_up if dirn > 0 else tgt_dn
            if dirn * (tgt - entry) < 0.10 * adr:      # target must have room
                trade = "skip"; break
            if stop_mode == "mid":
                slp_ = (box_hi + box_lo) / 2
            elif stop_mode == "opp":
                slp_ = box_lo if dirn > 0 else box_hi
            else:  # adr15
                slp_ = entry - dirn * 0.15 * adr
            if stop_mode != "adr15":
                slp_ = slp_ if dirn > 0 else slp_
            risk = dirn * (entry - slp_) * -1 if False else abs(entry - slp_)
            if risk < 3:                                # degenerate
                trade = "skip"; break
            trade = (i, dirn, entry, slp_, tgt, risk)
            break
        if trade in (None, "skip"):
            continue
        i0, dirn, entry, slp_, tgt, risk = trade
        exit_px = None
        stop = slp_
        for j in range(i0 + 1, len(mod)):
            if mod[j] > SESS_EXIT - 1:
                break
            adverse_first = (c[j] < o[j]) if dirn > 0 else (c[j] > o[j])
            hit_stop = (l[j] <= stop) if dirn > 0 else (h[j] >= stop)
            hit_tgt = (h[j] >= tgt) if dirn > 0 else (l[j] <= tgt)
            if adverse_first:
                if hit_stop: exit_px = stop; break
                if hit_tgt: exit_px = tgt; break
            else:
                if hit_tgt: exit_px = tgt; break
                if hit_stop: exit_px = stop; break
            if be and dirn * (c[j] - entry) >= risk:
                stop = max(stop, entry) if dirn > 0 else min(stop, entry)
        if exit_px is None:
            exit_px = c[min(len(c) - 1, j)]
        cost = SLIP + (sp[i0] if i0 < len(sp) else 0.9)
        netR = (dirn * (exit_px - entry) - cost) / risk
        out.append(netR)
    r = np.array(out)
    if len(r) < 30:
        return None
    pos, neg = r[r > 0], r[r <= 0]
    pf = pos.sum() / max(1e-9, -neg.sum()) if len(neg) else np.inf
    return dict(n=len(r), wr=100 * (r > 0).mean(), pf=pf, avgR=r.mean(), totR=r.sum())


dev_days = [d for d in valid_days if d < DEV_END]
hold_days = [d for d in valid_days if d >= DEV_END]
print(f"dev days: {len(dev_days)} | holdout days: {len(hold_days)}")

grid = list(itertools.product(
    (30, 60),                       # box minutes
    (0.5, 0.75),                    # target frac of ADR
    ("mid", "opp", "adr15"),        # stop mode
    (0.6, 0.8, None),               # room cap
    (True, False),                  # breakeven at 1R
    ("both",),                      # direction (round 1)
))
rows = []
for B, tf, sm, rc, be, dr in grid:
    res = run_config(dev_days, B, tf, sm, rc, be, dr)
    if res:
        rows.append(dict(B=B, tgt=tf, stop=sm, room=str(rc), be=be, **res))
R = pd.DataFrame(rows).sort_values("pf", ascending=False)
pd.set_option("display.width", 200)
print("\n===== DEV grid (top 15 by PF) =====")
print(R.head(15).to_string(index=False))
print("\n===== DEV grid (top 15 by WR) =====")
print(R.sort_values("wr", ascending=False).head(15).to_string(index=False))
R.to_csv(r"E:\Documents\Quant Trading\QQQ\results\ablation_dev_round1.csv", index=False)
