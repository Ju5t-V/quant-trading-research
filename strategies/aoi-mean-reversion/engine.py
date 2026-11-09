"""AOI mean-reversion engine — faithful reproduction of Revelio Trading's
fxalexg ablation methodology. Every rule and assumption: see SPEC.md (A1-A14).

Pipeline
  1. bars (parquet, from export scripts; native M30/H2 if present else resample M15)
  2. swings (strict fractal k=2 on closes, confirm-lagged — no lookahead)
  3. zones on D1/W1: >=3 swing-close touches clustered within 60 pips, 5-pip floor,
     expiry 2y/5y from last touch, active only after 3rd touch CONFIRMED
  4. candidates: every entry-TF candle closing inside an active zone with a known
     approach side (from above = support = BUY; from below = resistance = SELL),
     annotated with session hour / pattern / entry-TF trend / W1-D1-H4 trends /
     visit id / SL / TP (nearest D1 swing in 730d lookback, <2R skip, >4R cap)
  5. outcomes: vectorized intrabar walk; same-bar SL+TP -> LOSS (conservative)
  6. config run: eligibility filters + per-sim sequencing (one open trade per
     (pair, zone_tf, entry_tf) sim; max one trade per zone visit) -> R-multiple
     metrics (PF ranking = costs-excluded fixed-risk, exactly his method)

Run:  python engine.py           # builds candidates for all 16 pairs (parallel)
      python engine.py EURUSD    # single pair (debug)
"""
from __future__ import annotations

import itertools
import sys
from dataclasses import dataclass
from multiprocessing import Pool, freeze_support
from pathlib import Path

import numpy as np
import pandas as pd

DATA = Path(r"E:\Documents\Quant Trading\AOI_MeanReversion\data")
CACHE = DATA / "candidates.parquet"

PAIRS = ["AUDCAD","AUDCHF","AUDJPY","EURAUD","EURGBP","EURJPY","EURUSD","GBPAUD",
         "GBPCAD","GBPCHF","GBPNZD","GBPUSD","NZDCAD","NZDUSD","USDCAD","USDCHF"]

ENTRY_TFS = {"D1": ["H4", "H2", "H1", "M30", "M15"], "W1": ["H4", "H2", "H1"]}

import os

SWING_K = 2
ZONE_MAX_PIPS = 60.0
ZONE_MIN_PIPS = float(os.environ.get("AOI_ZONE_MIN", 5.0))
SL_PIPS = float(os.environ.get("AOI_SL_BEYOND", 5.0))
MIN_SL_PIPS = float(os.environ.get("AOI_MIN_SL", 0.0))   # 0 = off (his recap rule)
MIN_RR = 2.0
MAX_RR = float(os.environ.get("AOI_MAX_RR", 4.0))
TIME_STOP_DAYS = float(os.environ.get("AOI_TIME_STOP", 0.0))  # 0 = off
EXPIRY_DAYS = {"D1": 730, "W1": 1825}
TOUCHES_ACTIVE = int(os.environ.get("AOI_TOUCHES", 3))
TP_LOOKBACK_DAYS = 730

TF_SECONDS = {"M15": 900, "M30": 1800, "H1": 3600, "H2": 7200, "H4": 14400,
              "D1": 86400, "W1": 604800}

SESSIONS = {"asia": (1, 10), "london": (10, 19), "newyork": (15, 24),
            "overlap": (15, 19), "all": (0, 24)}   # server (EET) hours, close-time


def pip(sym: str) -> float:
    return 0.01 if "JPY" in sym else 0.0001


# ---------------------------------------------------------------- data

