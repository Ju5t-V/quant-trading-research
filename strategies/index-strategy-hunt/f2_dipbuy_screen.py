"""F2 screen: US500 multi-day dip-buy (pre-registered spec), DEV WINDOWS ONLY.

Spec (locked before running): trend gate close>SMA200(D1); enter next open after
RSI(2)<10 OR 2 consecutive down closes; exit at close when close>prev high or
RSI(2)>70, else 5-day time stop; long only.
Costs: spread 0.30 idx pts per round trip; swap per held night — two scenarios:
feed value 0.31 pts/night and conservative live 1.3 pts/night.
"""
import pandas as pd
import numpy as np

df = pd.read_parquet(r"E:\Documents\Quant Trading\Index_Hunt\data\US500_D1.parquet")
df = df[["time", "open", "high", "low", "close"]].reset_index(drop=True)

delta = df["close"].diff()
gain = delta.clip(lower=0).ewm(alpha=1 / 2, adjust=False).mean()
loss = (-delta.clip(upper=0)).ewm(alpha=1 / 2, adjust=False).mean()
rs = gain / loss.replace(0, np.nan)
df["rsi2"] = 100 - 100 / (1 + rs)
df["sma200"] = df["close"].rolling(200).mean()
df["down"] = df["close"] < df["close"].shift(1)
df["sig"] = (df["close"] > df["sma200"]) & (
    (df["rsi2"] < 10) | (df["down"] & df["down"].shift(1)))

SPREAD = 0.30

def run(win_from, win_to, swap_night):
    trades = []
    i = 0
    n = len(df)
    while i < n - 1:
        t = df["time"].iloc[i]
        if not (win_from <= t < win_to and df["sig"].iloc[i]):
            i += 1
            continue
        # enter next bar open
        e = i + 1
        if e >= n:
            break
        entry = df["open"].iloc[e]
        j = e
        exit_px, exit_j = None, None
        while j < n:
            held = j - e
            if j > e and (df["close"].iloc[j] > df["high"].iloc[j - 1]
                          or df["rsi2"].iloc[j] > 70):
                exit_px, exit_j = df["close"].iloc[j], j
                break
            if held >= 5:
                exit_px, exit_j = df["close"].iloc[j], j
                break
            j += 1
        if exit_px is None:
            exit_px, exit_j = df["close"].iloc[n - 1], n - 1
        nights = exit_j - e
        pnl = exit_px - entry - SPREAD - nights * swap_night
        trades.append(dict(t=df["time"].iloc[e], pnl=pnl, nights=nights,
                           ret=pnl / entry))
        i = exit_j + 1  # no overlapping trades
    tr = pd.DataFrame(trades)
    if len(tr) == 0:
        print("  no trades")
        return
    w = tr.loc[tr.pnl > 0, "pnl"].sum()
    l = -tr.loc[tr.pnl <= 0, "pnl"].sum()
    pf = w / l if l > 0 else float("inf")
    eq = (1 + tr["ret"]).cumprod()
    dd = (1 - eq / eq.cummax()).max()
    yrs = (win_to - win_from).days / 365.25
    print(f"  n={len(tr)} ({len(tr)/yrs:.0f}/yr)  PF={pf:.2f}  win%={100*(tr.pnl>0).mean():.0f}"
          f"  net={tr.pnl.sum():+.1f}pts  ret_sum={100*tr.ret.sum():+.1f}%  maxDD={100*dd:.1f}%"
          f"  avg_nights={tr.nights.mean():.1f}")

for swap in (0.31, 1.3):
    print(f"\n== swap {swap} pts/night ==")
    for a, b, tag in ((pd.Timestamp("2025-01-01"), pd.Timestamp("2026-07-18"), "DEV 2025-26"),
                      (pd.Timestamp("2020-01-01"), pd.Timestamp("2023-01-01"), "DEV 2020-22")):
        print(f" {tag}")
        run(a, b, swap)
