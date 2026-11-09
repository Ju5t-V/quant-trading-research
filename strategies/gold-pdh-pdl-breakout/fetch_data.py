"""Pull XAUUSD M1 bars from the local MetaTrader 5 terminal and save to CSV."""
import sys
from datetime import datetime, timezone

import MetaTrader5 as mt5
import pandas as pd

if not mt5.initialize():
    print("initialize() failed:", mt5.last_error())
    sys.exit(1)

info = mt5.terminal_info()
acct = mt5.account_info()
print("Terminal:", info.name, "| Broker company:", info.company)
if acct is not None:
    print("Account:", acct.login, "| Server:", acct.server, "| Currency:", acct.currency)

# find the gold symbol name this broker uses
candidates = [s.name for s in mt5.symbols_get() if "XAU" in s.name.upper() or "GOLD" in s.name.upper()]
print("Gold-like symbols:", candidates)

symbol = None
for c in ["XAUUSD", "XAUUSD.", "XAUUSDm", "XAUUSD.a", "GOLD", "GOLD."]:
    if c in candidates:
        symbol = c
        break
if symbol is None and candidates:
    symbol = candidates[0]
if symbol is None:
    print("No gold symbol found")
    mt5.shutdown()
    sys.exit(1)

mt5.symbol_select(symbol, True)
si = mt5.symbol_info(symbol)
print(f"Using symbol: {symbol} | digits={si.digits} | point={si.point} | "
      f"spread={si.spread} pts | contract size={si.trade_contract_size} | "
      f"stops level={si.trade_stops_level}")

utc_from = datetime(2025, 12, 25, tzinfo=timezone.utc)   # a few days early so we have Dec 31 for Jan 1 prev-day levels
utc_to = datetime(2026, 7, 6, tzinfo=timezone.utc)
rates = mt5.copy_rates_range(symbol, mt5.TIMEFRAME_M1, utc_from, utc_to)
mt5.shutdown()

if rates is None or len(rates) == 0:
    print("No M1 data returned:", mt5.last_error())
    sys.exit(1)

df = pd.DataFrame(rates)
df["time"] = pd.to_datetime(df["time"], unit="s")  # broker server time
print(f"Bars: {len(df)} | from {df['time'].iloc[0]} to {df['time'].iloc[-1]}")
print(f"Median spread: {df['spread'].median()} pts | Last close: {df['close'].iloc[-1]}")
out = r"E:\Documents\Quant Trading\MT5\xauusd_m1.csv"
df.to_csv(out, index=False)
print("Saved:", out)
