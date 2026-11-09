"""Grade Smith's 16 gold signals (Jun 24-30) against real price.
Malaysia time (UTC+8) - 5h = server (UTC+3). Times below already converted to server."""
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
df = pd.DataFrame(r)
df["time"] = pd.to_datetime(df["time"], unit="s")
print(f"data: {df['time'].iloc[0]} .. {df['time'].iloc[-1]}  ({len(df)} M5 bars)\n")

# (server_time, dir(+1 buy/-1 sell), entry, sl, [tp1..tp4 or None for 'open'])
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
        rows.append(dict(t=tstr, note="no data")); continue
    near = df[(df["time"] >= t0 - pd.Timedelta(minutes=10)) & (df["time"] <= t0 + pd.Timedelta(minutes=10))]
    entry_ok = (not near.empty) and near["low"].min() - 1 <= entry <= near["high"].max() + 1
    risk = abs(entry - sl)

    banked = [None, None, None, None]     # R per quarter when a target is hit
    stopped_at = None
    for _, b in fwd.iterrows():
        up = b["close"] >= b["open"]
        hi, lo = b["high"], b["low"]
        def tp_hit(tp):
            return (d > 0 and hi >= tp) or (d < 0 and lo <= tp)
        def sl_hit():
            return (d > 0 and lo <= sl) or (d < 0 and hi >= sl)
        # order within bar: favourable-first on favourable bars, SL-first otherwise
        fav = (up and d > 0) or ((not up) and d < 0)
        seq = ["tp", "sl"] if fav else ["sl", "tp"]
        for step in seq:
            if step == "tp":
                for i, tp in enumerate(tps):
                    if tp is not None and banked[i] is None and tp_hit(tp):
                        banked[i] = d * (tp - entry) / risk
            else:
                if sl_hit() and stopped_at is None:
                    stopped_at = b["time"]
        if stopped_at is not None:
            break
        if (b["time"] - t0).total_seconds() > 3 * 86400:
            break

    last = fwd["close"].iloc[min(len(fwd) - 1, 800)] if len(fwd) else entry
    qR = []
    for i, tp in enumerate(tps):
        if banked[i] is not None:
            qR.append(banked[i])
        elif stopped_at is not None:
            qR.append(-1.0)
        else:
            qR.append(d * (last - entry) / risk)   # open at window end
    netR = sum(qR) / 4.0
    n_tp = sum(1 for x in banked if x is not None)
    full_loss = (n_tp == 0 and stopped_at is not None)
    rows.append(dict(t=tstr, dir="B" if d > 0 else "S", entry=entry,
                     entry_ok="ok" if entry_ok else "OFF",
                     tp1=("Y" if banked[0] is not None else "-"),
                     tps_hit=n_tp, stopped=("Y" if stopped_at else "-"),
                     netR=round(netR, 2), full_loss=full_loss))

res = pd.DataFrame(rows)
print(res.to_string(index=False))

done = res[res["netR"].notna()]
print(f"\n--- SUMMARY ({len(done)} trades) ---")
print(f"TP1 hit before SL: {(done['tp1']=='Y').sum()}/{len(done)} ({100*(done['tp1']=='Y').mean():.0f}%)")
print(f"Full stop-outs (no TP): {done['full_loss'].sum()}/{len(done)} ({100*done['full_loss'].mean():.0f}%)")
print(f"Net winners (netR>0): {(done['netR']>0).sum()}/{len(done)}")
print(f"Avg net R per trade (¼ scale-out, SL as posted): {done['netR'].mean():.2f} R")
print(f"Total R over the batch: {done['netR'].sum():.2f} R")
print(f"Entries off-market: {(done['entry_ok']=='OFF').sum()}")
mt5.shutdown()
