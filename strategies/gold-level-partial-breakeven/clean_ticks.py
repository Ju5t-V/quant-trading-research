"""Remove clearly broken quotes from exported ticks.

    python clean_ticks.py              # MetaQuotes: data/ticks -> data/ticks_clean
    python clean_ticks.py --feed duka  # Dukascopy:  data/duka_ticks -> data/duka_ticks_clean

Rule (fixed before any strategy results were seen, after profiling all ticks):
  1. drop a quote whose spread is wider than max($3.00, 10 x that server day's
     median spread). This removes the seconds-long spread explosions at the
     01:00 server reopen (up to $149 in Jul-Sep 2026, ask side only) and feed
     glitches such as 2019-02-27 02:56-03:02 ($10-$29 spreads when the normal
     spread was $0.28, which filled both stop orders at once).
  2. MetaQuotes only: drop a quote whose bid lies outside the broker's own M1 bar
     for that minute (MT5's bars leave those glitches out). Dukascopy has no
     independent bar source, so only rule 1 applies there.
March 2020's genuinely wide COVID spreads survive rule 1 because that month's
daily medians were wide too. Raw ticks stay available for sensitivity runs.
"""
import sys
from pathlib import Path

import numpy as np
import pandas as pd

ROOT = Path(__file__).parent
MIN_WIDE = 3.00
MULT = 10.0
FEEDS = {"mt5": ("ticks", "ticks_clean", "cleaning_log.csv"),
         "duka": ("duka_ticks", "duka_ticks_clean", "cleaning_log_duka.csv")}


def main(feed: str) -> None:
    src_name, dst_name, log_name = FEEDS[feed]
    src, dst = ROOT / "data" / src_name, ROOT / "data" / dst_name
    dst.mkdir(parents=True, exist_ok=True)
    m1 = None
    if feed == "mt5":
        m1 = pd.read_parquet(ROOT / "data" / "bars" / "XAUUSD_M1.parquet", columns=["srv_ms", "high", "low"])
        m1 = m1.set_index(m1["srv_ms"] // 60000)[["high", "low"]]
        m1 = m1[~m1.index.duplicated()]
    rows = []
    for f in sorted(src.glob("XAUUSD_*.parquet")):
        out = dst / f.name
        if out.exists() and "--overwrite" not in sys.argv:
            continue
        t = pd.read_parquet(f)
        ms = t["srv_ms"].to_numpy()
        bid = t["bid"].to_numpy()
        sp = t["ask"].to_numpy() - bid
        med = pd.Series(sp).groupby(ms // 86_400_000).transform("median").to_numpy()
        wide = sp > np.maximum(MIN_WIDE, MULT * med)
        outside = np.zeros(len(t), dtype=bool)
        if m1 is not None:
            j = m1.reindex(ms // 60000)
            hi, lo = j["high"].to_numpy(), j["low"].to_numpy()
            outside = ~np.isnan(hi) & ((bid > hi + 1e-6) | (bid < lo - 1e-6))
        keep = ~(wide | outside)
        t[keep].reset_index(drop=True).to_parquet(out, compression="zstd", index=False)
        rows.append(dict(month=f.stem[-6:], ticks=len(t), too_wide=int(wide.sum()),
                         bid_outside_bar=int(outside.sum()), removed=int((~keep).sum()),
                         removed_pct=round(100 * float((~keep).mean()), 4)))
        print(rows[-1], flush=True)
    if rows:
        log = pd.DataFrame(rows)
        path = ROOT / "results" / log_name
        if path.exists() and "--overwrite" not in sys.argv:
            log = pd.concat([pd.read_csv(path, dtype={"month": str}), log], ignore_index=True)
        log.to_csv(path, index=False)
        print(f"removed {log['removed'].sum():,} of {log['ticks'].sum():,} ticks "
              f"({100 * log['removed'].sum() / log['ticks'].sum():.3f}%)")


if __name__ == "__main__":
    main("duka" if "--feed" in sys.argv and sys.argv[sys.argv.index("--feed") + 1] == "duka" else "mt5")
