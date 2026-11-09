"""Verify Smith's three gold BUY signals against real price data.
Malaysia time (UTC+8) - 5h = broker server time (UTC+3)."""
from datetime import datetime, timezone

import MetaTrader5 as mt5
import pandas as pd

if not mt5.initialize():
    raise SystemExit("attach failed")
sym = "XAUUSD"
mt5.symbol_select(sym, True)

# pull M5 across Jul 14-16 (server time)
r = mt5.copy_rates_range(sym, mt5.TIMEFRAME_M5,
                         datetime(2026, 7, 14, 10, 0, tzinfo=timezone.utc),
                         datetime(2026, 7, 16, 6, 0, tzinfo=timezone.utc))
df = pd.DataFrame(r)
df["time"] = pd.to_datetime(df["time"], unit="s")

# each signal: (label, server_entry_time, dir, entry, sl, [tps])
trades = [
    ("Jul14 22:08 MYT (17:08 srv)", "2026-07-14 17:08", 1, 4079, 4065, [4087, 4094, 4102]),
    ("Jul15 14:33 MYT (09:33 srv)", "2026-07-15 09:33", 1, 4026, 4011, [4034, 4041, 4047, 4053]),
    ("Jul15 20:22 MYT (15:22 srv)", "2026-07-15 15:22", 1, 4039, 4025, [4047, 4053, 4059]),
]

for label, tstr, d, entry, sl, tps in trades:
    t0 = pd.Timestamp(tstr)
    fwd = df[df["time"] >= t0]
    if fwd.empty:
        print(f"\n{label}: no data"); continue
    # was entry price actually near market at signal time?
    near = df[(df["time"] >= t0 - pd.Timedelta(minutes=10)) & (df["time"] <= t0 + pd.Timedelta(minutes=10))]
    mkt_lo, mkt_hi = near["low"].min(), near["high"].max()

    # walk forward: which came first, each TP or the SL?
    hit_sl = None
    tp_hits = []
    for _, b in fwd.iterrows():
        if hit_sl is None and b["low"] <= sl:
            hit_sl = b["time"]
        for tp in tps:
            if tp not in [h[0] for h in tp_hits] and b["high"] >= tp:
                tp_hits.append((tp, b["time"]))
        # stop scanning ~2 days out
        if (b["time"] - t0).total_seconds() > 2 * 86400:
            break

    print(f"\n=== {label} | BUY {entry}, SL {sl}, TPs {tps} ===")
    print(f"  market near signal time: {mkt_lo:.2f}-{mkt_hi:.2f}  (entry {entry} "
          f"{'inside' if mkt_lo <= entry <= mkt_hi else 'OUTSIDE'} range)")
    # order of events
    events = [(tp, tm, 'TP') for tp, tm in tp_hits]
    if hit_sl is not None:
        events.append((sl, hit_sl, 'SL'))
    events.sort(key=lambda x: x[1])
    for px, tm, kind in events:
        print(f"  {kind} {px} hit at {tm}")
    if not events:
        print("  neither TP nor SL hit in window")
    # verdict: did SL hit before any TP?
    first_tp = min([h[1] for h in tp_hits], default=None)
    if hit_sl and (first_tp is None or hit_sl < first_tp):
        print("  >>> RESULT: STOPPED OUT (loss) before any TP")
    elif tp_hits:
        print(f"  >>> RESULT: hit {len(tp_hits)} TP(s); SL {'later' if hit_sl else 'not hit'}")

mt5.shutdown()
