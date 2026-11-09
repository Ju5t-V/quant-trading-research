"""GOLD LAB: hunt for PF>=2 AND WR>=60 with dev/holdout discipline on XAUUSD M1.

Family A: prev-day H/L breakout (validated GoldBreakout family), entry hour >=6,
          ATR-scaled SL + aggressive trail, optional bank-half@1R, trend filters.
Family B: session-box breakout (30-min box at 10:00 or 16:30 server), trend
          filters, bank-half, ADR-referenced runner (round-3 structure).

Dev: 2022-07-01 .. 2024-12-31.  Holdout: 2025-01-01 .. 2026-07-17 (single shot).
Champion rule (pre-declared): highest PF among dev configs with WR>=60, n>=100.
"""
import itertools
import sys

import numpy as np
import pandas as pd

sys.stdout.reconfigure(encoding="utf-8", errors="replace")

df = pd.read_parquet(r"E:\Documents\Quant Trading\QQQ\xauusd_m1_deep.parquet")
df["dt"] = pd.to_datetime(df["time"], unit="s")
df["date"] = df["dt"].dt.date
df["modm"] = df["dt"].dt.hour * 60 + df["dt"].dt.minute
df = df.reset_index(drop=True)

O = df["open"].values; H = df["high"].values; L = df["low"].values
C = df["close"].values; SPD = df["spread"].values * 0.01
MOD = df["modm"].values
N = len(df)

daily = df.groupby("date").agg(hi=("high", "max"), lo=("low", "min"),
                               cl=("close", "last"), op=("open", "first"))
daily["range"] = daily["hi"] - daily["lo"]
prev_close = daily["cl"].shift(1)
tr = pd.concat([daily["range"], (daily["hi"] - prev_close).abs(),
                (daily["lo"] - prev_close).abs()], axis=1).max(axis=1)
ATR10 = tr.shift(1).rolling(10, min_periods=6).mean().to_dict()
PDH = daily["hi"].shift(1).to_dict()
PDL = daily["lo"].shift(1).to_dict()
PREVDIR = np.sign(daily["cl"] - daily["op"]).shift(1).to_dict()
MA20UP = (daily["cl"].shift(1) > daily["cl"].shift(1).rolling(20).mean()).to_dict()

# day -> (start_idx, end_idx) in flat arrays
day_idx = {}
for d, g in df.groupby("date"):
    day_idx[d] = (g.index[0], g.index[-1] + 1)
all_days = sorted(day_idx)
DEV_END = pd.Timestamp("2025-01-01").date()
DEV_START = pd.Timestamp("2022-07-01").date()
SLIP = 0.10
MAX_HOLD = 3 * 1440  # bars


def manage(i0, dirn, entry, sl_d, ts_d, td_d, bank, risk):
    """Walk bars from i0+1; returns netR (excl. costs). ATR-scaled trail."""
    stop = entry - dirn * sl_d
    banked, frac = 0.0, 1.0
    peak = entry
    exit_px = None
    jend = min(N, i0 + MAX_HOLD)
    for j in range(i0 + 1, jend):
        adverse = (C[j] < O[j]) if dirn > 0 else (C[j] > O[j])
        hit_stop = (L[j] <= stop) if dirn > 0 else (H[j] >= stop)
        hit_bank = bank and frac == 1.0 and \
            ((H[j] >= entry + risk) if dirn > 0 else (L[j] <= entry - risk))

        def do_bank():
            nonlocal banked, frac, stop
            banked = 0.5
            frac = 0.5
            stop = max(stop, entry) if dirn > 0 else min(stop, entry)

        if adverse:
            if hit_stop:
                exit_px = stop; break
            if hit_bank:
                do_bank()
        else:
            if hit_bank:
                do_bank()
            if hit_stop:
                exit_px = stop; break
        peak = max(peak, C[j]) if dirn > 0 else min(peak, C[j])
        if dirn * (peak - entry) >= ts_d:
            t_ = peak - dirn * td_d
            stop = max(stop, t_) if dirn > 0 else min(stop, t_)
    if exit_px is None:
        exit_px = C[jend - 1]
    return banked + frac * dirn * (exit_px - entry) / risk


def famA(days, s_atr, ts_atr, td_atr, bank, trendf):
    out = []
    for d in days:
        atr = ATR10.get(d, np.nan)
        ph, pl = PDH.get(d, np.nan), PDL.get(d, np.nan)
        if not (np.isfinite(atr) and np.isfinite(ph) and atr > 0):
            continue
        a, b = day_idx[d]
        sl_d, ts_d, td_d = s_atr * atr, ts_atr * atr, td_atr * atr
        allow_long, allow_short = True, True
        if trendf == "prev":
            pv = PREVDIR.get(d, 0)
            allow_long, allow_short = pv == 1, pv == -1
        elif trendf == "ma20":
            up = MA20UP.get(d, False)
            allow_long, allow_short = up, not up
        i6 = None
        for i in range(a, b):
            if MOD[i] >= 360:
                i6 = i; break
        if i6 is None:
            continue
        if O[i6] + SPD[i6] >= ph:
            allow_long = False
        if O[i6] <= pl:
            allow_short = False
        for i in range(i6, b):
            if allow_long and H[i] + SPD[i] >= ph:
                allow_long = False
                entry = ph + SPD[i] + SLIP
                risk = sl_d
                out.append(manage(i, 1, entry, sl_d, ts_d, td_d, bank, risk)
                           - (SPD[i] + 2 * SLIP) / risk)
            if allow_short and L[i] <= pl:
                allow_short = False
                entry = pl - SLIP
                risk = sl_d
                out.append(manage(i, -1, entry, sl_d, ts_d, td_d, bank, risk)
                           - (SPD[i] + 2 * SLIP) / risk)
            if not allow_long and not allow_short:
                break
    return np.array(out)


