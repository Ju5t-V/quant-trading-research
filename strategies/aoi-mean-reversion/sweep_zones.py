"""Pre-registered zone-construction sensitivity sweep (5 fixed variants).

The videos never define zones mechanically; our baseline yields tight zones
(avg SL ~18 pips) that die to costs. These variants target the ONE lever that
matters for cost survival (SL distance / zone strength). Selection on TRAIN
net PF only; TEST gets exactly one look, for train survivors.

  V1 base      : zone_min 5,  touches 3, no SL floor      (his recap rules)
  V2 wide      : zone_min 15, touches 3, no SL floor
  V3 strong    : zone_min 5,  touches 4, no SL floor
  V4 slfloor   : zone_min 5,  touches 3, SL floor 25 pips (deviation R1)
  V5 combo     : zone_min 15, touches 4, SL floor 25 pips
"""
import os
import subprocess
import sys

import numpy as np
import pandas as pd

BASE = r"E:\Documents\Quant Trading\AOI_MeanReversion"
sys.path.insert(0, BASE)

VARIANTS = {
    "V1_base":    {"AOI_ZONE_MIN": "5",  "AOI_TOUCHES": "3", "AOI_MIN_SL": "0"},
    "V2_wide":    {"AOI_ZONE_MIN": "15", "AOI_TOUCHES": "3", "AOI_MIN_SL": "0"},
    "V3_strong":  {"AOI_ZONE_MIN": "5",  "AOI_TOUCHES": "4", "AOI_MIN_SL": "0"},
    "V4_slfloor": {"AOI_ZONE_MIN": "5",  "AOI_TOUCHES": "3", "AOI_MIN_SL": "25"},
    "V5_combo":   {"AOI_ZONE_MIN": "15", "AOI_TOUCHES": "4", "AOI_MIN_SL": "25"},
}

TRAIN = ("2016-01-01", "2022-01-01")
TEST = ("2022-01-01", "2026-06-01")


def evaluate(tag):
    """Import engine fresh (env already set), compute train/test gross+net PF."""
    from importlib import reload
    import engine
    reload(engine)
    import final_eval
    reload(final_eval)
    from engine import Config, run_config
    from final_eval import add_costs

    cand = pd.read_parquet(os.path.join(BASE, "data", "candidates.parquet"))

    def pf(x):
        w = x[x > 0].sum(); l = x[x <= 0].sum()
        return round(float(w / abs(l)), 3) if l != 0 else float("inf")

    out = []
    for ses in ("all", "asia"):
        cfg = Config("off", False, False, False, ses)
        for nm, (t0, t1) in (("train", TRAIN), ("test", TEST)):
            _, tr = run_config(cand, cfg, t0, t1, zone_tfs=("D1",), entry_tfs=("H4", "H2"))
            if not len(tr):
                out.append((ses, nm, 0, np.nan, np.nan, np.nan)); continue
            tr = add_costs(tr)
            out.append((ses, nm, len(tr), pf(tr.R.to_numpy()), pf(tr.R_net.to_numpy()),
                        round(tr.sl_pips.mean(), 1)))
    print(f"\n=== {tag} ===")
    print(f"{'ses':<6}{'set':<7}{'n':>6}  {'PF_gross':>9}  {'PF_net':>7}  {'avgSL':>6}")
    for ses, nm, n, g, nt, asl in out:
        print(f"{ses:<6}{nm:<7}{n:>6}  {g:>9}  {nt:>7}  {asl:>6}")
    return out


def main():
    results = {}
    for tag, env in VARIANTS.items():
        os.environ.update(env)
        print(f"\n########## building {tag}  {env}", flush=True)
        r = subprocess.run([sys.executable, os.path.join(BASE, "engine.py")],
                           cwd=BASE, env={**os.environ},
                           capture_output=True, text=True, timeout=1200)
        tail = [l for l in r.stdout.splitlines() if "cached" in l or "candidates" in l][-1:]
        print("  ", tail, flush=True)
        results[tag] = evaluate(tag)

    print("\n\n================= SWEEP SUMMARY (train net PF is the selector) =================")
    print(f"{'variant':<12}{'ses':<6}{'train n':>8}{'train net':>10}{'test net':>10}{'avgSL':>7}")
    for tag, rows in results.items():
        for ses in ("all", "asia"):
            tr = next(r for r in rows if r[0] == ses and r[1] == "train")
            te = next(r for r in rows if r[0] == ses and r[1] == "test")
            print(f"{tag:<12}{ses:<6}{tr[2]:>8}{tr[4]:>10}{te[4]:>10}{tr[5]:>7}")


if __name__ == "__main__":
    main()
