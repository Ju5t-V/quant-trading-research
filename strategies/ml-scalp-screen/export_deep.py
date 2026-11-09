"""Paginated deep export: XAUUSD M5/M15/M30, US500 M5 (MaxBars raised to 10M)."""
import MetaTrader5 as mt5
import pandas as pd
from pathlib import Path

OUT = Path(r"E:\Documents\Quant Trading\ML_Scalp\data")
OUT.mkdir(parents=True, exist_ok=True)
mt5.initialize()

PAGE = 90000
jobs = [("XAUUSD", mt5.TIMEFRAME_M5, "M5"), ("XAUUSD", mt5.TIMEFRAME_M15, "M15"),
        ("XAUUSD", mt5.TIMEFRAME_M30, "M30"), ("US500", mt5.TIMEFRAME_M5, "M5")]
for sym, tf, label in jobs:
    mt5.symbol_select(sym, True)
    pages, pos = [], 0
    while True:
        r = mt5.copy_rates_from_pos(sym, tf, pos, PAGE)
        if r is None or len(r) == 0:
            break
        pages.append(pd.DataFrame(r))
        if len(r) < PAGE:
            break
        pos += PAGE
    if not pages:
        print(sym, label, "FAILED")
        continue
    df = pd.concat(pages).drop_duplicates(subset="time").sort_values("time")
    df["time"] = pd.to_datetime(df["time"], unit="s")
    df.to_parquet(OUT / f"{sym}_{label}.parquet")
    print(sym, label, len(df), df["time"].iloc[0], "->", df["time"].iloc[-1])

mt5.shutdown()
print("DONE")
