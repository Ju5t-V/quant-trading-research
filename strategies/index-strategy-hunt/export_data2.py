"""Export H1/M5 via position-paginated copy_rates_from_pos (range calls fail on this feed)."""
import MetaTrader5 as mt5
import pandas as pd
from pathlib import Path

OUT = Path(r"E:\Documents\Quant Trading\Index_Hunt\data")
OUT.mkdir(parents=True, exist_ok=True)
mt5.initialize()

PAGE = 90000
for sym in ("US500", "DE40"):
    mt5.symbol_select(sym, True)
    for tf, label in ((mt5.TIMEFRAME_H1, "H1"), (mt5.TIMEFRAME_M5, "M5")):
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
