"""Export XAGUSD/EURJPY bars and screen prev-day-breakout -> EOD drift vs XAUUSD.

Proxy stat (bar-exact, no trail): first H1 bar of the day whose OPEN exceeds the
previous day's high (long) -> hold to day close. Gross + net of current spread.
Gold is the calibration benchmark (its EA edge is proven); a candidate pair whose
drift stats match or beat gold's is worth real-tick EA runs.
"""
import MetaTrader5 as mt5
import pandas as pd
import numpy as np
from pathlib import Path

OUT = Path(__file__).parent / "data"
OUT.mkdir(parents=True, exist_ok=True)
SPLIT = pd.Timestamp("2021-01-01")

mt5.initialize()

SYMS = ["XAGUSD", "EURJPY", "XAUUSD"]
SPREADS = {}
for sym in SYMS:
    mt5.symbol_select(sym, True)
    si = mt5.symbol_info(sym)
    SPREADS[sym] = si.spread * si.point
    for tf, name in [(mt5.TIMEFRAME_H1, "H1"), (mt5.TIMEFRAME_D1, "D1")]:
        f = OUT / f"{sym}_{name}.parquet"
        if f.exists():
            continue
        rates = None
        for attempt in range(10):
            rates = mt5.copy_rates_from_pos(sym, tf, 0, 99000)
            if rates is not None and len(rates) > 1000:
                break
            import time
            time.sleep(6)
        if rates is None:
            print(sym, name, "FAIL", mt5.last_error())
            continue
        df = pd.DataFrame(rates)
        df["time"] = pd.to_datetime(df["time"], unit="s")
        df.to_parquet(f)
        print(sym, name, len(df), df["time"].iloc[0], "->", df["time"].iloc[-1])
mt5.shutdown()


def pf(x, cost):
    p = x - cost
    w, l = p[p > 0].sum(), -p[p <= 0].sum()
    return w / l if l > 0 else np.inf


print(f"\nspreads: { {k: round(v,5) for k,v in SPREADS.items()} }")
print(f"{'sym':7s} era  {'n':>5s} {'meanEOD':>9s} {'gPF':>6s} {'netPF':>6s} {'mean/spread':>11s}")
for sym in SYMS:
    h1 = pd.read_parquet(OUT / f"{sym}_H1.parquet")
    d1 = pd.read_parquet(OUT / f"{sym}_D1.parquet")
    d1["date"] = d1["time"].dt.date
    d1["pdh"] = d1["high"].shift(1)
    d1["dclose"] = d1["close"]
    h1["date"] = h1["time"].dt.date
    h1["hour"] = h1["time"].dt.hour
    h1 = h1.merge(d1[["date", "pdh", "dclose"]], on="date", how="left")
    h1 = h1[h1["hour"] >= 6]                      # match EA entry window
    h1["above"] = h1["open"] > h1["pdh"]
    first = h1[h1["above"] & ~h1.groupby("date")["above"].shift(1, fill_value=False)]
    first = first.drop_duplicates("date")         # first breakout bar of the day
    first = first.copy()
    first["eod_ret"] = first["dclose"] - first["open"]
    cost = SPREADS[sym]
    for era, mask in [("train", first["time"] < SPLIT), ("test", first["time"] >= SPLIT)]:
        x = first.loc[mask, "eod_ret"]
        if len(x) < 30:
            continue
        print(f"{sym:7s} {era:5s} {len(x):5d} {x.mean():+9.4f} {pf(x,0):6.3f} "
              f"{pf(x,cost):6.3f} {x.mean()/cost:+11.2f}")
