"""Check whether MetaQuotes-Demo carries QQQ (or a Nasdaq index) and its data depth."""
import sys
import time
from datetime import datetime, timezone

import MetaTrader5 as mt5

if not mt5.initialize():
    print("initialize() failed:", mt5.last_error())
    sys.exit(1)

hits = [s.name for s in mt5.symbols_get()
        if "QQQ" in s.name.upper() or "NAS" in s.name.upper()
        or "USTEC" in s.name.upper() or "NDX" in s.name.upper()]
print("Candidate symbols:", hits)

for sym in hits[:6]:
    if not mt5.symbol_select(sym, True):
        continue
    si = mt5.symbol_info(sym)
    # find oldest available daily bar
    rates = None
    for _ in range(6):
        rates = mt5.copy_rates_range(sym, mt5.TIMEFRAME_D1,
                                     datetime(2000, 1, 1, tzinfo=timezone.utc),
                                     datetime(2026, 7, 12, tzinfo=timezone.utc))
        if rates is not None and len(rates) > 0:
            break
        time.sleep(3)
    n = 0 if rates is None else len(rates)
    first = datetime.utcfromtimestamp(rates[0][0]).date() if n else "-"
    last = datetime.utcfromtimestamp(rates[-1][0]).date() if n else "-"
    print(f"{sym}: path={si.path} | digits={si.digits} | contract={si.trade_contract_size} "
          f"| D1 bars={n} ({first} .. {last})")

mt5.shutdown()
