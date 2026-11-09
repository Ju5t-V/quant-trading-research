"""Export XAUUSD data from the running MT5 terminal (MetaQuotes-Demo) for the Nautilus study.

MT5 returns times on the SERVER clock, encoded as if they were UTC epoch values.
The MetaQuotes-Demo server runs EET/EEST (Europe/Athens DST rules): UTC+2 from the
last Sunday of October to the last Sunday of March, UTC+3 otherwise. This was
checked from daily-close times (2019-01, 2020-03 inside the US/EU DST mismatch,
2025-06, 2026-03 mismatch) and the live clock (server - UTC = 3.000h, 2026-09).

Every file keeps the raw server time (for server-day logic: yesterday's high/low)
and adds true UTC nanoseconds (for the Asia session and Nautilus timestamps).

Usage (Quant Trading venv, which has the MetaTrader5 package):
    python export_mt5.py ticks 2025-05 2026-09      # inclusive month range
    python export_mt5.py bars                         # D1 + M1 bars 2018-2026
Reading data does not touch the EAs running in the terminal.
"""
import sys
import time
from datetime import datetime, timedelta, timezone
from pathlib import Path

import MetaTrader5 as mt5
import numpy as np
import pandas as pd

SYM = "XAUUSD"
SERVER_TZ = "Europe/Athens"
ROOT = Path(__file__).parent
TICKS = ROOT / "data" / "ticks"
BARS = ROOT / "data" / "bars"
NAT_INT = np.iinfo(np.int64).min


def server_to_utc_ns(srv_ms: np.ndarray) -> np.ndarray:
    """Server wall-clock milliseconds -> true UTC nanoseconds (NaT -> int64 min)."""
    idx = pd.DatetimeIndex(pd.to_datetime(srv_ms, unit="ms"))
    loc = idx.tz_localize(SERVER_TZ, ambiguous="NaT", nonexistent="NaT")
    utc = loc.tz_convert("UTC").tz_localize(None)
    return utc.values.astype("datetime64[ns]").astype("int64")


def month_range(a: str, b: str):
    y, m = map(int, a.split("-"))
    y2, m2 = map(int, b.split("-"))
    while (y, m) <= (y2, m2):
        yield y, m
        y, m = (y + 1, 1) if m == 12 else (y, m + 1)


def export_month(y: int, m: int, overwrite: bool = False) -> None:
    path = TICKS / f"{SYM}_{y:04d}{m:02d}.parquet"
    if path.exists() and not overwrite:
        print(f"{y}-{m:02d}: exists, skipped")
        return
    start = datetime(y, m, 1, tzinfo=timezone.utc)
    end = datetime(y + 1, 1, 1, tzinfo=timezone.utc) if m == 12 else datetime(y, m + 1, 1, tzinfo=timezone.utc)

    parts, days, empty_weekdays = [], 0, []
    d = start
    while d < end:
        r = None
        for attempt in range(3):
            r = mt5.copy_ticks_range(SYM, d, d + timedelta(days=1), mt5.COPY_TICKS_INFO)
            if (r is not None and len(r) > 0) or d.weekday() >= 5:
                break
            time.sleep(1.0)  # give the terminal a moment to sync, then retry
        if r is not None and len(r) > 0:
            parts.append(pd.DataFrame({
                "srv_ms": r["time_msc"].astype("int64"),
                "bid": r["bid"].astype("float64"),
                "ask": r["ask"].astype("float64"),
            }))
            days += 1
        elif d.weekday() < 5:
            empty_weekdays.append(d.strftime("%m-%d"))
        d += timedelta(days=1)
        time.sleep(0.05)  # keep the live terminal responsive

    if not parts:
        print(f"{y}-{m:02d}: NO TICKS (server returned nothing)")
        return

    df = pd.concat(parts, ignore_index=True)
    n0 = len(df)
    df = df[(df["bid"] > 0) & (df["ask"] > 0) & (df["ask"] >= df["bid"])]
    df = df.sort_values("srv_ms", kind="stable")
    df = df.drop_duplicates(subset=["srv_ms", "bid", "ask"])
    df["utc_ns"] = server_to_utc_ns(df["srv_ms"].to_numpy())
    dst_gap = int((df["utc_ns"] == NAT_INT).sum())
    df = df[df["utc_ns"] != NAT_INT].reset_index(drop=True)
    df.to_parquet(path, compression="zstd", index=False)

    spread = (df["ask"] - df["bid"]) / 0.01
    print(f"{y}-{m:02d}: {len(df):>11,} ticks  {days:2d} days  spread med {spread.median():4.0f} "
          f"p95 {spread.quantile(0.95):4.0f}  dropped {n0 - len(df):,} (dst-gap {dst_gap})"
          + (f"  EMPTY weekdays: {','.join(empty_weekdays)}" if empty_weekdays else ""))


def export_bars() -> None:
    BARS.mkdir(parents=True, exist_ok=True)
    for name, tf, years in (("D1", mt5.TIMEFRAME_D1, [(2015, 2027)]),
                            ("M1", mt5.TIMEFRAME_M1, [(y, y + 1) for y in range(2018, 2027)])):
        frames = []
        for y0, y1 in years:
            r = mt5.copy_rates_range(SYM, tf, datetime(y0, 1, 1, tzinfo=timezone.utc),
                                     datetime(y1, 1, 1, tzinfo=timezone.utc))
            if r is None or len(r) == 0:
                print(f"{name} {y0}: no bars ({mt5.last_error()})")
                continue
            frames.append(pd.DataFrame(r))
        if not frames:
            continue
        df = pd.concat(frames, ignore_index=True).drop_duplicates("time").sort_values("time")
        df["srv_ms"] = df["time"].astype("int64") * 1000
        df["utc_ns"] = server_to_utc_ns(df["srv_ms"].to_numpy())
        df = df.drop(columns=["time"]).reset_index(drop=True)
        out = BARS / f"{SYM}_{name}.parquet"
        df.to_parquet(out, compression="zstd", index=False)
        first = pd.to_datetime(df["srv_ms"].iloc[0], unit="ms")
        last = pd.to_datetime(df["srv_ms"].iloc[-1], unit="ms")
        print(f"{name}: {len(df):,} bars  {first} -> {last} (server clock)")


def main() -> None:
    if len(sys.argv) < 2 or sys.argv[1] not in ("ticks", "bars"):
        raise SystemExit(__doc__)
    if not mt5.initialize():
        raise SystemExit(f"MT5 initialize failed: {mt5.last_error()}")
    try:
        if not mt5.symbol_select(SYM, True):
            raise SystemExit("symbol_select failed")
        if sys.argv[1] == "bars":
            export_bars()
        else:
            TICKS.mkdir(parents=True, exist_ok=True)
            overwrite = "--overwrite" in sys.argv
            for y, m in month_range(sys.argv[2], sys.argv[3]):
                export_month(y, m, overwrite)
    finally:
        mt5.shutdown()


if __name__ == "__main__":
    main()
