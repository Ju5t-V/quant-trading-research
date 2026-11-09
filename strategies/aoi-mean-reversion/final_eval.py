"""Final evaluation: costs + high-watermark equity sim on the surviving configs.

Cost model (SPEC A11): per-pair typical raw spread + $7/lot RT commission
(~0.7 pips equivalent); Asia hours (01-10 server) spread x1.5 (thin liquidity).
Cost enters as an R-multiple haircut: cost_pips / SL_pips per trade.
Equity sim: risk% of high-water-mark balance per trade, $10k start.
"""
import numpy as np
import pandas as pd

from engine import Config, run_config

CAND = r"E:\Documents\Quant Trading\AOI_MeanReversion\data\candidates.parquet"

SPREAD = {"EURUSD": 0.10, "GBPUSD": 0.25, "USDCHF": 0.30, "USDCAD": 0.30,
          "NZDUSD": 0.40, "AUDJPY": 0.40, "EURJPY": 0.40, "EURGBP": 0.40,
          "AUDCHF": 0.60, "AUDCAD": 0.60, "EURAUD": 0.70, "GBPCHF": 0.90,
          "NZDCAD": 0.90, "GBPCAD": 1.00, "GBPAUD": 1.00, "GBPNZD": 1.80}
COMMISSION_PIPS = 0.7
ASIA_MULT = 1.5


def add_costs(trades: pd.DataFrame) -> pd.DataFrame:
    t = trades.copy()
    p = np.where(t.pair.str.contains("JPY"), 0.01, 0.0001)
    sl_pips = np.abs(t.entry - t.sl) / p
    spr = t.pair.map(SPREAD).to_numpy()
    spr = np.where((t.hour >= 1) & (t.hour < 10), spr * ASIA_MULT, spr)
    cost_R = (spr + COMMISSION_PIPS) / sl_pips
    t["R_net"] = t.R - cost_R
    t["sl_pips"] = sl_pips
    return t


def equity_sim(trades: pd.DataFrame, rcol="R_net", risk=0.005, hwm=True, start=10_000.0):
    t = trades.sort_values("entry_time")
    eq = start; peak = start
    curve_t, curve_v = [], []
    ruined = False
    for r in t[[rcol]].itertuples(index=False):
        base = peak if hwm else eq
        eq += risk * base * r[0]
        if eq <= 0:                      # account blown — stop the sim
            eq = 0.0; curve_v.append(eq); ruined = True
            break
        peak = max(peak, eq)
        curve_v.append(eq)
    if not curve_v:
        return {}
    v = np.array(curve_v)
    peaks = np.maximum.accumulate(np.maximum(v, 1e-9))
    dd = ((v - peaks) / peaks).min() * 100
    yrs = (t.entry_time.iloc[-1] - t.entry_time.iloc[0]) / np.timedelta64(1, "s") / 86400 / 365.25
    ret = (v[-1] / start - 1) * 100
    cagr = ((v[-1] / start) ** (1 / yrs) - 1) * 100 if v[-1] > 0 else -100.0
    t2 = t.iloc[:len(v)].copy(); t2["eq"] = v
    yearly = t2.groupby(t2.entry_time.dt.year)["eq"].last()
    yearly_ret = yearly.pct_change() * 100
    yearly_ret.iloc[0] = (yearly.iloc[0] / start - 1) * 100
    return {"final": round(v[-1]), "ret%": round(ret, 1), "cagr%": round(cagr, 1),
            "maxDD%": round(dd, 1), "n": len(t), "ruined": ruined,
            "yearly": yearly_ret.round(1).to_dict()}


def pf(x):
    w = x[x > 0].sum(); l = x[x <= 0].sum()
    return round(float(w / abs(l)), 3) if l else np.inf


def main():
    cand = pd.read_parquet(CAND)
    print("=" * 100)
    for ses in ("all", "asia"):
        for tfs, tf_label, t0 in ((("H4",), "H4", "2016-01-01"),
                                  (("H2",), "H2", "2016-01-01"),
                                  (("M15",), "M15 (2022+ only)", "2022-01-01")):
            cfg = Config("off", False, False, False, ses)
            _, tr = run_config(cand, cfg, t0, "2026-06-01", zone_tfs=("D1",), entry_tfs=tfs)
            if not len(tr):
                continue
            tr = add_costs(tr)
            g = equity_sim(tr, "R", risk=0.005)
            n_ = equity_sim(tr, "R_net", risk=0.005)
            print(f"\n--- D1 zones / {ses} / {tf_label}:  {len(tr)} trades, "
                  f"avg SL {tr.sl_pips.mean():.0f} pips")
            print(f"    PF gross {pf(tr.R.to_numpy())} -> net {pf(tr.R_net.to_numpy())}")
            print(f"    0.5% HWM gross: ret {g['ret%']}%  CAGR {g['cagr%']}%  DD {g['maxDD%']}%")
            print(f"    0.5% HWM net:   ret {n_['ret%']}%  CAGR {n_['cagr%']}%  DD {n_['maxDD%']}%")
            print(f"    net yearly: {n_['yearly']}")
    print("\n" + "=" * 100)
    print("TRAIN vs TEST, net of costs (D1 zones, H4):")
    for ses in ("all", "asia"):
        cfg = Config("off", False, False, False, ses)
        for nm, t0, t1 in (("train 2016-21", "2016-01-01", "2022-01-01"),
                           ("test  2022-26", "2022-01-01", "2026-06-01")):
            _, tr = run_config(cand, cfg, t0, t1, zone_tfs=("D1",), entry_tfs=("H4",))
            tr = add_costs(tr)
            print(f"  {ses:<5} {nm}: n {len(tr):>5}  PF net {pf(tr.R_net.to_numpy())}")


if __name__ == "__main__":
    main()