def load_tf(sym: str, tf: str) -> pd.DataFrame:
    f = DATA / f"{sym}_{tf}.parquet"
    if f.exists():
        return pd.read_parquet(f)
    if tf in ("M30", "H2"):
        m15 = pd.read_parquet(DATA / f"{sym}_M15.parquet").set_index("time")
        rule = "30min" if tf == "M30" else "2h"
        return (m15.resample(rule, label="left", closed="left")
                .agg({"open": "first", "high": "max", "low": "min", "close": "last",
                      "tick_volume": "sum", "spread": "mean"})
                .dropna(subset=["open"]).reset_index())
    raise FileNotFoundError(f)


# ---------------------------------------------------------------- swings

def swings(close: np.ndarray, k: int = SWING_K):
    """(idx, kind): swing bars, kind +1 high / -1 low. Strict fractal on closes.
    A swing at i is only KNOWN at bar i+k."""
    n = len(close)
    if n < 2 * k + 1:
        return np.array([], int), np.array([], int)
    hi = np.ones(n, bool); lo = np.ones(n, bool)
    for off in range(1, k + 1):
        f = np.roll(close, -off); b = np.roll(close, off)
        hi &= (close > f) & (close > b)
        lo &= (close < f) & (close < b)
    hi[:k] = hi[-k:] = lo[:k] = lo[-k:] = False
    idx = np.where(hi | lo)[0]
    return idx, np.where(hi[idx], 1, -1)


# ---------------------------------------------------------------- zones

class _Zone:
    __slots__ = ("zid", "levels", "last_touch", "activated")

    def __init__(self, zid, level, touch_t):
        self.zid = zid
        self.levels = [level]
        self.last_touch = touch_t
        self.activated = None          # confirm-time of 3rd member


def zone_snapshots(zdf: pd.DataFrame, sym: str, zone_tf: str):
    """Replay swing events over zone-TF bars.

    Returns (snap_close_times, snapshots) where snapshot k is a list of
    (zid, lo, hi) active for entry-candle closes t with T_k < t <= T_{k+1}.
    """
    p = pip(sym)
    close = zdf["close"].to_numpy()
    times = zdf["time"].to_numpy()
    idx, kind = swings(close)
    # confirmed only once the confirm bar has CLOSED (open time + TF seconds)
    conf_t = times[np.minimum(idx + SWING_K, len(times) - 1)] \
        + np.timedelta64(TF_SECONDS[zone_tf], "s")
    events = list(zip(conf_t, times[idx], close[idx]))     # (confirm, swing_t, level)

    bar_close = times + np.timedelta64(TF_SECONDS[zone_tf], "s")
    expiry = np.timedelta64(EXPIRY_DAYS[zone_tf] * 86400, "s")

    zones: list[_Zone] = []
    zid_ctr = 0
    ev = 0
    snaps = []
    for k in range(len(bar_close)):
        T = bar_close[k]
        while ev < len(events) and events[ev][0] <= T:
            c_t, s_t, lvl = events[ev]; ev += 1
            best, best_d = None, None
            for z in zones:
                lo = min(min(z.levels), lvl); hi = max(max(z.levels), lvl)
                if hi - lo <= ZONE_MAX_PIPS * p:
                    d = abs(lvl - sum(z.levels) / len(z.levels))
                    if best is None or d < best_d:
                        best, best_d = z, d
            if best is None:
                zid_ctr += 1
                zones.append(_Zone(zid_ctr, lvl, s_t))
            else:
                best.levels.append(lvl)
                if s_t > best.last_touch:
                    best.last_touch = s_t
                if len(best.levels) >= TOUCHES_ACTIVE and best.activated is None:
                    best.activated = c_t
        cutoff = T - expiry
        if zones and (k % 16 == 0):
            zones = [z for z in zones if z.last_touch >= cutoff]
        snap = []
        for z in zones:
            if z.activated is not None and z.activated <= T and z.last_touch >= cutoff:
                lo, hi = min(z.levels), max(z.levels)
                if hi - lo < ZONE_MIN_PIPS * p:
                    m = (hi + lo) / 2
                    lo, hi = m - ZONE_MIN_PIPS * p / 2, m + ZONE_MIN_PIPS * p / 2
                snap.append((z.zid, lo, hi, len(z.levels)))
        snaps.append(snap)
    return bar_close, snaps


