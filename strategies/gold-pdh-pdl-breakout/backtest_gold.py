"""
Backtest of GoldBreakoutEA logic on XAUUSD.

Replicates the EA exactly:
  - At each new server-time day: place buy stop at prev day high, sell stop at
    prev day low (skip a side if price already gapped beyond it). Pending
    orders expire at day end. Both sides can trigger (up to 2 trades/day).
  - SL/TP in points from entry. Aggressive trail: once profit >= trail_start
    points, SL ratchets to price - trail_dist points (never backwards).
  - Positions carry overnight until SL/TP/trail exit.

Prices in CSV are bid. Buys execute at ask = bid + spread.
Intrabar rules (conservative where the path is unknown):
  - SL checked before TP within a bar.
  - For a buy stop, the bar high is always at-or-after the trigger, so
    trailing from the bar high on the entry bar is path-valid; a close beyond
    the new trailed SL guarantees the SL was crossed after the high.
"""
import numpy as np
import pandas as pd

POINT = 0.01          # XAUUSD point size (2-digit broker)
USD_PER_PT_PER_LOT = 1.0  # 100 oz contract: 0.01 move = $1 per lot


def load_data():
    m5 = pd.read_csv(r"E:\Documents\Quant Trading\MT5\xauusd_m5.csv", parse_dates=["time"])
    m1 = pd.read_csv(r"E:\Documents\Quant Trading\MT5\xauusd_m1.csv", parse_dates=["time"])
    d1 = pd.read_csv(r"E:\Documents\Quant Trading\MT5\xauusd_d1.csv", parse_dates=["time"])
    for df in (m5, m1, d1):
        df["date"] = df["time"].dt.date
    return m5, m1, d1


def run(bars, d1, sl_pts=1000, tp_pts=1000, trail_start=100, trail_dist=50,
        spread_pts=4, oco=False, allow_long=True, allow_short=True,
        trend_ma=0, start=None, end=None, entry_hour=0):
    """Simulate the EA. Returns a trades DataFrame."""
    d1 = d1.sort_values("time").reset_index(drop=True)
    prev_hl = {}   # date -> (prev high, prev low)
    ma_ok_long, ma_ok_short = {}, {}
    closes = d1["close"].values
    for i in range(1, len(d1)):
        d = d1["date"].iloc[i]
        prev_hl[d] = (d1["high"].iloc[i - 1], d1["low"].iloc[i - 1])
        if trend_ma > 0 and i >= trend_ma:
            ma = closes[i - trend_ma:i].mean()
            ma_ok_long[d] = closes[i - 1] > ma
            ma_ok_short[d] = closes[i - 1] < ma
        else:
            ma_ok_long[d] = True
            ma_ok_short[d] = True

    sp = spread_pts * POINT
    sl_d, tp_d = sl_pts * POINT, tp_pts * POINT
    ts_d, td_d = trail_start * POINT, trail_dist * POINT

    if start is not None:
        bars = bars[bars["date"] >= start]
    if end is not None:
        bars = bars[bars["date"] <= end]

    positions = []   # open positions
    pend = []        # today's pending orders
    trades = []
    cur_date = None
    placed = False
    hours = bars["time"].dt.hour.values

    for t, d, o, h, l, c, hr in zip(bars["time"].values, bars["date"].values,
                                    bars["open"].values, bars["high"].values,
                                    bars["low"].values, bars["close"].values,
                                    hours):
        # ---- new day: clear old pendings; place new ones at entry_hour ----
        if d != cur_date:
            cur_date = d
            pend = []
            placed = False
        if not placed and hr >= entry_hour:
            placed = True
            if d in prev_hl:
                ph, pl = prev_hl[d]
                if allow_long and ma_ok_long[d] and (o + sp) < ph:
                    pend.append([1, ph])          # buy stop at prev high (ask price)
                if allow_short and ma_ok_short[d] and o > pl:
                    pend.append([-1, pl])         # sell stop at prev low (bid price)

        # ---- pending order triggers ----
        new_pos = []
        still = []
        for direction, level in pend:
            if direction == 1 and (h + sp) >= level:      # ask touched level
                new_pos.append({"dir": 1, "entry": level, "sl": level - sl_d,
                                "tp": level + tp_d, "t_in": t, "entry_bar": True})
            elif direction == -1 and l <= level:          # bid touched level
                new_pos.append({"dir": -1, "entry": level, "sl": level + sl_d,
                                "tp": level - tp_d, "t_in": t, "entry_bar": True})
            else:
                still.append([direction, level])
        pend = still
        if oco and new_pos:
            pend = []
        positions.extend(new_pos)

        # ---- manage open positions ----
        keep = []
        for p in positions:
            exit_px, reason = None, None
            if p["dir"] == 1:                    # long: bid OHLC applies directly
                if l <= p["sl"] and not p["entry_bar"]:
                    exit_px, reason = p["sl"], ("TRAIL" if p["sl"] > p["entry"] - sl_d + 1e-9 else "SL")
                elif h >= p["tp"]:
                    exit_px, reason = p["tp"], "TP"
                else:
                    if h >= p["entry"] + ts_d:
                        new_sl = h - td_d
                        if new_sl > p["sl"]:
                            p["sl"] = new_sl
                    if c <= p["sl"] and p["sl"] > p["entry"] - sl_d + 1e-9:
                        exit_px, reason = p["sl"], "TRAIL"
                    elif l <= p["sl"] and p["entry_bar"]:
                        exit_px, reason = p["sl"], "SL"
                if exit_px is not None:
                    pts = (exit_px - p["entry"]) / POINT
            else:                                 # short: server checks ask = bid + spread
                ask_l, ask_h, ask_c = l + sp, h + sp, c + sp
                if ask_h >= p["sl"] and not p["entry_bar"]:
                    exit_px, reason = p["sl"], ("TRAIL" if p["sl"] < p["entry"] + sl_d - 1e-9 else "SL")
                elif ask_l <= p["tp"]:
                    exit_px, reason = p["tp"], "TP"
                else:
                    if ask_l <= p["entry"] - ts_d:
                        new_sl = ask_l + td_d
                        if new_sl < p["sl"]:
                            p["sl"] = new_sl
                    if ask_c >= p["sl"] and p["sl"] < p["entry"] + sl_d - 1e-9:
                        exit_px, reason = p["sl"], "TRAIL"
                    elif ask_h >= p["sl"] and p["entry_bar"]:
                        exit_px, reason = p["sl"], "SL"
                if exit_px is not None:
                    pts = (p["entry"] - exit_px) / POINT

            p["entry_bar"] = False
            if exit_px is None:
                keep.append(p)
            else:
                trades.append({"t_in": p["t_in"], "t_out": t, "dir": p["dir"],
                               "entry": p["entry"], "exit": exit_px,
                               "pts": pts, "reason": reason})
        positions = keep

    # force-close anything still open at the last bar (mark-to-market)
    if positions:
        last_bid = bars["close"].iloc[-1]
        for p in positions:
            pts = ((last_bid - p["entry"]) if p["dir"] == 1
                   else (p["entry"] - (last_bid + sp))) / POINT
            trades.append({"t_in": p["t_in"], "t_out": bars["time"].iloc[-1],
                           "dir": p["dir"], "entry": p["entry"], "exit": last_bid,
                           "pts": pts, "reason": "OPEN_EOD"})
    return pd.DataFrame(trades)


