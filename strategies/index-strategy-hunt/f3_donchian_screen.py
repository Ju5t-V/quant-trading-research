"""F3 screen: Donchian channel breakout, US500/DE40 D1, next-open fills.
Cells (locked): (20-high entry, 10-low exit) and (55-high, 20-low); long primary,
short ablation. Dev windows ONLY. Swap: feed pts/night and conservative live pts/night.
"""
import pandas as pd

SWAP = {"US500": (0.31, 1.3), "DE40": (0.9, 4.6)}   # (feed-ish, live-conservative)
COST = {"US500": 0.5, "DE40": 1.6}                  # round-trip spread+slippage pts

def run(sym, n_in, n_out, side, swap_night, a, b):
    df = pd.read_parquet(rf"E:\Documents\Quant Trading\Index_Hunt\data\{sym}_D1.parquet")
    df = df[["time", "open", "high", "low", "close"]].reset_index(drop=True)
    df["hh"] = df["high"].rolling(n_in).max().shift(1)
    df["ll_out"] = df["low"].rolling(n_out).min().shift(1)
    df["ll"] = df["low"].rolling(n_in).min().shift(1)
    df["hh_out"] = df["high"].rolling(n_out).max().shift(1)
    sgn = 1 if side == "long" else -1
    trades, pos = [], 0
    for i in range(60, len(df) - 1):
        t = df["time"].iloc[i]
        row = df.iloc[i]
        if pos == 0:
            if not (a <= t < b):
                continue
            trig = row["close"] > row["hh"] if sgn == 1 else row["close"] < row["ll"]
            if trig:
                pos, e_i, entry = sgn, i + 1, df["open"].iloc[i + 1]
        else:
            trig = row["close"] < row["ll_out"] if sgn == 1 else row["close"] > row["hh_out"]
            if trig or i == len(df) - 2:
                exit_px = df["open"].iloc[i + 1]
                nights = i + 1 - e_i
                pnl = sgn * (exit_px - entry) - COST[sym] - nights * swap_night
                trades.append(dict(t=df["time"].iloc[e_i], pnl=pnl, nights=nights,
                                   ret=pnl / entry))
                pos = 0
    tr = pd.DataFrame(trades)
    if len(tr) == 0:
        print("      no trades")
        return
    w = tr.loc[tr.pnl > 0, "pnl"].sum()
    l = -tr.loc[tr.pnl <= 0, "pnl"].sum()
    pf = w / l if l > 0 else float("inf")
    eq = (1 + tr["ret"]).cumprod()
    dd = (1 - eq / eq.cummax()).max()
    print(f"    {sym} {n_in}/{n_out} {side:5s} swap={swap_night}: n={len(tr)}"
          f"  PF={pf:.2f}  win%={100*(tr.pnl>0).mean():.0f}  net={tr.pnl.sum():+.1f}pts"
          f"  retSum={100*tr.ret.sum():+.1f}%  DD={100*dd:.1f}%  avgNights={tr.nights.mean():.0f}")

for a, b, tag in ((pd.Timestamp("2025-01-01"), pd.Timestamp("2026-07-18"), "DEV 2025-26"),
                  (pd.Timestamp("2020-01-01"), pd.Timestamp("2023-01-01"), "DEV 2020-22")):
    print(f"== {tag} ==")
    for sym in ("US500", "DE40"):
        for n_in, n_out in ((20, 10), (55, 20)):
            for side in ("long", "short"):
                for swap in SWAP[sym]:
                    run(sym, n_in, n_out, side, swap, a, b)
