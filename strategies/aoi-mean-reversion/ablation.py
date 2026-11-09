"""Ablation grid — replicates video 2's methodology.

TRAIN  = 2016-01-01 .. 2022-01-01  (his: Jan 2016 - Dec 2021)
TEST   = 2022-01-01 .. 2026-06-01  (locked until winners are chosen on TRAIN)
Ablation entry TFs = H4/H2/H1 (full 2016+ coverage on our feed).
M30 (2018+) and M15 (2022+) evaluated separately as Phase B.
Ranking metric = R-multiple profit factor (his: costs excluded, 2% fixed risk).
"""
import numpy as np
import pandas as pd

from engine import Config, all_configs, run_config

CAND = r"E:\Documents\Quant Trading\AOI_MeanReversion\data\candidates.parquet"
OUT = r"E:\Documents\Quant Trading\AOI_MeanReversion\results"

TRAIN = ("2016-01-01", "2022-01-01")
TEST = ("2022-01-01", "2026-06-01")
ABL_TFS = ("H4", "H2", "H1")

def main():
    import os
    os.makedirs(OUT, exist_ok=True)
    cand = pd.read_parquet(CAND)
    print(f"candidates: {len(cand)}  pairs: {cand.pair.nunique()}")

    rows = []
    for i, cfg in enumerate(all_configs()):
        m, _ = run_config(cand, cfg, *TRAIN, entry_tfs=ABL_TFS)
        rows.append({"config": cfg.label(), "bias": cfg.bias,
                     "trend": "on" if cfg.trend else "off",
                     "pattern": "on" if cfg.pattern else "off",
                     "retest": "on" if cfg.retest else "off",
                     "session": cfg.session, **m})
        if (i + 1) % 40 == 0:
            print(f"  {i+1}/200 configs done", flush=True)

    df = pd.DataFrame(rows).sort_values("pf", ascending=False).reset_index(drop=True)
    df.index += 1
    df.to_csv(f"{OUT}/ablation_train.csv")

    pd.set_option("display.width", 160)
    print("\n=== TRAIN ranking (top 25) ===")
    print(df.head(25).to_string())
    print("\n=== bottom 5 ===")
    print(df.tail(5).to_string())

    alloff = df[(df.bias == "off") & (df.trend == "off") & (df.pattern == "off") & (df.retest == "off")]
    print("\n=== all-off variants (his anchors: asia #2 1.139 / overlap #6 1.128 / all #9-ish 1.10) ===")
    print(alloff.to_string())

    pairbias = df[df.bias == "pair"]
    print(f"\nbest PAIR-bias rank: #{pairbias.index.min()} (his: #38, barely >1)")

    print("\n=== bias marginal effect (mean PF by bias, train) ===")
    print(df.groupby("bias")["pf"].mean().sort_values(ascending=False).to_string())
    print("\n=== session marginal effect ===")
    print(df.groupby("session")["pf"].mean().sort_values(ascending=False).to_string())
    for col in ("trend", "pattern", "retest"):
        g = df.groupby(col)["pf"].mean()
        print(f"{col}: on {g.get('on', np.nan):.3f}  off {g.get('off', np.nan):.3f}")

    # ---- locked-test evaluation of the pre-registered winner configs
    print("\n=== TEST set (2022-2026) — winner configs chosen on TRAIN ===")
    winners = [Config("off", False, False, False, s) for s in ("all", "overlap", "asia")]
    for cfg in winners:
        tr_m, _ = run_config(cand, cfg, *TRAIN, entry_tfs=ABL_TFS)
        te_m, _ = run_config(cand, cfg, *TEST, entry_tfs=ABL_TFS)
        print(f"{cfg.label():<28} train PF {tr_m['pf']:<6} n {tr_m['n']:<5} | "
              f"test PF {te_m['pf']:<6} n {te_m['n']:<5} win {te_m['win']}%")

    # ---- his final strategy: D1 zones only, per entry TF (replicates the video table)
    print("\n=== Final-strategy TF table (D1 zones, all-off), full period 2016-2026 ===")
    print(f"{'TF':<5} {'ALL: PF':<10} {'n':<6} {'OVL: PF':<10} {'n':<6}")
    for tf in ("H4", "H2", "H1", "M30", "M15"):
        a, _ = run_config(cand, Config("off", False, False, False, "all"),
                          "2016-01-01", "2026-06-01", zone_tfs=("D1",), entry_tfs=(tf,))
        o, _ = run_config(cand, Config("off", False, False, False, "overlap"),
                          "2016-01-01", "2026-06-01", zone_tfs=("D1",), entry_tfs=(tf,))
        print(f"{tf:<5} {a['pf']:<10} {a['n']:<6} {o['pf']:<10} {o['n']:<6}")

    # ---- per-pair robustness of the final config (D1, all-off/all, H4H2H1 + M30/M15)
    print("\n=== per-pair PF (D1 zones, all-off/all, full period, all entry TFs) ===")
    for pair in sorted(cand.pair.unique()):
        sub = cand[cand.pair == pair]
        m, _ = run_config(sub, Config("off", False, False, False, "all"),
                          "2016-01-01", "2026-06-01", zone_tfs=("D1",))
        print(f"{pair}: PF {m['pf']:<7} n {m['n']}")

if __name__ == "__main__":
    main()
