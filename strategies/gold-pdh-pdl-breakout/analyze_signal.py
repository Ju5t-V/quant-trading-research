"""Pull today's XAUUSD context to reverse-engineer the Smith Trade sell signal."""
from datetime import datetime, timezone, timedelta

import MetaTrader5 as mt5
import pandas as pd

if not mt5.initialize():
    raise SystemExit("attach failed")

sym = "XAUUSD"
mt5.symbol_select(sym, True)

# --- daily bars: previous-day high/low context ---
d1 = pd.DataFrame(mt5.copy_rates_from_pos(sym, mt5.TIMEFRAME_D1, 0, 8))
d1["time"] = pd.to_datetime(d1["time"], unit="s")
print("=== Recent daily bars (server time) ===")
print(d1[["time", "open", "high", "low", "close"]].to_string(index=False))

prev = d1.iloc[-2]  # yesterday
today = d1.iloc[-1]
print(f"\nYesterday: high {prev['high']:.2f}  low {prev['low']:.2f}  close {prev['close']:.2f}")
print(f"Today so far: open {today['open']:.2f}  high {today['high']:.2f}  low {today['low']:.2f}")

# --- M15 bars for today, to see structure around the 09:25-09:34 entries ---
m15 = pd.DataFrame(mt5.copy_rates_from_pos(sym, mt5.TIMEFRAME_M15, 0, 160))
m15["time"] = pd.to_datetime(m15["time"], unit="s")
today_date = m15["time"].iloc[-1].date()
tm = m15[m15["time"].dt.date == today_date]
print(f"\n=== Today's M15 bars (server time), {today_date} ===")
print(tm[["time", "open", "high", "low", "close"]].to_string(index=False))

# --- context: session high before the signal, round numbers ---
sig_time = pd.Timestamp(f"{today_date} 09:25:00")
before = tm[tm["time"] <= sig_time]
if len(before):
    print(f"\nBefore the 09:25 signal today: high {before['high'].max():.2f}  low {before['low'].min():.2f}")
print("Signal zone: entries 4001.6-4006.5 | SL 4016 | TPs 3994/3989/3984/3978")
print(f"Round numbers nearby: 4000 (psych), yesterday high {prev['high']:.2f}")

mt5.shutdown()
