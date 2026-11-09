"""Pull native H2 + M30 bars (server caps ~100k bars/TF; H2 needs only ~46k for 10.5y)."""
import sys, time
from datetime import datetime, timezone
from pathlib import Path
import MetaTrader5 as mt5
import pandas as pd

PAIRS = ["AUDCAD","AUDCHF","AUDJPY","EURAUD","EURGBP","EURJPY","EURUSD","GBPAUD",
         "GBPCAD","GBPCHF","GBPNZD","GBPUSD","NZDCAD","NZDUSD","USDCAD","USDCHF"]
TFS = {"H2": mt5.TIMEFRAME_H2, "M30": mt5.TIMEFRAME_M30}
OUT = Path(r"E:\Documents\Quant Trading\AOI_MeanReversion\data")

if not mt5.initialize():
    print("FATAL:", mt5.last_error()); sys.exit(1)

rows = []
for sym in PAIRS:
    mt5.symbol_select(sym, True)
    for tf_name, tf in TFS.items():
        frames = []
        for year in range(2014, 2027):
            a = datetime(year, 1, 1, tzinfo=timezone.utc)
            b = datetime(year + 1, 1, 1, tzinfo=timezone.utc)
            r = mt5.copy_rates_range(sym, tf, a, b)
            if r is not None and len(r):
                frames.append(pd.DataFrame(r))
            time.sleep(0.03)
        if not frames:
            print(f"{sym} {tf_name}: NO DATA"); continue
        df = pd.concat(frames).drop_duplicates(subset="time").sort_values("time").reset_index(drop=True)
        df["time"] = pd.to_datetime(df["time"], unit="s")
        df = df[["time","open","high","low","close","tick_volume","spread"]]
        df.to_parquet(OUT / f"{sym}_{tf_name}.parquet", index=False)
        print(f"{sym} {tf_name}: {len(df):>6} bars  {df['time'].iloc[0]:%Y-%m-%d} .. {df['time'].iloc[-1]:%Y-%m-%d}", flush=True)
        rows.append((sym, tf_name, len(df), str(df['time'].iloc[0].date())))
mt5.shutdown()
print("done")
