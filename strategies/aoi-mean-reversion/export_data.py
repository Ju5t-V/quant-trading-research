"""Export MT5 history for the AOI mean-reversion project.

Attaches to the RUNNING terminal (does not close/restart it).
Pulls M15, H1, H4, D1, W1 for the 16 pairs, 2014-01-01 .. now,
in yearly chunks (robust against copy_rates_range limits),
saves parquet per pair/TF + a coverage report.
"""
import sys, time
from datetime import datetime, timezone
from pathlib import Path

import MetaTrader5 as mt5
import pandas as pd

PAIRS = ["AUDCAD","AUDCHF","AUDJPY","EURAUD","EURGBP","EURJPY","EURUSD","GBPAUD",
         "GBPCAD","GBPCHF","GBPNZD","GBPUSD","NZDCAD","NZDUSD","USDCAD","USDCHF"]
TFS = {"M15": mt5.TIMEFRAME_M15, "H1": mt5.TIMEFRAME_H1, "H4": mt5.TIMEFRAME_H4,
       "D1": mt5.TIMEFRAME_D1, "W1": mt5.TIMEFRAME_W1}
START = datetime(2014, 1, 1, tzinfo=timezone.utc)
OUT = Path(r"E:\Documents\Quant Trading\AOI_MeanReversion\data")
OUT.mkdir(parents=True, exist_ok=True)

if not mt5.initialize():
    print("FATAL: mt5.initialize() failed:", mt5.last_error()); sys.exit(1)

info = mt5.terminal_info()
acct = mt5.account_info()
print(f"attached: {info.name} | build {mt5.version()[1]} | account {acct.login} ({acct.server})")

report = []
for sym in PAIRS:
    si = mt5.symbol_info(sym)
    if si is None or not si.visible:
        if not mt5.symbol_select(sym, True):
            print(f"{sym}: NOT AVAILABLE on this server"); report.append((sym, "MISSING", "", 0)); continue
        time.sleep(0.5)
    for tf_name, tf in TFS.items():
        frames = []
        for year in range(2014, 2027):
            a = datetime(year, 1, 1, tzinfo=timezone.utc)
            b = datetime(year + 1, 1, 1, tzinfo=timezone.utc)
            rates = mt5.copy_rates_range(sym, tf, a, b)
            if rates is not None and len(rates):
                frames.append(pd.DataFrame(rates))
            time.sleep(0.05)
        if not frames:
            print(f"{sym} {tf_name}: NO DATA"); report.append((sym, tf_name, "", 0)); continue
        df = pd.concat(frames).drop_duplicates(subset="time").sort_values("time").reset_index(drop=True)
        df["time"] = pd.to_datetime(df["time"], unit="s")
        df = df[["time","open","high","low","close","tick_volume","spread"]]
        df.to_parquet(OUT / f"{sym}_{tf_name}.parquet", index=False)
        first, last = df["time"].iloc[0], df["time"].iloc[-1]
        report.append((sym, tf_name, f"{first:%Y-%m-%d} .. {last:%Y-%m-%d}", len(df)))
        print(f"{sym} {tf_name}: {len(df):>7} bars  {first:%Y-%m-%d} .. {last:%Y-%m-%d}")

mt5.shutdown()
rep = pd.DataFrame(report, columns=["symbol","tf","range","bars"])
rep.to_csv(OUT / "coverage.csv", index=False)
print("\nDone. Coverage written to coverage.csv")
