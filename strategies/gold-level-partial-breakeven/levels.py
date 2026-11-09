"""Daily arming schedule (levels, ATR, trend flag, arm/expire times) built from bars.

Server days follow the MetaQuotes-Demo clock (Europe/Athens DST rules). Levels
are bid-based, like MT5's own iHigh/iLow, and only use data that is complete
before the orders are armed:
  PDH_PDL : high/low of the previous server-day D1 bar; armed at a server clock
            time; unfilled orders expire at the next server midnight.
  ASIA    : high/low of M1 bars opening 00:00-07:59 UTC; armed 08:00 UTC;
            unfilled orders expire 20:00 UTC (D_AsiaBreakout's window).
ATR(14) is a simple average of true range over the 14 completed D1 bars before
the trading day (MT5's iATR), in points. sell_ok is true when yesterday's close
was below the SMA(50) of completed D1 closes (the sell-in-downtrend filter).
feed="mt5" reads data/bars (MetaQuotes); feed="duka" reads data/duka_bars.
"""
from datetime import datetime, time, timedelta, timezone
from pathlib import Path
from zoneinfo import ZoneInfo

import numpy as np
import pandas as pd

SERVER_TZ = ZoneInfo("Europe/Athens")
POINT = 0.01
ROOT = Path(__file__).parent
BARS_DIR = {"mt5": ROOT / "data" / "bars", "duka": ROOT / "data" / "duka_bars"}
MIN_ASIA_BARS = 240  # at least 4 of the 8 Asia hours must have traded


def _ns(dt: datetime) -> int:
    return int(dt.astimezone(timezone.utc).timestamp()) * 1_000_000_000


def load_d1(feed: str = "mt5") -> pd.DataFrame:
    d1 = pd.read_parquet(BARS_DIR[feed] / "XAUUSD_D1.parquet")
    d1["day"] = pd.to_datetime(d1["srv_ms"], unit="ms").dt.normalize()
    d1 = d1.sort_values("day").reset_index(drop=True)
    prev_close = d1["close"].shift(1)
    tr = np.maximum(d1["high"] - d1["low"],
                    np.maximum((d1["high"] - prev_close).abs(), (d1["low"] - prev_close).abs()))
    tr.iloc[0] = d1["high"].iloc[0] - d1["low"].iloc[0]
    atr = tr.rolling(14).mean()
    sma50 = d1["close"].rolling(50).mean()
    d1["pdh"] = d1["high"].shift(1)
    d1["pdl"] = d1["low"].shift(1)
    d1["atr_prev_pts"] = atr.shift(1) / POINT
    d1["sell_ok"] = (d1["close"].shift(1) < sma50.shift(1)).fillna(False)
    return d1


def asia_ranges(feed: str = "mt5") -> pd.DataFrame:
    m1 = pd.read_parquet(BARS_DIR[feed] / "XAUUSD_M1.parquet", columns=["utc_ns", "high", "low"])
    t = pd.to_datetime(m1["utc_ns"], unit="ns")
    mask = (t.dt.hour < 8).to_numpy()
    sub = m1[mask]
    key = t[mask].dt.normalize()
    g = sub.groupby(key.to_numpy())
    return pd.DataFrame({"asia_hi": g["high"].max(), "asia_lo": g["low"].min(), "asia_bars": g.size()})


def build_schedule(levels: str, arm_hour: int = 0, arm_minute: int = 5,
                   asia_arm_utc_hour: int = 8, asia_expire_utc_hour: int = 20,
                   start: str | None = None, end: str | None = None,
                   feed: str = "mt5") -> dict[str, dict]:
    """Return {server_date: {up, dn, atr_pts, sell_ok, arm_ns, expire_ns}} for every trading day."""
    d1 = load_d1(feed)
    asia = asia_ranges(feed) if levels == "ASIA" else None
    lo = pd.Timestamp(start) if start else None
    hi = pd.Timestamp(end) if end else None
    rows: dict[str, dict] = {}
    for r in d1.itertuples(index=False):
        day = r.day
        if (lo is not None and day < lo) or (hi is not None and day > hi):
            continue
        if not (np.isfinite(r.pdh) and np.isfinite(r.pdl)):
            continue
        atr_pts = float(r.atr_prev_pts) if np.isfinite(r.atr_prev_pts) else None
        date = day.date()
        if levels == "PDH_PDL":
            arm = datetime.combine(date, time(arm_hour, arm_minute), tzinfo=SERVER_TZ)
            expire = datetime.combine(date + timedelta(days=1), time(0, 0), tzinfo=SERVER_TZ)
            up, dn = float(r.pdh), float(r.pdl)
        elif levels == "ASIA":
            key = np.datetime64(day.to_datetime64(), "ns")
            if key not in asia.index:
                continue
            a = asia.loc[key]
            if a["asia_bars"] < MIN_ASIA_BARS:
                continue
            arm = datetime.combine(date, time(asia_arm_utc_hour), tzinfo=timezone.utc)
            expire = datetime.combine(date, time(asia_expire_utc_hour), tzinfo=timezone.utc)
            up, dn = float(a["asia_hi"]), float(a["asia_lo"])
        else:
            raise ValueError(f"unknown levels mode {levels}")
        if not up > dn:
            continue
        rows[day.strftime("%Y-%m-%d")] = dict(up=up, dn=dn, atr_pts=atr_pts, sell_ok=bool(r.sell_ok),
                                              arm_ns=_ns(arm), expire_ns=_ns(expire))
    return rows
