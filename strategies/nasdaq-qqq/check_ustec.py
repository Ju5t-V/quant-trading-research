"""Specs + ATR profile for the Nasdaq CFDs on MetaQuotes-Demo (read-only)."""
import time
from datetime import datetime, timezone

import MetaTrader5 as mt5
import pandas as pd

if not mt5.initialize():
    raise SystemExit("init failed")
acct = mt5.account_info()
print("attached to account:", acct.login, acct.server)

for sym in ["USTEC", "USTECH100M"]:
    mt5.symbol_select(sym, True)
    si = mt5.symbol_info(sym)
    print(f"\n{sym}: digits={si.digits} point={si.point} contract={si.trade_contract_size} "
          f"volmin={si.volume_min} volstep={si.volume_step} spread={si.spread}pts "
          f"stops_level={si.trade_stops_level} bid={si.bid}")
    r = None
    for _ in range(6):
        r = mt5.copy_rates_range(sym, mt5.TIMEFRAME_D1,
                                 datetime(2019, 1, 1, tzinfo=timezone.utc),
                                 datetime(2026, 7, 12, tzinfo=timezone.utc))
        if r is not None and len(r):
            break
        time.sleep(3)
    df = pd.DataFrame(r)
    df["time"] = pd.to_datetime(df["time"], unit="s")
    prev = df["close"].shift(1)
    tr = pd.concat([df["high"] - df["low"], (df["high"] - prev).abs(),
                    (df["low"] - prev).abs()], axis=1).max(axis=1)
    atr = tr.rolling(14).mean()
    print(f"  D1 {df['time'].iloc[0].date()} .. {df['time'].iloc[-1].date()} ({len(df)} bars)")
    print(f"  ATR14 now = {atr.iloc[-1]:.0f} index units = {atr.iloc[-1] / si.point:,.0f} points")
    print(f"  ATR14 mean over data = {atr.mean():.0f} | min {atr.min():.0f} | max {atr.max():.0f}")
    # $ value of 1 point for 1 lot
    print(f"  value of 1 point at 1 lot = ${si.trade_contract_size * si.point:.2f}")

mt5.shutdown()
