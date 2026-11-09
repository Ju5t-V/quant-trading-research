"""Scripted price paths through the strategy: checks order logic before any real run.

Server days in January 2020 (winter, server = UTC+2). Levels: buy stop 2000.00,
sell stop 1990.00. ATR 14,000 pts, so ATR-sized presets also use 1R = $10.00.
"""
import warnings
from datetime import datetime, timezone

import pandas as pd

warnings.filterwarnings("ignore", message=".*chained assignment.*")
warnings.filterwarnings("ignore", message=".*Timestamp.utcnow.*")

from nautilus_trader.persistence.wranglers import QuoteTickDataWrangler

from gold_level_breakout import LevelBreakout, LevelBreakoutConfig
from run_matrix import PRESETS, SCHEDULE_KEYS, make_engine, make_instrument


def ns(text: str) -> int:
    return int(datetime.strptime(text, "%Y-%m-%d %H:%M").replace(tzinfo=timezone.utc).timestamp()) * 10**9


# Wednesday 2020-01-15: armed 00:05 server = 01-14 22:05 UTC; expires server midnight = 01-15 22:00 UTC
WED = {"2020-01-15": dict(up=2000.00, dn=1990.00, atr_pts=14000.0, sell_ok=True,
                          arm_ns=ns("2020-01-14 22:05"), expire_ns=ns("2020-01-15 22:00"))}
# Friday 2020-01-17: weekend close at 22:30 server = 20:30 UTC
FRI = {"2020-01-17": dict(up=2000.00, dn=1990.00, atr_pts=14000.0, sell_ok=True,
                          arm_ns=ns("2020-01-16 22:05"), expire_ns=ns("2020-01-17 22:00"))}
WED_NO_SELL = {k: dict(v, sell_ok=False) for k, v in WED.items()}

PARTIAL_PATH = [
    ("2020-01-14 22:00:00", 1995.00, 1995.20),
    ("2020-01-14 22:06:00", 1995.00, 1995.20),
    ("2020-01-14 22:10:00", 1999.70, 1999.90),
    ("2020-01-14 22:11:00", 1999.85, 2000.05),   # buy stop fills at ask 2000.05
    ("2020-01-14 22:12:00", 2000.00, 2000.20),
    ("2020-01-14 22:13:00", 2000.10, 2000.30),
    ("2020-01-14 22:20:00", 2010.00, 2010.20),   # TP1 (1R) fills 5 oz at 2010.00
    ("2020-01-14 22:21:00", 2008.00, 2008.20),   # breakeven modify processed
    ("2020-01-14 22:22:00", 2007.00, 2007.20),
    ("2020-01-14 22:30:00", 2000.15, 2000.35),   # BE stop (2000.05 + 0.10) fills 5 oz
    ("2020-01-14 22:31:00", 2000.00, 2000.20),
    ("2020-01-14 22:40:00", 1989.95, 1990.15),   # sell stop fills at bid 1989.95
    ("2020-01-14 22:41:00", 1990.50, 1990.70),
    ("2020-01-14 22:42:00", 1991.00, 1991.20),
    ("2020-01-14 22:50:00", 1999.90, 2000.10),   # short SL (2000.00) fills at ask 2000.10
    ("2020-01-14 22:51:00", 1999.00, 1999.20),
    ("2020-01-15 23:00:00", 1999.00, 1999.20),   # after expiry
]

ORIGINAL_PATH = [
    ("2020-01-14 22:00:00", 1995.00, 1995.20),
    ("2020-01-14 22:06:00", 1995.00, 1995.20),
    ("2020-01-14 22:10:00", 1999.70, 1999.90),
    ("2020-01-14 22:11:00", 1999.85, 2000.05),   # buy stop fills at 2000.05, 200 oz
    ("2020-01-14 22:12:00", 2000.00, 2000.20),
    ("2020-01-14 22:13:00", 2001.10, 2001.30),   # trail activates (>= 2001.05), stop 2000.60
    ("2020-01-14 22:14:00", 2003.00, 2003.20),   # stop trails to 2002.50
    ("2020-01-14 22:15:00", 2002.40, 2002.60),   # trail fills at 2002.40
    ("2020-01-14 22:16:00", 2002.00, 2002.20),
    ("2020-01-15 23:00:00", 1999.00, 1999.20),   # sell stop expired unfilled
]

RUNNER_PATH = [
    ("2020-01-14 22:00:00", 1995.00, 1995.20),
    ("2020-01-14 22:06:00", 1995.00, 1995.20),
    ("2020-01-14 22:11:00", 1999.85, 2000.05),   # buy fills 10 oz at 2000.05
    ("2020-01-14 22:12:00", 2000.00, 2000.20),
    ("2020-01-14 22:20:00", 2010.00, 2010.20),   # TP1 5 oz at 2010.00 -> BE stop + 1R trail, TP2 cancelled
    ("2020-01-14 22:21:00", 2012.00, 2012.20),
    ("2020-01-14 22:25:00", 2025.00, 2025.20),   # past 2R: trail stop at 2015.00
    ("2020-01-14 22:26:00", 2014.90, 2015.10),   # trail fills 5 oz at 2014.90
    ("2020-01-14 22:27:00", 2014.00, 2014.20),
    ("2020-01-15 23:00:00", 2014.00, 2014.20),
]