# ---------------------------------------------------------------- structure trend

def structure_trend(df: pd.DataFrame) -> np.ndarray:
    """Video-1 body-close break engine. trend[i] = state as of close of bar i."""
    close = df["close"].to_numpy()
    n = len(close)
    idx, kind = swings(close)
    conf = idx + SWING_K
    trend = np.zeros(n, np.int8)
    last_hi = last_lo = ref_hi = ref_lo = np.nan
    cur = 0
    pend_hi = pend_lo = False
    ev = 0
    for i in range(n):
        while ev < len(idx) and conf[ev] == i:
            lvl = close[idx[ev]]
            if kind[ev] == 1:
                last_hi = lvl
                if pend_hi:
                    ref_hi = lvl; pend_hi = False
            else:
                last_lo = lvl
                if pend_lo:
                    ref_lo = lvl; pend_lo = False
            if np.isnan(ref_hi) and not np.isnan(last_hi):
                ref_hi = last_hi
            if np.isnan(ref_lo) and not np.isnan(last_lo):
                ref_lo = last_lo
            ev += 1
        c = close[i]
        if not np.isnan(ref_hi) and not np.isnan(ref_lo):
            if c > ref_hi and not pend_hi:
                cur = 1; pend_hi = True; ref_lo = last_lo
            elif c < ref_lo and not pend_lo:
                cur = -1; pend_lo = True; ref_hi = last_hi
        trend[i] = cur
    return trend


def trend_at_bulk(tf_df: pd.DataFrame, trend: np.ndarray, tf: str,
                  t_arr: np.ndarray) -> np.ndarray:
    """Trend as of the last CLOSED tf bar at each time in t_arr."""
    closes = tf_df["time"].to_numpy() + np.timedelta64(TF_SECONDS[tf], "s")
    pos = np.searchsorted(closes, t_arr, side="right") - 1
    out = np.zeros(len(t_arr), np.int8)
    ok = pos >= 0
    out[ok] = trend[pos[ok]]
    return out


# ---------------------------------------------------------------- patterns

def annotate_patterns(df: pd.DataFrame):
    """(bull, bear) booleans per bar for Alex's kept pattern list."""
    o = df["open"].to_numpy(); h = df["high"].to_numpy()
    l = df["low"].to_numpy(); c = df["close"].to_numpy()
    body = np.abs(c - o)
    rng = np.maximum(h - l, 1e-12)
    upsh = h - np.maximum(c, o)
    dnsh = np.minimum(c, o) - l
    bull_c = c > o; bear_c = c < o
    small = body <= 0.3 * rng
    doji = body <= 0.1 * rng

    hammer = small & (dnsh >= 2 * body) & (upsh <= body)          # + hanging man (bear ctx)
    inv_hammer = small & (upsh >= 2 * body) & (dnsh <= body)      # + shooting star (bear ctx)
    grave_doji = doji & (upsh >= 0.5 * rng) & (dnsh <= 0.1 * rng)

    o1 = np.roll(o, 1); c1 = np.roll(c, 1)
    o2 = np.roll(o, 2); c2 = np.roll(c, 2)
    body1 = np.abs(c1 - o1); rng1 = np.roll(rng, 1)
    small1 = body1 <= 0.3 * rng1
    doji1 = body1 <= 0.1 * rng1

    bull_engulf = (c1 < o1) & bull_c & (c >= o1) & (o <= c1)
    bear_engulf = (c1 > o1) & bear_c & (c <= o1) & (o >= c1)
    m_star = (c2 < o2) & small1 & bull_c & (c > (o2 + c2) / 2)
    m_dstar = (c2 < o2) & doji1 & bull_c & (c > (o2 + c2) / 2)
    e_star = (c2 > o2) & small1 & bear_c & (c < (o2 + c2) / 2)
    e_dstar = (c2 > o2) & doji1 & bear_c & (c < (o2 + c2) / 2)

    bull = hammer | inv_hammer | bull_engulf | m_star | m_dstar
    bear = inv_hammer | hammer | grave_doji | bear_engulf | e_star | e_dstar
    bull[:2] = False; bear[:2] = False
    return bull, bear


