"""Download XAUUSD ticks from Dukascopy's public datafeed for the holdout test.

    python export_dukascopy.py download     # hourly .bi5 files -> data/duka_raw (resumable)
    python export_dukascopy.py convert      # -> data/duka_ticks/XAUUSD_YYYYMM.parquet
    python export_dukascopy.py bars         # data/duka_ticks_clean -> data/duka_bars (D1 + M1)

Source: https://datafeed.dukascopy.com/datafeed/XAUUSD/YYYY/MM-1/DD/HHh_ticks.bi5
Each file is LZMA-compressed 20-byte big-endian records: ms offset inside the UTC
hour, ask, bid (price x 1000), ask volume, bid volume. Checked 2026-09-15: the
2021-06-15 13h file matches MetaQuotes M1 bars within ~$0.10 (spread ~$0.33).

Every worker thread keeps one HTTPS connection open: from Malaysia a new TLS
handshake per file made the first attempt crawl at ~0.8 files/s.

Output ticks use the same columns as the MT5 export (srv_ms, bid, ask, utc_ns),
with the server clock on Europe/Athens rules, so levels.py and run_matrix.py treat
both feeds the same way. Bars are built from CLEANED ticks (clean_ticks.py --feed duka).
"""
import http.client
import lzma
import sys
import threading
import time
from concurrent.futures import ThreadPoolExecutor, as_completed
from datetime import datetime, timedelta, timezone
from pathlib import Path

import numpy as np
import pandas as pd

ROOT = Path(__file__).parent
RAW = ROOT / "data" / "duka_raw"
TICKS = ROOT / "data" / "duka_ticks"
CLEAN = ROOT / "data" / "duka_ticks_clean"
BARS = ROOT / "data" / "duka_bars"
HOST = "datafeed.dukascopy.com"
PATH = "/datafeed/XAUUSD/{y:04d}/{m:02d}/{d:02d}/{h:02d}h_ticks.bi5"
START = datetime(2020, 10, 1, tzinfo=timezone.utc)   # Oct-Dec 2020 = ATR / SMA warm-up
END = datetime(2025, 5, 1, tzinfo=timezone.utc)      # exclusive
SERVER_TZ = "Europe/Athens"
WORKERS = 16
REC = np.dtype([("ms", ">u4"), ("ask", ">u4"), ("bid", ">u4"), ("av", ">f4"), ("bv", ">f4")])
_local = threading.local()


def market_hours():
    """UTC hours when gold can trade: skip Saturday, Sunday before 20h, Friday from 22h."""
    t = START
    while t < END:
        wd = t.weekday()
        closed = wd == 5 or (wd == 6 and t.hour < 20) or (wd == 4 and t.hour >= 22)
        if not closed:
            yield t
        t += timedelta(hours=1)


def raw_path(t: datetime) -> Path:
    return RAW / f"{t:%Y}" / f"{t:%m}" / f"{t:%d}" / f"{t:%H}h_ticks.bi5"


def _conn() -> http.client.HTTPSConnection:
    c = getattr(_local, "conn", None)
    if c is None:
        c = http.client.HTTPSConnection(HOST, timeout=45)
        _local.conn = c
    return c


def _drop_conn() -> None:
    c = getattr(_local, "conn", None)
    if c is not None:
        try:
            c.close()
        except Exception:
            pass
    _local.conn = None


def _save(p: Path, data: bytes) -> None:
    p.parent.mkdir(parents=True, exist_ok=True)
    tmp = p.with_suffix(".part")
    tmp.write_bytes(data)
    tmp.replace(p)


def fetch(t: datetime):
    p = raw_path(t)
    if p.exists():
        return "skip", 0
    path = PATH.format(y=t.year, m=t.month - 1, d=t.day, h=t.hour)
    err = None
    for attempt in range(6):
        try:
            c = _conn()
            c.request("GET", path, headers={"User-Agent": "Mozilla/5.0", "Connection": "keep-alive"})
            r = c.getresponse()
            data = r.read()
            if r.status == 404:
                _save(p, b"")
                return "404", 0
            if r.status != 200:
                raise IOError(f"HTTP {r.status}")
            _save(p, data)
            return "ok", len(data)
        except Exception as e:  # timeouts, resets, server closing the kept-alive connection
            err = e
            _drop_conn()
            time.sleep(min(30, 2 ** attempt))
    return f"fail:{type(err).__name__}", 0


def download() -> None:
    hours = list(market_hours())
    todo = [t for t in hours if not raw_path(t).exists()]
    print(f"{len(hours):,} market hours, {len(todo):,} still to download "
          f"({time.strftime('%H:%M:%S')}, {WORKERS} workers)", flush=True)
    done = ok_bytes = fails = 0
    failed = []
    t0 = time.time()
    with ThreadPoolExecutor(max_workers=WORKERS) as pool:
        futures = {pool.submit(fetch, t): t for t in todo}
        for fut in as_completed(futures):
            status, n = fut.result()
            done += 1
            ok_bytes += n
            if status.startswith("fail"):
                fails += 1
                failed.append(futures[fut])
            if done % 500 == 0 or done == len(todo):
                rate = done / max(1e-9, time.time() - t0)
                eta = (len(todo) - done) / max(rate, 1e-9) / 60
                print(f"  {done:,}/{len(todo):,} hours  {ok_bytes / 1e6:,.0f} MB  fails {fails}  "
                      f"{rate:.1f}/s  eta {eta:.0f} min  ({time.strftime('%H:%M:%S')})", flush=True)
    log = ROOT / "results" / "duka_failed_hours.txt"
    log.write_text("\n".join(f"{t:%Y-%m-%d %H}h" for t in sorted(failed)))
    print(f"download finished: {fails} failed hours (listed in {log.name}; rerun to retry)", flush=True)


