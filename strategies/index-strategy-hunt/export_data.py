"""Export US500/DE40 bars (D1, H1, M5 chunked) from MT5 to parquet."""
import MetaTrader5 as mt5
import pandas as pd
from datetime import datetime
from pathlib import Path

OUT = Path(r"E:\Documents\Quant Trading\Index_Hunt\data")
OUT.mkdir(parents=True, exist_ok=True)

mt5.initialize()

def fetch_range(sym, tf, t0, t1):
    r = mt5.copy_rates_range(sym, tf, t0, t1)
    if r is None or len(r) == 0:
        return None
    df = pd.DataFrame(r)
    df["time"] = pd.to_datetime(df["time"], unit="s")
    return df

for sym in ("US500", "DE40"):
    mt5.symbol_select(sym, True)
    for tf, label in ((mt5.TIMEFRAME_D1, "D1"), (mt5.TIMEFRAME_H1, "H1")):
        df = fetch_range(sym, tf, datetime(2012, 1, 1), datetime(2026, 7, 19))
        if df is not None:
            df.to_parquet(OUT / f"{sym}_{label}.parquet")
            print(sym, label, len(df), df['time'].iloc[0], '->', df['time'].iloc[-1])
        else:
            print(sym, label, "FAILED")
    # M5 per-year chunks (server may cap large range requests)
    chunks = []
    for y in range(2012, 2027):
        c = fetch_range(sym, mt5.TIMEFRAME_M5, datetime(y, 1, 1), datetime(y + 1, 1, 1))
        if c is not None:
            chunks.append(c)
            print(sym, "M5", y, len(c))
        else:
            print(sym, "M5", y, "none")
    if chunks:
        m5 = pd.concat(chunks).drop_duplicates(subset="time").sort_values("time")
        m5.to_parquet(OUT / f"{sym}_M5.parquet")
        print(sym, "M5 total", len(m5), m5['time'].iloc[0], '->', m5['time'].iloc[-1])

mt5.shutdown()
print("DONE")