def stats(trades, lots=2.0, balance=10_000.0, label=""):
    if trades.empty:
        return {"label": label, "trades": 0}
    usd = trades["pts"] * USD_PER_PT_PER_LOT * lots
    eq = balance + usd.cumsum()
    peak = eq.cummax()
    dd = (eq - peak).min()
    wins = trades["pts"] > 0
    gross_w = trades.loc[wins, "pts"].sum()
    gross_l = -trades.loc[~wins, "pts"].sum()
    return {
        "label": label,
        "trades": len(trades),
        "win%": 100 * wins.mean(),
        "net_pts": trades["pts"].sum(),
        "PF": gross_w / gross_l if gross_l > 0 else float("inf"),
        "avg_pts": trades["pts"].mean(),
        f"net_${lots}lot": usd.sum(),
        f"maxDD_${lots}lot": dd,
        "end_bal": eq.iloc[-1],
        "SL_exits": (trades["reason"] == "SL").sum(),
        "TP_exits": (trades["reason"] == "TP").sum(),
        "TRAIL_exits": (trades["reason"] == "TRAIL").sum(),
        "long_pts": trades.loc[trades["dir"] == 1, "pts"].sum(),
        "short_pts": trades.loc[trades["dir"] == -1, "pts"].sum(),
    }


def show(rows):
    df = pd.DataFrame(rows)
    with pd.option_context("display.width", 250, "display.max_columns", 30,
                           "display.float_format", lambda x: f"{x:,.1f}"):
        print(df.to_string(index=False))


if __name__ == "__main__":
    from datetime import date
    m5, m1, d1 = load_data()
    jan1, mar19 = date(2026, 1, 1), date(2026, 3, 19)

    print("=" * 100)
    print("BASELINE — your exact settings (SL/TP 1000, trail 100/50), Jan 1 - Jul 3 2026, M5 data")
    print("=" * 100)
    tr_m5 = run(m5, d1, start=jan1)
    rows = [stats(tr_m5, label="M5 full period, spread 4pt")]

    tr_m5_sp20 = run(m5, d1, start=jan1, spread_pts=20)
    rows.append(stats(tr_m5_sp20, label="M5 full period, spread 20pt"))

    # granularity check: same window on M1 vs M5
    tr_m1 = run(m1, d1, start=mar19)
    rows.append(stats(tr_m1, label="M1 Mar19-Jul3 (granularity check)"))
    tr_m5_cut = run(m5, d1, start=mar19)
    rows.append(stats(tr_m5_cut, label="M5 Mar19-Jul3 (same window)"))
    show(rows)

    tr_m5.to_csv(r"E:\Documents\Quant Trading\MT5\trades_baseline.csv", index=False)

    print()
    print("Monthly net points (baseline, M5):")
    tmp = tr_m5.copy()
    tmp["month"] = pd.to_datetime(tmp["t_out"]).dt.to_period("M")
    print(tmp.groupby("month")["pts"].agg(["count", "sum"]).to_string())