WEEKEND_PATH = [
    ("2020-01-16 22:00:00", 1995.00, 1995.20),
    ("2020-01-16 22:06:00", 1995.00, 1995.20),
    ("2020-01-16 22:11:00", 1999.85, 2000.05),   # buy fills 10 oz at 2000.05 (Friday server day)
    ("2020-01-16 22:12:00", 2000.00, 2000.20),
    ("2020-01-17 10:00:00", 2004.00, 2004.20),
    ("2020-01-17 20:29:00", 2005.00, 2005.20),
    ("2020-01-17 20:31:00", 2005.00, 2005.20),   # after the 20:30 UTC close: market exit at 2005.00
    ("2020-01-17 21:59:00", 2005.10, 2005.30),
    ("2020-01-17 22:01:00", 2005.00, 2005.20),
]

NO_SELL_PATH = [
    ("2020-01-14 22:00:00", 1995.00, 1995.20),
    ("2020-01-14 22:06:00", 1995.00, 1995.20),
    ("2020-01-14 22:40:00", 1989.95, 1990.15),   # would fill a sell stop - but sells are filtered
    ("2020-01-14 22:41:00", 1985.00, 1985.20),
    ("2020-01-15 23:00:00", 1985.00, 1985.20),
]


def path(rows):
    idx = pd.DatetimeIndex([pd.Timestamp(t, tz="UTC") for t, _, _ in rows])
    return pd.DataFrame({"bid": [b for _, b, _ in rows], "ask": [a for _, _, a in rows]}, index=idx)


def run_case(label: str, preset: str, rows, schedule) -> tuple[list[dict], dict]:
    instrument = make_instrument()
    engine = make_engine(instrument)
    params = {k: v for k, v in PRESETS[preset].items() if k not in SCHEDULE_KEYS}
    strat = LevelBreakout(LevelBreakoutConfig(instrument_id=instrument.id, **params))
    strat.set_schedule(schedule)
    engine.add_strategy(strat)
    engine.add_data(QuoteTickDataWrangler(instrument).process(path(rows)))
    engine.run()
    print(f"\n=== {label} ===")
    for t in strat.closed:
        print({k: t[k] for k in ("side", "qty", "entry_px", "exit_kind", "legs", "pnl_usd", "pnl_R")})
    print("stats:", strat.stats)
    pos = engine.trader.generate_positions_report()
    if len(pos):
        cols = [c for c in ("side", "peak_qty", "avg_px_open", "avg_px_close", "realized_pnl") if c in pos.columns]
        print(pos[cols].to_string())
    closed, stats = list(strat.closed), dict(strat.stats)
    engine.dispose()
    return closed, stats


def check(cond: bool, msg: str) -> None:
    print(("PASS " if cond else "FAIL ") + msg)
    if not cond:
        raise SystemExit(1)


if __name__ == "__main__":
    tr, _ = run_case("PARTIAL_BE fixed stop (preset 1)", "1", PARTIAL_PATH, WED)
    buy = [t for t in tr if t["side"] == "BUY"]
    sell = [t for t in tr if t["side"] == "SELL"]
    check(len(buy) == 1 and len(sell) == 1, "one buy trade and one sell trade closed")
    check(buy[0]["legs"] == "TP1@2010.00x5|SL@2000.15x5", f"buy legs {buy[0]['legs']}")
    check(abs(buy[0]["pnl_usd"] - 50.25) < 1e-6, f"buy pnl 50.25 (got {buy[0]['pnl_usd']})")
    check(sell[0]["legs"] == "SL@2000.10x10", f"sell legs {sell[0]['legs']}")
    check(abs(sell[0]["pnl_usd"] + 101.50) < 1e-6, f"sell pnl -101.50 (got {sell[0]['pnl_usd']})")

    tr, _ = run_case("PARTIAL_BE ATR stop (preset 1A), same path", "1A", PARTIAL_PATH, WED)
    check(len(tr) == 2 and sorted(t["pnl_usd"] for t in tr) == [-101.5, 50.25], "ATR preset at scale 1 matches")

    tr, _ = run_case("ORIGINAL (preset 0a)", "0a", ORIGINAL_PATH, WED)
    check(len(tr) == 1 and tr[0]["qty"] == 200 and tr[0]["exit_kind"] == "TRAIL", f"trail exit ({tr[0]['legs']})")
    check(abs(tr[0]["pnl_usd"] - 470.00) < 1e-6, f"pnl 470.00 (got {tr[0]['pnl_usd']})")

    tr, st = run_case("Runner trail (preset E2)", "E2", RUNNER_PATH, WED)
    check(len(tr) == 1 and tr[0]["legs"] == "TP1@2010.00x5|TRAIL@2014.90x5", f"runner legs {tr[0]['legs'] if tr else None}")
    check(abs(tr[0]["pnl_usd"] - 124.00) < 1e-6 and st["runner_trails"] == 1, f"runner pnl 124.00 (got {tr[0]['pnl_usd']})")

    tr, st = run_case("Weekend close (preset E3)", "E3", WEEKEND_PATH, FRI)
    check(len(tr) == 1 and tr[0]["exit_kind"] == "WKND", f"closed by the Friday rule ({tr[0]['legs'] if tr else None})")
    check(abs(tr[0]["pnl_usd"] - 49.50) < 1e-6 and st["weekend_closes"] == 1, f"weekend pnl 49.50 (got {tr[0]['pnl_usd']})")
    check(st["entry_expired"] == 0, "unfilled sell stop was cancelled at the Friday close, not left to expire")

    tr, st = run_case("Sell filter (preset E4), downtrend flag off", "E4", NO_SELL_PATH, WED_NO_SELL)
    check(len(tr) == 0 and st["sells_filtered"] == 1 and st["entries_placed"] == 1, "no sell armed, buy still armed")
    tr, st = run_case("Sell filter (preset E4), downtrend flag on", "E4", NO_SELL_PATH, WED)
    check(st["sells_filtered"] == 0 and st["entries_placed"] == 2, "sell armed when yesterday closed below the SMA")

    print("\nALL CHECKS PASSED")
