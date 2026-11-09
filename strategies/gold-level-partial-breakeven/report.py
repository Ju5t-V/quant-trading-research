"""Collect results/*.json + *.csv into tables and apply the plan-v2 rules.

Metric (plan v2, fixed before any stage-1 result was read): profit at equal drawdown,
ratio = net R / max drawdown R, per dev window (A = Jun 2025-Sep 2026, B = 2019-2020).
"Better" = higher ratio in BOTH windows.
Gates for a winner: in each dev window net R > 0, PF >= 1.3, ratio >= the original's
(0b); and PF >= 1.1 with spreads widened 20 pts in both windows.
Winner = F (resolved alias) if it passes all gates, else the gated config with the best
min(ratio A, ratio B). R (v1.31 trail exit) is a reference, never a winner.

    python report.py        # tables + evaluation
    python report.py -y     # plus per-year tables
"""
import json
import math
import sys
from pathlib import Path

import pandas as pd

from stats import equity_sim, yearly

ROOT = Path(__file__).parent
RES = ROOT / "results"
SETS = RES / "config_sets.json"
CANDIDATES = ("1A", "2A", "3A", "E1", "E2", "E3", "E4", "F")
REFERENCE = ("0b", "R", "1", "2", "3")
COLS = ["trades", "win_pct", "pf", "net_R", "max_dd_R", "ret_dd", "avg_win_R", "avg_loss_R",
        "net_usd_at_1pct", "max_dd_pct_at_1pct", "buy_net_R", "sell_net_R", "tp1_hit_pct",
        "median_hold_min", "overnight_pct", "swap_R_est", "median_r_pts", "median_spread_pct_of_R",
        "trail_exits", "weekend_exits", "days_two_trades", "big_slip_trades"]


def load_sets() -> dict:
    return json.loads(SETS.read_text()) if SETS.exists() else {}


def resolve(name: str, sets: dict | None = None) -> str:
    """F may be an alias of a single improvement or of the base B* (see stage2.py 2c)."""
    sets = load_sets() if sets is None else sets
    return sets.get("F_alias", "F") if name == "F" else name


def load() -> pd.DataFrame:
    rows = []
    for f in sorted(RES.glob("*.json")):
        if f.name == SETS.name:
            continue
        j = json.loads(f.read_text())
        s = j.get("summary", {})
        if "tag" not in j or not s:
            continue
        row = dict(tag=j["tag"], data=j.get("data"), seconds=j.get("seconds"))
        row.update({k: s.get(k) for k in COLS})
        rows.append(row)
    return pd.DataFrame(rows).set_index("tag") if rows else pd.DataFrame()


def _get(df: pd.DataFrame, tag: str, col: str) -> float:
    if df.empty or tag not in df.index or df.loc[tag, col] is None:
        return math.nan
    return float(df.loc[tag, col])


def ratio(df: pd.DataFrame, tag: str) -> float:
    net, dd = _get(df, tag, "net_R"), _get(df, tag, "max_dd_R")
    if math.isnan(net) or math.isnan(dd):
        return math.nan
    return net / dd if dd > 0 else (math.inf if net > 0 else 0.0)


def evaluate(df: pd.DataFrame, sets: dict | None = None) -> pd.DataFrame:
    sets = load_sets() if sets is None else sets
    rows = []
    for name in CANDIDATES + REFERENCE:
        n = resolve(name, sets)
        if f"{n}_A" not in df.index or f"{n}_B" not in df.index:
            continue
        row = dict(config=name, results=n)
        for w in ("A", "B"):
            t = f"{n}_{w}"
            row[f"ratio_{w}"] = ratio(df, t)
            row[f"base_{w}"] = ratio(df, f"0b_{w}")
            row[f"net_R_{w}"] = _get(df, t, "net_R")
            row[f"pf_{w}"] = _get(df, t, "pf")
            row[f"win_{w}"] = _get(df, t, "win_pct")
            row[f"stress_pf_{w}"] = _get(df, f"{t}_stress", "pf")
        row["min_ratio"] = min(row["ratio_A"], row["ratio_B"])
        row["dev_gates"] = all(row[f"net_R_{w}"] > 0 and row[f"pf_{w}"] >= 1.3 and
                               row[f"ratio_{w}"] >= row[f"base_{w}"] for w in ("A", "B"))
        row["stress_ok"] = all(row[f"stress_pf_{w}"] >= 1.1 for w in ("A", "B"))
        row["all_gates"] = row["dev_gates"] and row["stress_ok"] and name in CANDIDATES
        rows.append(row)
    return pd.DataFrame(rows)