def to_server_ms(utc_ns: np.ndarray) -> np.ndarray:
    idx = pd.DatetimeIndex(pd.to_datetime(utc_ns, unit="ns")).tz_localize("UTC").tz_convert(SERVER_TZ)
    return idx.tz_localize(None).values.astype("datetime64[ms]").astype(np.int64)


def convert() -> None:
    TICKS.mkdir(parents=True, exist_ok=True)
    months: dict = {}
    for t in market_hours():
        months.setdefault((t.year, t.month), []).append(t)
    for (y, m), hours in sorted(months.items()):
        out = TICKS / f"XAUUSD_{y:04d}{m:02d}.parquet"
        if out.exists() and "--overwrite" not in sys.argv:
            print(f"{y}-{m:02d}: exists, skipped", flush=True)
            continue
        missing = [t for t in hours if not raw_path(t).exists()]
        if missing:
            print(f"{y}-{m:02d}: {len(missing)} hours not downloaded yet - skipped", flush=True)
            continue
        parts, empty = [], 0
        for t in hours:
            b = raw_path(t).read_bytes()
            data = lzma.decompress(b) if b else b""
            n = len(data) // 20
            if n == 0:
                empty += 1
                continue
            r = np.frombuffer(data[: n * 20], dtype=REC)
            base = int(t.timestamp()) * 1_000_000_000
            parts.append(pd.DataFrame({"utc_ns": base + r["ms"].astype(np.int64) * 1_000_000,
                                       "bid": r["bid"].astype(np.float64) / 1000.0,
                                       "ask": r["ask"].astype(np.float64) / 1000.0}))
        if not parts:
            print(f"{y}-{m:02d}: no ticks", flush=True)
            continue
        df = pd.concat(parts, ignore_index=True)
        n0 = len(df)
        df = df[(df["bid"] > 0) & (df["ask"] >= df["bid"])]
        df = df.sort_values("utc_ns", kind="stable").drop_duplicates()
        df["srv_ms"] = to_server_ms(df["utc_ns"].to_numpy())
        df = df[["srv_ms", "bid", "ask", "utc_ns"]].reset_index(drop=True)
        df.to_parquet(out, compression="zstd", index=False)
        sp = (df["ask"] - df["bid"]) / 0.01
        print(f"{y}-{m:02d}: {len(df):>11,} ticks  empty hours {empty:3d}  spread med {sp.median():4.0f} "
              f"p95 {sp.quantile(0.95):4.0f}  dropped {n0 - len(df):,}", flush=True)


def bars() -> None:
    BARS.mkdir(parents=True, exist_ok=True)
    frames = {"D1": [], "M1": []}
    for f in sorted(CLEAN.glob("XAUUSD_*.parquet")):
        t = pd.read_parquet(f)
        ms = t["srv_ms"].to_numpy()
        for name, size in (("D1", 86_400_000), ("M1", 60_000)):
            g = t.groupby(ms // size * size)
            b = pd.DataFrame({"open": g["bid"].first(), "high": g["bid"].max(), "low": g["bid"].min(),
                              "close": g["bid"].last(), "tick_volume": g.size(),
                              "spread": ((g["ask"].median() - g["bid"].median()) / 0.01).round()})
            b.index.name = "srv_ms"
            frames[name].append(b.reset_index())
        print(f"  bars from {f.name}", flush=True)
    for name, parts in frames.items():
        df = pd.concat(parts, ignore_index=True)
        df = df.groupby("srv_ms", sort=True).agg(open=("open", "first"), high=("high", "max"),
                                                 low=("low", "min"), close=("close", "last"),
                                                 tick_volume=("tick_volume", "sum"),
                                                 spread=("spread", "median")).reset_index()
        loc = pd.DatetimeIndex(pd.to_datetime(df["srv_ms"], unit="ms")).tz_localize(
            SERVER_TZ, ambiguous="NaT", nonexistent="NaT")
        df["utc_ns"] = loc.tz_convert("UTC").tz_localize(None).values.astype("datetime64[ns]").astype(np.int64)
        df.to_parquet(BARS / f"XAUUSD_{name}.parquet", compression="zstd", index=False)
        print(f"{name}: {len(df):,} bars {pd.to_datetime(df['srv_ms'].iloc[0], unit='ms')} -> "
              f"{pd.to_datetime(df['srv_ms'].iloc[-1], unit='ms')} (server clock)", flush=True)


if __name__ == "__main__":
    cmd = sys.argv[1] if len(sys.argv) > 1 else ""
    {"download": download, "convert": convert, "bars": bars}.get(cmd, lambda: print(__doc__))()
