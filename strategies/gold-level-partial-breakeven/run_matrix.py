"""Run one config on one window in NautilusTrader, streaming XAUUSD quotes in chunks.

    python run_matrix.py --name 1A --window A
    python run_matrix.py --name E2 --window B --set levels=ASIA
    python run_matrix.py --name F --window A --stress                   # spread +20 pts
    python run_matrix.py --name F --window A --raw                      # unfiltered ticks
    python run_matrix.py --name F --window C --feed duka --set levels=ASIA   # Dukascopy holdout

Feeds: mt5 = MetaQuotes-Demo (data/ticks_clean, data/bars); duka = Dukascopy
(data/duka_ticks_clean, data/duka_bars). --bars builds 4 quotes per M1 bar instead
of ticks (lower fidelity). Presets:
  0a 0b        Jerry's original bot (2.0 lots / 1% risk), fixed 1000-pt stop
  G            0b with the rollover guard: orders placed 01:15 server, after the reopen
  1 2 3        partial profit + breakeven with the fixed stop (stage 1 reference)
  1A 2A 3A     same with ATR-sized stops (plan v2 step 2a)
  E1..E4       one improvement each on the best base B* (step 2b; levels via --set)
  F            the stacked improvements (step 2c; everything via --set)
  R            GoldBreakoutEA v1.31 trail exit (reference; levels via --set)
"""
import argparse
import json
import time
import warnings
from decimal import Decimal
from pathlib import Path

import pandas as pd
import pyarrow.parquet as pq
from nautilus_trader.backtest.engine import BacktestEngine, BacktestEngineConfig
from nautilus_trader.backtest.models import FillModel
from nautilus_trader.config import LoggingConfig
from nautilus_trader.model.currencies import USD
from nautilus_trader.model.enums import AccountType, AssetClass, OmsType
from nautilus_trader.model.identifiers import InstrumentId, Symbol, TraderId, Venue
from nautilus_trader.model.instruments import Cfd
from nautilus_trader.model.objects import Money, Price, Quantity
from nautilus_trader.persistence.wranglers import QuoteTickDataWrangler

from gold_level_breakout import LevelBreakout, LevelBreakoutConfig
from levels import BARS_DIR, build_schedule
from stats import summarize, yearly

# pandas 3 warnings raised inside Nautilus 1.231 internals (harmless, but one per chunk)
warnings.filterwarnings("ignore", message=".*chained assignment.*")
warnings.filterwarnings("ignore", message=".*Timestamp.utcnow.*")

ROOT = Path(__file__).parent
SIM = Venue("SIM")
WINDOWS = {"A": ("2025-06", "2026-09"), "B": ("2019-01", "2020-12"), "C": ("2021-01", "2025-04")}
TICK_DIRS = {"mt5": ("ticks_clean", "ticks"), "duka": ("duka_ticks_clean", "duka_ticks")}
STRESS_HALF_SPREAD = 0.10  # +20 points total
MAX_CHUNK_TICKS = 1_500_000  # bounds memory: 2026 months hold up to 18M ticks

BASE = dict(sl_mode="FIXED", sl_points=1000.0, tp1_r=1.0, final_r=2.0, partial_frac=0.5,
            be_buffer_points=10.0, size_mode="RISK_USD", risk_usd=100.0)
ATR = dict(BASE, exit_mode="PARTIAL_BE", sl_mode="ATR")
PRESETS = {
    "0a": dict(BASE, levels="PDH_PDL", arm_hour=0, arm_minute=5, exit_mode="ORIGINAL",
               tp_points=1000.0, trail_start_points=100.0, trail_dist_points=50.0,
               size_mode="FIXED_LOTS", lots=2.0),
    "0b": dict(BASE, levels="PDH_PDL", arm_hour=0, arm_minute=5, exit_mode="ORIGINAL",
               tp_points=1000.0, trail_start_points=100.0, trail_dist_points=50.0),
    # G = 0b with the rollover guard: orders placed after the 01:00 server reopen, not before it.
    "G": dict(BASE, levels="PDH_PDL", arm_hour=1, arm_minute=15, exit_mode="ORIGINAL",
              tp_points=1000.0, trail_start_points=100.0, trail_dist_points=50.0),
    "1": dict(BASE, levels="PDH_PDL", arm_hour=0, arm_minute=5, exit_mode="PARTIAL_BE"),
    "2": dict(BASE, levels="ASIA", exit_mode="PARTIAL_BE"),
    "3": dict(BASE, levels="PDH_PDL", arm_hour=6, arm_minute=0, exit_mode="PARTIAL_BE"),
    "1A": dict(ATR, levels="PDH_PDL", arm_hour=0, arm_minute=5),
    "2A": dict(ATR, levels="ASIA"),
    "3A": dict(ATR, levels="PDH_PDL", arm_hour=6, arm_minute=0),
    "E1": dict(ATR, tp1_r=0.5),
    "E2": dict(ATR, runner_mode="TRAIL", runner_trail_r=1.0),
    "E3": dict(ATR, weekend_flat=True),
    "E4": dict(ATR, sell_filter=True),
    "F": dict(ATR),
    "R": dict(BASE, exit_mode="TRAIL_REF", sl_mode="ATR", sl_points=500.0, tp_points=1000.0,
              trail_start_points=300.0, trail_dist_points=150.0),
}
SCHEDULE_KEYS = {"levels", "arm_hour", "arm_minute"}
FLOAT_KEYS = ("sl_points", "tp_points", "trail_start_points", "trail_dist_points", "tp1_r", "final_r",
              "partial_frac", "be_buffer_points", "risk_usd", "lots", "max_spread_points",
              "atr_ref_points", "runner_trail_r")


