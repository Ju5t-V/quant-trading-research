"""Generate the next job list from finished results, following plan v2.

    python stage2.py 2a   # 1A 2A 3A (ATR stops) on A and B
    python stage2.py 2b   # E1-E4 + R on the best base B*   (needs 2a)
    python stage2.py 2c   # F = B* + every E that beat B* in both windows (needs 2b)
    python stage2.py 3    # +20-pt stress for F and other dev-gated configs, raw ticks for F and 0b
    python stage2.py 4    # Dukascopy holdout (window C) for the winner, 0b and R, run once

B* = the 2a config with the best min(ratio A, ratio B), ratio = net R / max DD R.
The --set flags for every config live in results/config_sets.json so later stages
rerun exactly the same settings.
"""
import json
import sys
from pathlib import Path

from report import CANDIDATES, evaluate, load, resolve, winner

ROOT = Path(__file__).parent
RES = ROOT / "results"
SETS = RES / "config_sets.json"
SCHED = {"1A": {"levels": "PDH_PDL", "arm_hour": 0, "arm_minute": 5},
         "2A": {"levels": "ASIA"},
         "3A": {"levels": "PDH_PDL", "arm_hour": 6, "arm_minute": 0}}
CHANGES = {"E1": {"tp1_r": 0.5}, "E2": {"runner_mode": "TRAIL", "runner_trail_r": 1.0},
           "E3": {"weekend_flat": True}, "E4": {"sell_filter": True}}


def flags(d: dict) -> str:
    return " ".join(f"--set {k}={v}" for k, v in d.items())


def load_sets() -> dict:
    return json.loads(SETS.read_text()) if SETS.exists() else {}


def write(stage: str, lines: list[str], sets: dict) -> None:
    out = RES / f"queue_stage{stage}.txt"
    out.write_text("\n".join(lines) + "\n")
    SETS.write_text(json.dumps(sets, indent=2))
    print(out.read_text())


def main() -> None:
    stage = sys.argv[1] if len(sys.argv) > 1 else ""
    sets = load_sets()

    if stage == "2a":
        for n, s in SCHED.items():
            sets[n] = dict(s)
        lines = ["# plan v2 step 2a: partial profit + breakeven with ATR-sized stops"]
        lines += [f"--name {n} --window {w}" for w in ("A", "B") for n in SCHED]
        write("2a", lines, sets)

    elif stage == "2b":
        ev = evaluate(load(), sets)
        sub = ev[ev["config"].isin(list(SCHED))].sort_values("min_ratio", ascending=False)
        if len(sub) < 3:
            raise SystemExit("step 2a results incomplete")
        best = sub["config"].iloc[0]
        sets["B*"] = best
        for n in ("E1", "E2", "E3", "E4", "R"):
            sets[n] = dict(SCHED[best])
        lines = [f"# plan v2 step 2b: min(ratio A, ratio B) of 2a = "
                 f"{dict(zip(sub['config'], sub['min_ratio'].round(3)))} -> B* = {best} {SCHED[best]}"]
        lines += [f"--name {n} --window {w} {flags(sets[n])}" for w in ("A", "B")
                  for n in ("E1", "E2", "E3", "E4", "R")]
        write("2b", lines, sets)

    elif stage == "2c":
        base = sets["B*"]
        ev = evaluate(load(), sets).set_index("config")
        missing = [e for e in CHANGES if e not in ev.index]
        if missing:
            raise SystemExit(f"step 2b results incomplete: {missing}")
        kept = [e for e in CHANGES if ev.loc[e, "ratio_A"] > ev.loc[base, "ratio_A"]
                and ev.loc[e, "ratio_B"] > ev.loc[base, "ratio_B"]]
        lines = [f"# plan v2 step 2c: B* = {base}; improvements that beat B* in both windows: {kept or 'none'}"]
        sets.pop("F_alias", None)
        if len(kept) >= 2:
            f = dict(SCHED[base])
            for e in kept:
                f.update(CHANGES[e])
            sets["F"] = f
            lines += [f"--name F --window {w} {flags(f)}" for w in ("A", "B")]
        else:
            sets["F_alias"] = kept[0] if kept else base
            lines.append(f"# F = {sets['F_alias']} (already run, no new runs)")
        write("2c", lines, sets)

    elif stage == "3":
        ev = evaluate(load(), sets)
        gated = ev[ev["dev_gates"] & ev["config"].isin(CANDIDATES)]["config"].tolist()
        stress = sorted({resolve("F", sets)} | {resolve(c, sets) for c in gated})
        lines = [f"# plan v2 step 3: dev-gated configs {gated or 'none'}; stress runs for {stress}"]
        lines += [f"--name {n} --window {w} --stress {flags(sets.get(n, {}))}" for n in stress for w in ("A", "B")]
        for n in (resolve("F", sets), "0b"):
            lines += [f"--name {n} --window {w} --raw {flags(sets.get(n, {}))}" for w in ("A", "B")]
        write("3", lines, sets)

    elif stage == "4":
        df = load()
        w = winner(df, sets)
        lines = [f"# plan v2 step 4 (holdout, run once): winner = {w or 'NONE'}"]
        if w is None:
            # the plan lists the holdout as F, 0b and R: with no winner, F (the ladder's
            # pre-committed result) still runs, for information only
            lines.append("# nothing passed the gates; holdout runs F, 0b and R for information only, as planned")
        rep = resolve(w if w else "F", sets)
        names = ["0b", "R", rep]
        lines += [f"--name {n} --window C --feed duka {flags(sets.get(n, {}))}" for n in names]
        sets["winner"] = w
        sets["holdout_config"] = rep
        write("4", lines, sets)

    else:
        raise SystemExit(__doc__)


if __name__ == "__main__":
    main()