# ---------------------------------------------------------------- candidates

def build_candidates(sym: str) -> pd.DataFrame:
    p = pip(sym)
    d1 = load_tf(sym, "D1"); w1 = load_tf(sym, "W1"); h4 = load_tf(sym, "H4")
    tr_d1 = structure_trend(d1); tr_w1 = structure_trend(w1); tr_h4 = structure_trend(h4)

    # D1 swing points for TP (confirm-lagged)
    dc = d1["close"].to_numpy(); dt = d1["time"].to_numpy()
    di, dk = swings(dc)
    # usable only after the confirm D1 bar has CLOSED
    d_conf = dt[np.minimum(di + SWING_K, len(dt) - 1)] + np.timedelta64(86400, "s")
    d_lvl = dc[di]

    # D1 ATR(14) percentile (rolling 252d) for the volatility filter, lag-safe:
    dh = d1["high"].to_numpy(); dl = d1["low"].to_numpy()
    tr1 = dh - dl
    tr2 = np.abs(dh - np.roll(dc, 1)); tr3 = np.abs(dl - np.roll(dc, 1))
    tr = np.maximum(tr1, np.maximum(tr2, tr3)); tr[0] = tr1[0]
    atr = pd.Series(tr).rolling(14).mean()
    atr_pct = atr.rolling(252).rank(pct=True).to_numpy()
    atr_close_t = dt + np.timedelta64(86400, "s")   # ATR known at D1 bar CLOSE
    hi_t, hi_l = d_conf[dk == 1], d_lvl[dk == 1]
    lo_t, lo_l = d_conf[dk == -1], d_lvl[dk == -1]
    tp_lb = np.timedelta64(TP_LOOKBACK_DAYS * 86400, "s")

    all_rows = []
    for zone_tf, entry_tfs in ENTRY_TFS.items():
        zdf = d1 if zone_tf == "D1" else w1
        snap_t, snaps = zone_snapshots(zdf, sym, zone_tf)
        for etf in entry_tfs:
            e = load_tf(sym, etf)
            et = e["time"].to_numpy()
            eo = e["open"].to_numpy(); ec = e["close"].to_numpy()
            n = len(e)
            if n < 10:
                continue
            close_t = et + np.timedelta64(TF_SECONDS[etf], "s")
            bull_pat, bear_pat = annotate_patterns(e)
            tr_e = structure_trend(e)
            sid = np.searchsorted(snap_t, close_t, side="left") - 1

            state: dict[int, int] = {}       # zid -> +1 out_above / -1 out_below / 0 inside
            visit_no: dict[int, int] = {}    # zid -> visit counter
            visit_dir: dict[int, int] = {}   # zid -> direction of current visit
            rows = []
            for i in range(n):
                k = sid[i]
                if k < 0:
                    continue
                snap = snaps[k]
                if not snap:
                    continue
                c = ec[i]
                inside_best = None; best_d = None
                for zid, lo, hi, nt in snap:
                    if lo <= c <= hi:
                        prev = state.get(zid)
                        if prev is None:
                            state[zid] = 0
                            continue
                        if prev != 0:                     # transition -> new visit
                            visit_no[zid] = visit_no.get(zid, 0) + 1
                            visit_dir[zid] = 1 if prev == 1 else -1
                            state[zid] = 0
                        if zid in visit_dir:
                            d = abs(c - (lo + hi) / 2)
                            if best_d is None or d < best_d:
                                inside_best = (zid, lo, hi, nt); best_d = d
                    else:
                        state[zid] = 1 if c > hi else -1
                if inside_best is None:
                    continue
                zid, lo, hi, ntouch = inside_best
                direction = visit_dir[zid]
                ei = i + 1
                if ei >= n:
                    continue
                entry = eo[ei]
                sl = lo - SL_PIPS * p if direction == 1 else hi + SL_PIPS * p
                if MIN_SL_PIPS > 0:      # deviation R1: enforce minimum SL distance
                    if direction == 1:
                        sl = min(sl, entry - MIN_SL_PIPS * p)
                    else:
                        sl = max(sl, entry + MIN_SL_PIPS * p)
                risk = (entry - sl) if direction == 1 else (sl - entry)
                if risk <= 0:
                    continue
                t_sig = close_t[i]
                if direction == 1:
                    m = (hi_t <= t_sig) & (hi_t >= t_sig - tp_lb) & (hi_l > entry)
                    if not m.any():
                        continue
                    tp = hi_l[m].min()
                else:
                    m = (lo_t <= t_sig) & (lo_t >= t_sig - tp_lb) & (lo_l < entry)
                    if not m.any():
                        continue
                    tp = lo_l[m].max()
                rr = ((tp - entry) if direction == 1 else (entry - tp)) / risk
                if rr < MIN_RR:
                    continue
                if rr > MAX_RR:
                    tp = entry + MAX_RR * risk * (1 if direction == 1 else -1)
                    rr = MAX_RR
                rows.append((zone_tf, etf, i, ei, t_sig, et[ei], direction, entry, sl, tp,
                             round(rr, 3), lo, hi, zid, visit_no[zid], ntouch,
                             bool(bull_pat[i]) if direction == 1 else bool(bear_pat[i]),
                             int(tr_e[i])))
            if not rows:
                continue
            g = pd.DataFrame(rows, columns=[
                "zone_tf", "entry_tf", "signal_i", "entry_i", "signal_time", "entry_time",
                "dir", "entry", "sl", "tp", "rr", "band_lo", "band_hi", "zid", "visit_n",
                "ntouch", "pat_ok", "tr_entry"])
            g["pair"] = sym
            # outcomes: resolve on the finest TF available (H1 for H4/H2 entries)
            rdf = load_tf(sym, "H1") if etf in ("H4", "H2") else e
            g = g[g["entry_time"] >= rdf["time"].iloc[0]].reset_index(drop=True)
            if not len(g):
                continue
            R, exit_t, amb = _resolve(g, e, rdf)
            g["R"] = R
            g["exit_time"] = exit_t
            if len(g):
                print(f"    {sym} {zone_tf}/{etf}: {len(g)} cands, ambiguous-bar exits {amb}", flush=True)
            all_rows.append(g)

    if not all_rows:
        return pd.DataFrame()
    cand = pd.concat(all_rows, ignore_index=True)
    ts = cand["signal_time"].to_numpy()
    cand["tr_w1"] = trend_at_bulk(w1, tr_w1, "W1", ts)
    cand["tr_d1"] = trend_at_bulk(d1, tr_d1, "D1", ts)
    cand["tr_h4"] = trend_at_bulk(h4, tr_h4, "H4", ts)
    cand["hour"] = pd.DatetimeIndex(cand["signal_time"]).hour.astype(np.int8)
    cand["width_pips"] = (cand["band_hi"] - cand["band_lo"]) / p
    pos = np.searchsorted(atr_close_t, ts, side="right") - 1
    cand["atr_pct"] = np.where(pos >= 0, atr_pct[np.clip(pos, 0, None)], np.nan)
    return cand