def make_instrument() -> Cfd:
    return Cfd(
        instrument_id=InstrumentId(Symbol("XAUUSD"), SIM),
        raw_symbol=Symbol("XAUUSD"),
        asset_class=AssetClass.COMMODITY,
        quote_currency=USD,
        price_precision=2,
        size_precision=0,
        price_increment=Price.from_str("0.01"),
        size_increment=Quantity.from_int(1),      # 1 oz = 0.01 MT5 lot
        ts_event=0,
        ts_init=0,
        lot_size=Quantity.from_int(1),
        max_quantity=Quantity.from_int(1_000_000),
        min_quantity=Quantity.from_int(1),
        margin_init=Decimal("0.01"),
        margin_maint=Decimal("0.01"),
        maker_fee=Decimal("0"),
        taker_fee=Decimal("0"),
    )


def make_engine(instrument: Cfd) -> BacktestEngine:
    engine = BacktestEngine(config=BacktestEngineConfig(
        trader_id=TraderId("GOLD-001"), logging=LoggingConfig(log_level="ERROR")))
    # Large balance + leverage so the venue never blocks orders; MT5 margin limits for
    # the exact 2.0-lot run are assessed from the trade list afterwards.
    engine.add_venue(
        venue=SIM, oms_type=OmsType.HEDGING, account_type=AccountType.MARGIN, base_currency=USD,
        starting_balances=[Money(10_000_000, USD)], default_leverage=Decimal(1000),
        fill_model=FillModel(prob_fill_on_limit=1.0, prob_slippage=0.0, random_seed=42),
        reject_stop_orders=True, support_gtd_orders=True, use_reduce_only=True,
    )
    engine.add_instrument(instrument)
    return engine


def months(a: str, b: str):
    y, m = map(int, a.split("-"))
    y2, m2 = map(int, b.split("-"))
    while (y, m) <= (y2, m2):
        yield f"{y:04d}{m:02d}"
        y, m = (y + 1, 1) if m == 12 else (y, m + 1)


def tick_frames(a: str, b: str, folder: str):
    """Stream each month's parquet in slices, so a dense month (18M ticks) is never held whole."""
    for ym in months(a, b):
        f = ROOT / "data" / folder / f"XAUUSD_{ym}.parquet"
        if not f.exists():
            print(f"  missing {folder}/{f.name}", flush=True)
            continue
        pf = pq.ParquetFile(f)
        print(f"  {ym}: {pf.metadata.num_rows:,} ticks  ({time.strftime('%H:%M:%S')})", flush=True)
        for batch in pf.iter_batches(batch_size=MAX_CHUNK_TICKS, columns=["utc_ns", "bid", "ask"]):
            yield batch.to_pandas()


def bar_frames(a: str, b: str, feed: str):
    m1 = pd.read_parquet(BARS_DIR[feed] / "XAUUSD_M1.parquet")
    t = pd.to_datetime(m1["utc_ns"], unit="ns")
    lo = pd.Timestamp(f"{a}-01")
    hi = pd.Timestamp(f"{b}-01") + pd.offsets.MonthEnd(1) + pd.Timedelta(days=1)
    m1 = m1[(t >= lo) & (t < hi)]
    week = m1["utc_ns"].to_numpy() // (7 * 86_400 * 1_000_000_000)
    for _, g in m1.groupby(week, sort=True):
        yield g