def famB(days, anchor, trendf, bankR, runner):
    out = []
    for d in days:
        atr = ATR10.get(d, np.nan)
        if not np.isfinite(atr) or atr <= 0:
            continue
        up_ok = MA20UP.get(d, False)
        pv = PREVDIR.get(d, 0)
        if trendf == "prev":
            dir_allowed = pv
        elif trendf == "ma20":
            dir_allowed = 1 if up_ok else -1
        else:  # prev+ma
            if pv == 1 and up_ok:
                dir_allowed = 1
            elif pv == -1 and not up_ok:
                dir_allowed = -1
            else:
                continue
        if dir_allowed == 0:
            continue
        a, b = day_idx[d]
        box_i = [i for i in range(a, b) if anchor <= MOD[i] < anchor + 30]
        if len(box_i) < 20:
            continue
        box_hi = max(H[i] for i in box_i)
        box_lo = min(L[i] for i in box_i)
        sess_end_mod = anchor + 390
        entry_i = None
        for i in range(box_i[-1] + 1, b):
            if MOD[i] > sess_end_mod - 60 or MOD[i] < anchor:
                break
            if dir_allowed > 0 and H[i] + SPD[i] >= box_hi:
                entry_i, entry, stop = i, box_hi + SPD[i] + SLIP, box_lo
                break
            if dir_allowed < 0 and L[i] <= box_lo:
                entry_i, entry, stop = i, box_lo - SLIP, box_hi
                break
        if entry_i is None:
            continue
        dirn = dir_allowed
        risk = abs(entry - stop)
        if risk < 0.5:
            continue
        banked, frac, peak = 0.0, 1.0, entry
        exit_px = None
        j = entry_i
        for j in range(entry_i + 1, b):
            if MOD[j] > sess_end_mod - 2:
                break
            adverse = (C[j] < O[j]) if dirn > 0 else (C[j] > O[j])
            hit_stop = (L[j] <= stop) if dirn > 0 else (H[j] >= stop)
            hit_bank = frac == 1.0 and \
                ((H[j] >= entry + bankR * risk) if dirn > 0 else (L[j] <= entry - bankR * risk))
            run_t = entry + dirn * 1.0 * atr
            hit_run = runner == "tgt100" and \
                ((H[j] >= run_t) if dirn > 0 else (L[j] <= run_t))

            def do_bank():
                nonlocal banked, frac, stop
                banked = 0.5 * bankR
                frac = 0.5
                stop = max(stop, entry) if dirn > 0 else min(stop, entry)

            if adverse:
                if hit_stop:
                    exit_px = stop; break
                if hit_bank:
                    do_bank()
                if hit_run:
                    exit_px = run_t; break
            else:
                if hit_bank:
                    do_bank()
                if hit_run:
                    exit_px = run_t; break
                if hit_stop:
                    exit_px = stop; break
            if runner == "trail25" and frac == 0.5:
                peak = max(peak, C[j]) if dirn > 0 else min(peak, C[j])
                if dirn * (peak - entry) > 0.25 * atr:
                    t_ = peak - dirn * 0.25 * atr
                    stop = max(stop, t_) if dirn > 0 else min(stop, t_)
        if exit_px is None:
            exit_px = C[min(j, b - 1)]
        out.append(banked + frac * dirn * (exit_px - entry) / risk
                   - (SPD[entry_i] + 2 * SLIP) / risk)
    return np.array(out)


def stats(r):
    if len(r) < 60:
        return None
    pos, neg = r[r > 0], r[r <= 0]
    pf = pos.sum() / max(1e-9, -neg.sum()) if len(neg) else np.inf
    return dict(n=len(r), wr=round(100 * (r > 0).mean(), 1), pf=round(pf, 3),
                avgR=round(r.mean(), 3), totR=round(r.sum(), 1))


dev_days = [d for d in all_days if DEV_START <= d < DEV_END]
hold_days = [d for d in all_days if d >= DEV_END]
print(f"dev days {len(dev_days)} | holdout days {len(hold_days)}")

rows = []
for s, (ts, td), bank, tf in itertools.product(
        (0.25, 0.35), ((0.15, 0.10), (0.25, 0.15)), (False, True),
        (None, "prev", "ma20")):
    st = stats(famA(dev_days, s, ts, td, bank, tf))
    if st:
        rows.append(dict(fam="A", p1=s, p2=f"{ts}/{td}", bank=bank, trend=str(tf), **st))
for anchor, tf, bankR, runner in itertools.product(
        (600, 990), ("prev", "ma20", "prev+ma"), (0.5, 1.0), ("trail25", "tgt100")):
    st = stats(famB(dev_days, anchor, tf, bankR, runner))
    if st:
        rows.append(dict(fam="B", p1=anchor, p2=runner, bank=bankR, trend=tf, **st))

R = pd.DataFrame(rows)
pd.set_option("display.width", 220)
print("\n===== DEV: all configs sorted by PF =====")
print(R.sort_values("pf", ascending=False).to_string(index=False))
Q = R[(R["wr"] >= 60) & (R["n"] >= 100)].sort_values("pf", ascending=False)
print("\n===== DEV: qualifying (WR>=60, n>=100) =====")
print(Q.to_string(index=False) if len(Q) else "none qualify")
R.to_csv(r"E:\Documents\Quant Trading\QQQ\results\gold_lab_dev.csv", index=False)