def _resolve(g: pd.DataFrame, e: pd.DataFrame, rdf: pd.DataFrame):
    """Vectorized SL/TP walk on resolution TF rdf (finest available).

    Entry happens at the open of entry-TF bar entry_i; we walk rdf bars from the
    bar whose open time >= that entry time (aligned opens for H4/H2 -> H1).
    Same-bar SL+TP on the RESOLUTION TF -> LOSS (conservative; rate reported).
    End of data -> mark-to-market. Returns (R, exit_time, ambiguous_count).
    """
    et_entry = g["entry_time"].to_numpy()
    rt = rdf["time"].to_numpy()
    H = rdf["high"].to_numpy(); L = rdf["low"].to_numpy(); C = rdf["close"].to_numpy()
    n = len(rdf)
    m = len(g)
    start = np.searchsorted(rt, et_entry, side="left")
    dirs = g["dir"].to_numpy()
    sl = g["sl"].to_numpy(); tp = g["tp"].to_numpy(); rr = g["rr"].to_numpy()
    entry = g["entry"].to_numpy()
    R = np.full(m, np.nan)
    exit_idx = np.full(m, n - 1, np.int64)
    ambiguous = 0
    tf_sec = int((rt[1] - rt[0]) / np.timedelta64(1, "s")) if n > 1 else 3600
    max_h = int(TIME_STOP_DAYS * 86400 / tf_sec) if TIME_STOP_DAYS > 0 else 0
    active = np.arange(m)
    h = 0
    while len(active):
        if max_h and h >= max_h:               # time-stop: exit MTM at current bar close
            j = np.minimum(start[active] + h, n - 1)
            risk = np.abs(entry[active] - sl[active])
            mtm = np.where(dirs[active] == 1, C[j] - entry[active], entry[active] - C[j])
            R[active] = mtm / risk
            exit_idx[active] = j
            break
        j = start[active] + h
        done_data = j >= n
        if done_data.any():
            sel = active[done_data]
            risk = np.abs(entry[sel] - sl[sel])
            mtm = np.where(dirs[sel] == 1, C[n - 1] - entry[sel], entry[sel] - C[n - 1])
            R[sel] = mtm / risk
            exit_idx[sel] = n - 1
            active = active[~done_data]
            if not len(active):
                break
            j = start[active] + h
        hj = H[j]; lj = L[j]
        buy = dirs[active] == 1
        hit_sl = np.where(buy, lj <= sl[active], hj >= sl[active])
        hit_tp = np.where(buy, hj >= tp[active], lj <= tp[active])
        ambiguous += int((hit_sl & hit_tp).sum())
        lose = hit_sl                       # SL priority on same-bar touch
        win = hit_tp & ~hit_sl
        if lose.any():
            sel = active[lose]; R[sel] = -1.0; exit_idx[sel] = j[lose]
        if win.any():
            sel = active[win]
            R[sel] = rr[sel]
            exit_idx[sel] = j[win]
        active = active[~(lose | win)]
        h += 1
    return R, rt[exit_idx], ambiguous