def run(name: str, window: str, overrides: dict, stress: bool, bars: bool, raw: bool, feed: str,
        first: str | None, last: str | None) -> None:
    params = dict(PRESETS[name])
    params.update(overrides)
    a, b = WINDOWS[window]
    a, b = first or a, last or b
    instrument = make_instrument()
    engine = make_engine(instrument)

    sched_args = {k: params.pop(k) for k in list(params) if k in SCHEDULE_KEYS}
    schedule = build_schedule(sched_args.get("levels", "PDH_PDL"), sched_args.get("arm_hour", 0),
                              sched_args.get("arm_minute", 5), start=f"{a}-01",
                              end=str((pd.Timestamp(f"{b}-01") + pd.offsets.MonthEnd(1)).date()),
                              feed=feed)
    strat = LevelBreakout(LevelBreakoutConfig(instrument_id=instrument.id,
                                              levels=sched_args.get("levels", "PDH_PDL"), **params))
    strat.set_schedule(schedule)
    engine.add_strategy(strat)
    wrangler = QuoteTickDataWrangler(instrument)

    folder = TICK_DIRS[feed][1 if raw else 0]
    data = f"{feed}_bars" if bars else folder
    tag = f"{name}_{window}" + (f"_{first}_{last}" if (first or last) else "") + \
          ("_stress" if stress else "") + ("_bars" if bars else "") + ("_raw" if raw else "") + \
          ("_duka" if feed == "duka" else "")
    t0, n_quotes = time.time(), 0
    frames = bar_frames(a, b, feed) if bars else tick_frames(a, b, folder)
    for g in frames:
        idx = pd.DatetimeIndex(g["utc_ns"].to_numpy().astype("datetime64[ns]"), tz="UTC")
        if bars:
            bid = pd.DataFrame({c: g[c].to_numpy() for c in ("open", "high", "low", "close")}, index=idx)
            ask = bid + (g["spread"].to_numpy() * 0.01)[:, None]
            if stress:
                bid, ask = bid - STRESS_HALF_SPREAD, ask + STRESS_HALF_SPREAD
            ticks = wrangler.process_bar_data(bid, ask, offset_interval_ms=10_000,
                                              timestamp_is_close=False, random_seed=42)
        else:
            bid = g["bid"].to_numpy() - (STRESS_HALF_SPREAD if stress else 0.0)
            ask = g["ask"].to_numpy() + (STRESS_HALF_SPREAD if stress else 0.0)
            ticks = wrangler.process(pd.DataFrame(
                {"bid": bid, "ask": ask, "bid_size": 1e6, "ask_size": 1e6}, index=idx))
        n_quotes += len(ticks)
        engine.add_data(ticks)
        engine.run(streaming=True)
        engine.clear_data()
        del ticks
    engine.end()
    secs = time.time() - t0

    trades = pd.DataFrame(strat.closed)
    out_dir = ROOT / "results"
    out_dir.mkdir(exist_ok=True)
    trades.to_csv(out_dir / f"{tag}.csv", index=False)
    summary = dict(tag=tag, name=name, window=[a, b], feed=feed, data=data, stress=stress,
                   params=params, schedule=sched_args, overrides=overrides,
                   quotes=n_quotes, seconds=round(secs, 1), strategy_stats=strat.stats,
                   summary=summarize(trades))
    (out_dir / f"{tag}.json").write_text(json.dumps(summary, indent=2, default=str))
    print(json.dumps({k: summary[k] for k in ("tag", "data", "quotes", "seconds", "strategy_stats")},
                     default=str), flush=True)
    print(json.dumps(summary["summary"], default=str), flush=True)
    if len(trades):
        print(yearly(trades).to_string(index=False), flush=True)
    engine.dispose()


def parse_value(v: str):
    if v.lower() in ("true", "false"):
        return v.lower() == "true"
    for cast in (int, float):
        try:
            return cast(v)
        except ValueError:
            pass
    return v


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("--name", required=True, choices=sorted(PRESETS))
    ap.add_argument("--window", required=True, choices=sorted(WINDOWS))
    ap.add_argument("--set", action="append", default=[], help="override, e.g. levels=ASIA")
    ap.add_argument("--stress", action="store_true", help="widen spread by 20 points")
    ap.add_argument("--bars", action="store_true", help="quotes from M1 bars")
    ap.add_argument("--raw", action="store_true", help="unfiltered ticks")
    ap.add_argument("--feed", default="mt5", choices=sorted(TICK_DIRS))
    ap.add_argument("--first", help="YYYY-MM (shorter test)")
    ap.add_argument("--last", help="YYYY-MM (shorter test)")
    args = ap.parse_args()
    ov = {}
    for kv in args.set:
        k, v = kv.split("=", 1)
        ov[k] = parse_value(v)
    for k in FLOAT_KEYS:
        if k in ov:
            ov[k] = float(ov[k])
    run(args.name, args.window, ov, args.stress, args.bars, args.raw, args.feed, args.first, args.last)