def winner(df: pd.DataFrame, sets: dict | None = None):
    ev = evaluate(df, sets)
    if ev.empty:
        return None
    f = ev[(ev["config"] == "F") & ev["all_gates"]]
    if len(f):
        return "F"
    ok = ev[ev["all_gates"]]
    return None if ok.empty else ok.sort_values("min_ratio", ascending=False)["config"].iloc[0]


def margin_check(csv: Path, start_equity: float = 10_000.0, leverage: float = 100.0) -> dict:
    """MT5-style check for fixed-lot runs: at each fill, would free margin (1:100) cover it?"""
    d = pd.read_csv(csv).sort_values("entry_ns").reset_index(drop=True)
    exits = d[["exit_ns", "pnl_usd"]].to_numpy()
    rejects, blown = 0, None
    for _, r in d.iterrows():
        equity = start_equity + exits[exits[:, 0] < r["entry_ns"], 1].sum()
        if equity <= 0 and blown is None:
            blown = r["day"]
        open_now = d[(d["entry_ns"] < r["entry_ns"]) & (d["exit_ns"] > r["entry_ns"])]
        used = float((open_now["qty"] * open_now["entry_px"]).sum()) / leverage
        if r["qty"] * r["entry_px"] / leverage > equity - used:
            rejects += 1
    return dict(trades=len(d), fills_mt5_would_reject=rejects, equity_below_zero_on=blown)


def resummarize() -> None:
    """Recompute the summary block of every result JSON from its trade CSV (adds newer columns)."""
    from stats import summarize
    for f in sorted(RES.glob("*.json")):
        if f.name == SETS.name:
            continue
        j = json.loads(f.read_text())
        csv = RES / f"{j.get('tag', '')}.csv"
        if "summary" not in j or not csv.exists() or csv.stat().st_size <= 5:
            continue
        j["summary"] = summarize(pd.read_csv(csv))
        f.write_text(json.dumps(j, indent=2, default=str))
        print(f"resummarized {f.name}")


if __name__ == "__main__":
    if "--resummarize" in sys.argv:
        resummarize()
    df = load()
    if df.empty:
        raise SystemExit("no results yet")
    pd.set_option("display.width", 280)
    pd.set_option("display.max_columns", 50)
    print(df[["data"] + COLS].to_string())
    for tag in df.index:
        if tag.startswith("0a") and (RES / f"{tag}.csv").exists():
            print(f"\n{tag} margin check at 1:100 from $10,000:", margin_check(RES / f"{tag}.csv"))
    ev = evaluate(df)
    if len(ev):
        print("\n=== plan v2 evaluation (ratio = net R / max drawdown R) ===")
        print(ev.to_string(index=False))
        w = winner(df)
        print("winner:", w, "->", resolve(w) if w else "")
        for name in [x for x in ("0b", w, "R") if x]:
            n = resolve(name)
            for win in ("A", "B"):
                csv = RES / f"{n}_{win}.csv"
                if csv.exists():
                    t = pd.read_csv(csv)
                    print(f"  equity {name} {win}: fixed 1% {equity_sim(t, False)}  recovery {equity_sim(t, True)}")
    if "-y" in sys.argv:
        for tag in df.index:
            csv = RES / f"{tag}.csv"
            if csv.exists() and csv.stat().st_size > 5:
                print(f"\n--- {tag} by year")
                print(yearly(pd.read_csv(csv)).to_string(index=False))