# ---------------------------------------------------------------- config runner

@dataclass(frozen=True)
class Config:
    bias: str       # off|pair|w|d|h4
    trend: bool
    pattern: bool
    retest: bool
    session: str    # asia|london|newyork|overlap|all

    def label(self):
        t = lambda b: "on" if b else "off"
        return f"{self.bias}/{t(self.trend)}/{t(self.pattern)}/{t(self.retest)}/{self.session}"


def all_configs():
    return [Config(b, tr, pat, ret, s) for b, tr, pat, ret, s in itertools.product(
        ["off", "pair", "w", "d", "h4"], [True, False], [True, False], [True, False],
        ["asia", "london", "newyork", "overlap", "all"])]


def eligibility(cand: pd.DataFrame, cfg: Config) -> np.ndarray:
    d = cand["dir"].to_numpy()
    m = np.ones(len(cand), bool)
    if cfg.bias == "pair":
        w = cand["tr_w1"].to_numpy(); dd = cand["tr_d1"].to_numpy(); h4 = cand["tr_h4"].to_numpy()
        m &= ((w == d) & (dd == d)) | ((dd == d) & (h4 == d))
    elif cfg.bias == "w":
        m &= cand["tr_w1"].to_numpy() == d
    elif cfg.bias == "d":
        m &= cand["tr_d1"].to_numpy() == d
    elif cfg.bias == "h4":
        m &= cand["tr_h4"].to_numpy() == d
    if cfg.trend:
        m &= cand["tr_entry"].to_numpy() == d
    if cfg.pattern:
        m &= cand["pat_ok"].to_numpy()
    if cfg.retest:
        m &= cand["visit_n"].to_numpy() >= 2
    a, b = SESSIONS[cfg.session]
    hr = cand["hour"].to_numpy()
    m &= (hr >= a) & (hr < b)
    return m


