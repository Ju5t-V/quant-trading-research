"""Trade-list statistics shared by run_matrix.py, report.py and stage2.py."""
import math

import numpy as np
import pandas as pd

SERVER_TZ = "Europe/Athens"


def _pf(p: pd.Series) -> float:
    gp = p[p > 0].sum()
    gl = -p[p <= 0].sum()
    return float(gp / gl) if gl > 0 else math.inf


def _max_dd(values: np.ndarray) -> float:
    eq = np.concatenate([[0.0], np.cumsum(values)])
    return float(np.max(np.maximum.accumulate(eq) - eq))


def summarize(df: pd.DataFrame, risk_usd: float = 100.0, start_equity: float = 10_000.0) -> dict:
    """Win = trade net P&L > 0. Scratch = |result| < 0.1R (reported, not removed).
    R figures assume a constant $ risk per trade (1% of $10k = $100).
    ret_dd = net R / max drawdown R: profit at equal drawdown (the plan's metric)."""
    if df is None or len(df) == 0:
        return {"trades": 0}
    d = df.sort_values("exit_ns").reset_index(drop=True)
    win = d["pnl_usd"] > 0
    net_r = float(d["pnl_R"].sum())
    dd_r = _max_dd(d["pnl_R"].to_numpy())
    eq_usd = start_equity + np.concatenate([[0.0], d["pnl_usd"].cumsum().to_numpy()])
    peak = np.maximum.accumulate(eq_usd)
    out = dict(
        trades=len(d),
        win_pct=round(100 * win.mean(), 1),
        scratch_pct=round(100 * (d["pnl_R"].abs() < 0.1).mean(), 1),
        pf=round(_pf(d["pnl_usd"]), 3),
        net_R=round(net_r, 2),
        max_dd_R=round(dd_r, 2),
        ret_dd=round(net_r / dd_r, 3) if dd_r > 0 else (math.inf if net_r > 0 else 0.0),
        exp_R=round(float(d["pnl_R"].mean()), 4),
        avg_win_R=round(float(d.loc[win, "pnl_R"].mean()), 3) if win.any() else 0.0,
        avg_loss_R=round(float(d.loc[~win, "pnl_R"].mean()), 3) if (~win).any() else 0.0,
        net_usd_at_1pct=round(net_r * risk_usd, 0),
        max_dd_pct_at_1pct=round(dd_r * risk_usd / start_equity * 100, 1),
        net_usd_actual=round(float(d["pnl_usd"].sum()), 0),
        min_equity_actual=round(float(eq_usd.min()), 0),
        max_dd_usd_actual=round(float(np.max(peak - eq_usd)), 0),
        swap_R_est=round(float((d["swap_usd_est"] / (d["qty"] * d["r_pts"] * 0.01)).sum()), 2),
        overnight_pct=round(100 * (d["swap_nights"] > 0).mean(), 1),
        median_hold_min=round(float(d["hold_min"].median()), 1),
        days_two_trades=int((d.groupby("day").size() >= 2).sum()),
        tp1_hit_pct=round(100 * d["tp1_hit"].mean(), 1),
        median_r_pts=round(float(d["r_pts"].median()), 0),
        median_spread_pct_of_R=round(float((d["spread_at_arm_pts"] / d["r_pts"] * 100).median()), 2),
        trail_exits=int((d["exit_kind"] == "TRAIL").sum()),
        weekend_exits=int((d["exit_kind"] == "WKND").sum()),
    )
    if "max_stop_slip_pts" in d.columns:
        big = (d["entry_slip_pts"] > 100) | (d["max_stop_slip_pts"] > 100)   # > $1 beyond the order price
        out["big_slip_trades"] = int(big.sum())
        out["big_slip_net_R"] = round(float(d.loc[big, "pnl_R"].sum()), 2)
        out["median_entry_slip_pts"] = round(float(d["entry_slip_pts"].median()), 1)
    for side in ("BUY", "SELL"):
        s = d[d["side"] == side]
        out[f"{side.lower()}_n"] = len(s)
        out[f"{side.lower()}_win_pct"] = round(100 * (s["pnl_usd"] > 0).mean(), 1) if len(s) else 0.0
        out[f"{side.lower()}_net_R"] = round(float(s["pnl_R"].sum()), 2)
        out[f"{side.lower()}_pf"] = round(_pf(s["pnl_usd"]), 3) if len(s) else 0.0
    return out


def yearly(df: pd.DataFrame) -> pd.DataFrame:
    """Per-year results including the typical stop size and spread cost relative to 1R."""
    if df is None or len(df) == 0:
        return pd.DataFrame()
    d = df.copy()
    d["year"] = pd.to_datetime(d["exit_ns"], unit="ns", utc=True).dt.tz_convert(SERVER_TZ).dt.year
    rows = []
    for y, g in d.sort_values("exit_ns").groupby("year"):
        dd = _max_dd(g["pnl_R"].to_numpy())
        rows.append(dict(year=y, trades=len(g), win_pct=round(100 * (g["pnl_usd"] > 0).mean(), 1),
                         pf=round(_pf(g["pnl_usd"]), 2), net_R=round(float(g["pnl_R"].sum()), 1),
                         max_dd_R=round(dd, 1), median_r_pts=round(float(g["r_pts"].median())),
                         spread_pct_R=round(float((g["spread_at_arm_pts"] / g["r_pts"] * 100).median()), 1),
                         median_hold_min=round(float(g["hold_min"].median()), 1)))
    return pd.DataFrame(rows)


def equity_sim(df: pd.DataFrame, recovery: bool, start: float = 10_000.0, risk: float = 0.01,
               low_risk: float = 0.001, lookback: int = 10) -> dict:
    """Compounding equity from the R trade list. Recovery mode (GoldBreakoutEA v1.31):
    risk drops to low_risk while the last `lookback` trades closed before this entry are
    net negative in dollars. Equity only counts trades already closed at entry time."""
    if df is None or len(df) == 0:
        return {}
    d = df.sort_values("entry_ns").reset_index(drop=True)
    entry = d["entry_ns"].to_numpy()
    exit_ = d["exit_ns"].to_numpy()
    r = d["pnl_R"].to_numpy()
    pnl = np.zeros(len(d))
    reduced = 0
    for i in range(len(d)):
        done = np.where(exit_[:i] < entry[i])[0]
        equity = start + pnl[done].sum()
        rk = risk
        if recovery and len(done):
            last = done[np.argsort(exit_[done])][-lookback:]
            if pnl[last].sum() < 0:
                rk = low_risk
                reduced += 1
        pnl[i] = r[i] * rk * max(equity, 0.0)
    order = np.argsort(exit_)
    eq = start + np.concatenate([[0.0], np.cumsum(pnl[order])])
    peak = np.maximum.accumulate(eq)
    dd_pct = float(np.max((peak - eq) / peak) * 100)
    ret_pct = float((eq[-1] / start - 1) * 100)
    return dict(recovery=recovery, final_equity=round(float(eq[-1]), 0), return_pct=round(ret_pct, 1),
                max_dd_pct=round(dd_pct, 1), return_per_dd=round(ret_pct / dd_pct, 2) if dd_pct > 0 else math.inf,
                trades_at_reduced_risk=reduced)
