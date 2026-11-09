"""Re-grade Smith's 16 signals WITH active management:
after TP1 -> stop to breakeven; after TP2 -> stop to TP1; after TP3 -> stop to TP2.
(¼ position scaled out at each TP; runner rides the trailed stop.)"""
from datetime import datetime, timezone

import MetaTrader5 as mt5
import pandas as pd

if not mt5.initialize():
    raise SystemExit("attach failed")
sym = "XAUUSD"
mt5.symbol_select(sym, True)
r = mt5.copy_rates_range(sym, mt5.TIMEFRAME_M5,
                         datetime(2026, 6, 24, 6, 0, tzinfo=timezone.utc),
                         datetime(2026, 7, 3, 0, 0, tzinfo=timezone.utc))
df = pd.DataFrame(r); df["time"] = pd.to_datetime(df["time"], unit="s")

SPREAD = 0.30  # ~ realistic gold cost drag per round trip (price units)

T = [
    ("06-24 16:18", +1, 3973, 3959, [3982, 3991, 4008, None]),
    ("06-26 12:26", -1, 4049, 4063, [4040, 4033, 4025, 4019]),
    ("06-26 17:21", -1, 4091, 4105, [4083, 4077, 4073, 4068]),
    ("06-26 19:37", +1, 4087, 4073, [4095, 4102, 4106, 4111]),
    ("06-26 21:08", +1, 4076, 4062, [4084, 4091, 4099, 4106]),
    ("06-29 10:52", +1, 4066, 4052, [4074, 4081, 4091, 4099]),
    ("06-29 13:05", +1, 4029, 4016, [4036, 4044, 4052, 4059]),
    ("06-29 13:44", +1, 4035, 4021, [4042, 4049, 4056, 4063]),
    ("06-29 17:25", +1, 4021, 4015, [4029, 4037, 4045, None]),
    ("06-29 18:02", +1, 4025, 4011, [4033, 4041, 4049, None]),
    ("06-30 08:43", +1, 3982, 3968, [3991, 4001, 4009, None]),
    ("06-30 09:45", +1, 4027, 4011, [4034, 4041, 4048, None]),
    ("06-30 10:38", +1, 4030, 4016, [4038, 4045, 4053, None]),
    ("06-30 13:46", +1, 4029, 4016, [4038, 4045, 4053, None]),
    ("06-30 16:17", +1, 4026, 4011, [4035, 4043, 4051, None]),
    ("06-30 18:20", +1, 4026, 4011, [4035, 4043, 4051, None]),
]

rows = []
for tstr, d, entry, sl, tps in T:
    t0 = pd.Timestamp("2026-" + tstr)
    fwd = df[df["time"] >= t0]
    if fwd.empty:
        continue
    risk = abs(entry - sl)
    banked = [None] * 4
    eff_stop = sl
    exit_stop_level = None
    for _, b in fwd.iterrows():
        hi, lo, cl, op = b["high"], b["low"], b["close"], b["open"]
        fav = (cl >= op and d > 0) or (cl < op and d < 0)

        def do_tps():
            raised = eff_stop
            for i, tp in enumerate(tps):
                if tp is not None and banked[i] is None and ((d > 0 and hi >= tp) or (d < 0 and lo <= tp)):
                    banked[i] = d * (tp - entry) / risk
                    # trail: after TPi, stop to (entry if i==0 else tp[i-1])
                    lvl = entry if i == 0 else tps[i - 1]
                    raised = max(raised, lvl) if d > 0 else min(raised, lvl)
            return raised

        def stop_hit(level):
            return (d > 0 and lo <= level) or (d < 0 and hi >= level)

        if fav:
            eff_stop = do_tps()
            if stop_hit(eff_stop):
                exit_stop_level = eff_stop; break
        else:
            if stop_hit(eff_stop):
                exit_stop_level = eff_stop; break
            eff_stop = do_tps()
        if (b["time"] - t0).total_seconds() > 3 * 86400:
            break

    last = fwd["close"].iloc[min(len(fwd) - 1, 864)]
    qR = []
    for i, tp in enumerate(tps):
        if banked[i] is not None:
            qR.append(banked[i])
        elif exit_stop_level is not None:
            qR.append(d * (exit_stop_level - entry) / risk)
        else:
            qR.append(d * (last - entry) / risk)
    netR = sum(qR) / 4.0 - SPREAD / risk   # subtract cost drag
    n_tp = sum(1 for x in banked if x is not None)
    rows.append(dict(t=tstr, dir="B" if d > 0 else "S", tps_hit=n_tp,
                     netR=round(netR, 2)))

res = pd.DataFrame(rows)
print(res.to_string(index=False))
print(f"\n--- MANAGED (breakeven after TP1, trail after) + costs ---")
print(f"Trades: {len(res)}")
print(f"Net-positive trades: {(res['netR']>0).sum()}/{len(res)} ({100*(res['netR']>0).mean():.0f}%)")
print(f"Avg net R per trade: {res['netR'].mean():.2f} R")
print(f"Total R over the week: {res['netR'].sum():.2f} R")
print(f"(For comparison, SL-left-as-posted was -0.28 R/trade, -4.45 R total)")
mt5.shutdown()