def sequence(cand: pd.DataFrame) -> pd.DataFrame:
    """One open trade per sim; max one trade per zone visit (A14)."""
    taken = []
    for _, grp in cand.groupby(["pair", "zone_tf", "entry_tf"], sort=False):
        if len(grp) > 1:
            grp = grp.sort_values("signal_time", kind="stable")
        busy_until = None
        consumed: set[tuple] = set()
        for r in grp.itertuples():
            vkey = (r.zid, r.visit_n)
            if vkey in consumed:
                continue
            if busy_until is not None and r.entry_time < busy_until:
                continue
            taken.append(r.Index)
            consumed.add(vkey)
            busy_until = r.exit_time
        # note: trades may overlap across sims for the same pair (ablation phase
        # mirrors the video's per-cell independent sims)
    return cand.loc[taken] if taken else cand.iloc[0:0]


def metrics(trades: pd.DataFrame) -> dict:
    if not len(trades):
        return {"pf": np.nan, "n": 0, "win": np.nan, "avg_rr": np.nan, "sumR": 0.0}
    R = trades["R"].to_numpy()
    wins = R[R > 0].sum()
    losses = R[R <= 0].sum()
    pf = wins / abs(losses) if losses != 0 else np.inf
    return {"pf": round(float(pf), 3), "n": int(len(R)),
            "win": round(float((R > 0).mean() * 100), 1),
            "avg_rr": round(float(trades["rr"].mean()), 2),
            "sumR": round(float(R.sum()), 1)}


def run_config(cand: pd.DataFrame, cfg: Config, t0=None, t1=None,
               zone_tfs=("D1", "W1"), entry_tfs=None) -> tuple[dict, pd.DataFrame]:
    m = eligibility(cand, cfg)
    if t0 is not None:
        m &= cand["signal_time"].to_numpy() >= np.datetime64(t0)
    if t1 is not None:
        m &= cand["signal_time"].to_numpy() < np.datetime64(t1)
    m &= cand["zone_tf"].isin(zone_tfs).to_numpy()
    if entry_tfs is not None:
        m &= cand["entry_tf"].isin(entry_tfs).to_numpy()
    trades = sequence(cand[m])
    return metrics(trades), trades


# ---------------------------------------------------------------- main

def _build_one(sym: str) -> str:
    c = build_candidates(sym)
    out = DATA / f"cand_{sym}.parquet"
    c.to_parquet(out, index=False)
    return f"{sym}: {len(c)} candidates"


if __name__ == "__main__":
    freeze_support()
    only = sys.argv[1:] or PAIRS
    if len(only) == 1:
        print(_build_one(only[0]))
    else:
        with Pool(min(6, len(only))) as pool:
            for msg in pool.imap_unordered(_build_one, only):
                print(msg, flush=True)
    parts = [pd.read_parquet(DATA / f"cand_{s}.parquet") for s in only
             if (DATA / f"cand_{s}.parquet").exists()]
    allc = pd.concat(parts, ignore_index=True)
    allc.to_parquet(CACHE, index=False)
    print(f"cached {len(allc)} candidates -> {CACHE}")
