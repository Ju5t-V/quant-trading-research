"""Export XAUUSD bar data from MT5 for the one-candle-hold study."""
import MetaTrader5 as mt5
import pandas as pd
from datetime import datetime, timezone
from pathlib import Path

OUT = Path(__file__).parent / "data"
OUT.mkdir(exist_ok=True)

if not mt5.initialize():
    raise SystemExit(f"initialize failed: {mt5.last_error()}")

info = mt5.terminal_info()
print("terminal:", info.name, "| connected:", info.connected)
acct = mt5.account_info()
print("account:", acct.login, acct.server)

sym = "XAUUSD"
if not mt5.symbol_select(sym, True):
    raise SystemExit("symbol_select failed")
si = mt5.symbol_info(sym)
print(f"point={si.point} digits={si.digits} spread={si.spread} "
      f"contract={si.trade_contract_size}")

TFS = {
    "M15": mt5.TIMEFRAME_M15,
    "M30": mt5.TIMEFRAME_M30,
    "H1": mt5.TIMEFRAME_H1,
    "H2": mt5.TIMEFRAME_H2,
    "H4": mt5.TIMEFRAME_H4,
    "D1": mt5.TIMEFRAME_D1,
}
utc_from = datetime(2010, 1, 1, tzinfo=timezone.utc)
utc_to = datetime(2026, 7, 18, tzinfo=timezone.utc)

import time as _time

def fetch(tf):
    for attempt in range(6):
        rates = mt5.copy_rates_range(sym, tf, utc_from, utc_to)
        if rates is not None and len(rates) > 100:
            return rates
        rates = mt5.copy_rates_from_pos(sym, tf, 0, 200000)
        if rates is not None and len(rates) > 100:
            return rates
        _time.sleep(5)
    return None

for name, tf in TFS.items():
    rates = fetch(tf)
    if rates is None:
        print(f"{name}: NO DATA ({mt5.last_error()})")
        continue
    df = pd.DataFrame(rates)
    df["time"] = pd.to_datetime(df["time"], unit="s")
    df.to_parquet(OUT / f"XAUUSD_{name}.parquet")
    print(f"{name}: {len(df)} bars  {df['time'].iloc[0]} -> {df['time'].iloc[-1]}")

mt5.shutdown()
print("done")
