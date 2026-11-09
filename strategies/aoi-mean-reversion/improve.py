"""Pre-registered improvement pass. Baseline = V4 (zone_min 5, touches 3, SL floor 25).

Rebuild variants (engine env knobs):
  I1a time-stop 5d   | I1b time-stop 10d     (mean-reversion thesis decays)
  I2a TP cap 3R      | I2b TP cap 2.5R      (shallow reversion -> closer targets)
  I3  SL 15p beyond band                     (fewer stop-hunts through band edge)
Runtime-filter variants (no rebuild):
  I4  zone quality: ntouch>=4 AND width>=15p (trade only established levels)
  I5  volatility: skip atr_pct > 0.9         (blowout days break S/R)

Selection: TRAIN (2016-2021) net PF, asia session, D1 zones, H4+H2, 16 pairs.
Anything beating baseline by >= +0.03 net PF joins the combo; combo gets ONE test look.
"""
import os
import subprocess
import sys

import numpy as np
import pandas as pd

BASE = r"E:\Documents\Quant Trading\AOI_MeanReversion"
sys.path.insert(0, BASE)

V4 = {"AOI_ZONE_MIN": "5", "AOI_TOUCHES": "3", "AOI_MIN_SL": "25",
      "AOI_SL_BEYOND": "5", "AOI_MAX_RR": "4", "AOI_TIME_STOP": "0"}

REBUILD_VARIANTS = {
    "B_base":  {},
    "I1a_ts5": {"AOI_TIME_STOP": "5"},
    "I1b_ts10": {"AOI_TIME_STOP": "10"},
    "I2a_rr3": {"AOI_MAX_RR": "3"},
    "I2b_rr25": {"AOI_MAX_RR": "2.5"},
    "I3_sl15": {"AOI_SL_BEYOND": "15"},
}

TRAIN = ("2016-01-01", "2022-01-01")
TEST = ("2022-01-01", "2026-06-01")


def build(env):
    e = {**os.environ, **V4, **env}
    r = subprocess.run([sys.executable, os.path.join(BASE, "engine.py")],
                       cwd=BASE, env=e, capture_output=True, text=True, timeout=1800)
    if "cached" not in r.stdout:
        print("BUILD FAILED:", r.stdout[-500:], r.stderr[-500:])
        raise SystemExit(1)


def evaluate(tag, extra_filter=None, window=TRAIN):
    from importlib import reload
    import engine, final_eval
    reload(engine); reload(final_eval)
    from engine import Config, run_config
    from final_eval import add_costs

    cand = pd.read_parquet(os.path.join(BASE, "data", "candidates.parquet"))
    if extra_filter is not None:
        cand = cand[extra_filter(cand)]
    out = {}
    for ses in ("asia", "all"):
        cfg = Config("off", False, False, False, ses)
        _, tr = run_config(cand, cfg, *window, zone_tfs=("D1",), entry_tfs=("H4", "H2"))
        if not len(tr):
            out[ses] = (0, np.nan, np.nan); continue
        tr = add_costs(tr)
        w = tr.R_net[tr.R_net > 0].sum(); l = tr.R_net[tr.R_net <= 0].sum()
        wg = tr.R[tr.R > 0].sum(); lg = tr.R[tr.R <= 0].sum()
        out[ses] = (len(tr), round(float(wg / abs(lg)), 3), round(float(w / abs(l)), 3))
    return out


def main():
    results = {}
    for tag, env in REBUILD_VARIANTS.items():
        print(f"building {tag} ...", flush=True)
        build(env)
        results[tag] = evaluate(tag)
        n, g, nt = results[tag]["asia"]
        print(f"  {tag}: asia train n={n} gross={g} net={nt}   all={results[tag]['all']}", flush=True)

    # runtime filters evaluated on the BASELINE build (rebuild base last)
    print("rebuilding baseline for runtime filters ...", flush=True)
    build({})
    results["I4_zoneq"] = evaluate("I4", lambda c: (c.ntouch >= 4) & (c.width_pips >= 15))
    print(f"  I4_zoneq: {results['I4_zoneq']}", flush=True)
    results["I5_vol"] = evaluate("I5", lambda c: ~(c.atr_pct > 0.9))
    print(f"  I5_vol: {results['I5_vol']}", flush=True)

    print("\n===== TRAIN summary (asia net PF is the selector; baseline first) =====")
    base_net = results["B_base"]["asia"][2]
    print(f"{'variant':<10}{'n':>6}{'gross':>8}{'net':>8}{'d_net':>8}")
    for tag, r in results.items():
        n, g, nt = r["asia"]
        print(f"{tag:<10}{n:>6}{g:>8}{nt:>8}{round(nt-base_net,3):>+8}")


if __name__ == "__main__":
    main()
