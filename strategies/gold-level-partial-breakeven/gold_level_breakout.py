"""Level breakout strategy for XAUUSD on NautilusTrader 1.231.

Once per day a buy stop is armed at an upper level and a sell stop at a lower
level (see levels.py for PDH_PDL and ASIA). Both sides may fill on the same day
and open positions are never force-closed unless weekend_flat is on.

Exits are real resting orders -- no per-tick Python code:
  ORIGINAL   : SL stop + TP limit + trailing stop that activates at +start and
               trails dist behind price. Replays Jerry's bot (1000/1000, 100/50).
  PARTIAL_BE : SL stop (full size) + TP1 limit (partial) + TP2 limit (the rest).
               When TP1 fills, the SL shrinks to the rest and moves to the fill
               price + a small buffer (breakeven). With runner_mode="TRAIL" the
               TP2 limit is replaced at that moment by a trailing stop
               runner_trail_r x R behind price, so the rest can run past 2R.
  TRAIL_REF  : the three ORIGINAL orders with GoldBreakoutEA v1.31 distances.

Options (all off by default, so older configs behave exactly as before):
  weekend_flat : on Friday at weekend_flat_hour:minute (server clock) unfilled
                 entries are cancelled and open positions closed at market.
  sell_filter  : the sell stop is only armed when the schedule row's sell_ok is
                 true (yesterday's close below the D1 SMA(50), see levels.py).

SL/TP prices are measured from the LEVEL (the pending order price, as the MT5 EAs
do); trailing activation and breakeven are measured from the actual fill price.
Profit is booked per exit leg from real fill prices; 1R = qty x stop distance.
"""
from __future__ import annotations

from dataclasses import dataclass, field
from datetime import datetime, timedelta, timezone
from decimal import Decimal
from zoneinfo import ZoneInfo

from nautilus_trader.config import StrategyConfig
from nautilus_trader.model.enums import OrderSide, TimeInForce, TrailingOffsetType, TriggerType
from nautilus_trader.model.identifiers import InstrumentId
from nautilus_trader.model.objects import Quantity
from nautilus_trader.trading.strategy import Strategy

SERVER_TZ = ZoneInfo("Europe/Athens")
POINT = 0.01
OZ_PER_LOT = 100
SWAP_POINTS_PER_LOT = {OrderSide.BUY: -12.6, OrderSide.SELL: -4.6}  # MetaQuotes-Demo, Sep 2026


class LevelBreakoutConfig(StrategyConfig, frozen=True):
    instrument_id: InstrumentId
    levels: str = "PDH_PDL"            # PDH_PDL | ASIA (the schedule carries the prices)
    exit_mode: str = "PARTIAL_BE"      # ORIGINAL | PARTIAL_BE | TRAIL_REF
    sl_mode: str = "FIXED"             # FIXED | ATR
    sl_points: float = 1000.0
    tp_points: float = 1000.0          # ORIGINAL / TRAIL_REF target
    trail_start_points: float = 100.0
    trail_dist_points: float = 50.0
    atr_ref_points: float = 14000.0
    tp1_r: float = 1.0
    final_r: float = 2.0
    partial_frac: float = 0.5
    be_buffer_points: float = 10.0
    runner_mode: str = "TP2"           # TP2 (fixed final target) | TRAIL (trail the rest after TP1)
    runner_trail_r: float = 1.0
    weekend_flat: bool = False
    weekend_flat_hour: int = 22
    weekend_flat_minute: int = 30
    sell_filter: bool = False
    size_mode: str = "RISK_USD"        # RISK_USD | FIXED_LOTS
    risk_usd: float = 100.0
    lots: float = 2.0
    max_spread_points: float = 80.0


@dataclass
class Trade:
    day: str
    side: OrderSide
    level_px: float
    r_px: float
    tp_px: float
    start_px: float
    dist_px: float
    qty: int
    arm_ns: int
    spread_pts: float
    entry_coid: object = None
    status: str = "armed"
    entry_ns: int = 0
    entry_px: float = 0.0
    position_id: object = None
    remaining: int = 0
    exits: dict = field(default_factory=dict)
    legs: list = field(default_factory=list)
    tp1_hit: bool = False
    be_moved: bool = False
    sl_trigger: float = 0.0
    entry_slip_pts: float = 0.0      # fill beyond the stop level (+ = worse)
    max_stop_slip_pts: float = 0.0   # worst stop-loss fill beyond its trigger (+ = worse)

    @property
    def sign(self) -> int:
        return 1 if self.side == OrderSide.BUY else -1


def ns_to_dt(ns: int) -> datetime:
    return datetime.fromtimestamp(ns // 1_000_000_000, tz=timezone.utc) + timedelta(
        microseconds=(ns % 1_000_000_000) // 1000)


def swap_nights(entry_ns: int, exit_ns: int) -> int:
    """Rollovers charged between entry and exit: weekdays only, Wednesday counts 3."""
    a = datetime.fromtimestamp(entry_ns / 1e9, SERVER_TZ).date()
    b = datetime.fromtimestamp(exit_ns / 1e9, SERVER_TZ).date()
    n, d = 0, a
    while d < b:
        if d.weekday() < 5:
            n += 3 if d.weekday() == 2 else 1
        d += timedelta(days=1)
    return n


class LevelBreakout(Strategy):
    def __init__(self, config: LevelBreakoutConfig) -> None:
        super().__init__(config)
        self.schedule: dict[str, dict] = {}
        self.instrument = None
        self.by_entry: dict = {}
        self.by_exit: dict = {}
        self.closed: list[dict] = []
        self.stats = dict(days=0, spread_waits=0, days_skipped_spread=0, entries_placed=0,
                          entry_rejected=0, entry_expired=0, modify_rejected=0,
                          exit_rejected=0, open_at_end=0, sells_filtered=0,
                          runner_trails=0, weekend_flats=0, weekend_closes=0)

    def set_schedule(self, schedule: dict[str, dict]) -> None:
        self.schedule = schedule

    # ------------------------------------------------------------------ arming
    def on_start(self) -> None:
        self.instrument = self.cache.instrument(self.config.instrument_id)
        now = self.clock.timestamp_ns()
        for day, row in self.schedule.items():
            if row["expire_ns"] <= now:
                continue
            self.clock.set_time_alert(f"arm|{day}|0", ns_to_dt(max(row["arm_ns"], now)), self._on_arm)
        if self.config.weekend_flat and self.schedule:
            d = datetime.strptime(min(self.schedule), "%Y-%m-%d")
            last = datetime.strptime(max(self.schedule), "%Y-%m-%d")
            while d <= last:
                if d.weekday() == 4:
                    flat = datetime(d.year, d.month, d.day, self.config.weekend_flat_hour,
                                    self.config.weekend_flat_minute, tzinfo=SERVER_TZ)
                    ns = int(flat.timestamp()) * 1_000_000_000
                    if ns > now:
                        self.clock.set_time_alert(f"flat|{d:%Y-%m-%d}", ns_to_dt(ns), self._on_weekend_flat)
                d += timedelta(days=1)

    def _on_arm(self, event) -> None:
        _, day, attempt = event.name.split("|")
        row = self.schedule[day]
        now = self.clock.timestamp_ns()
        if now >= row["expire_ns"]:
            return
        quote = self.cache.quote_tick(self.config.instrument_id)
        spread = None if quote is None else float(quote.ask_price) - float(quote.bid_price)
        if spread is None or spread > self.config.max_spread_points * POINT + 1e-9:
            # the MT5 bot waits for a normal spread before placing; retry each minute
            self.stats["spread_waits"] += 1
            nxt = now + 60_000_000_000
            if nxt < row["expire_ns"]:
                self.clock.set_time_alert(f"arm|{day}|{int(attempt) + 1}", ns_to_dt(nxt), self._on_arm)
            else:
                self.stats["days_skipped_spread"] += 1
            return

        self.stats["days"] += 1
        r_px, tp_px, start_px, dist_px = self._distances(row["atr_pts"])
        for side, level in ((OrderSide.BUY, row["up"]), (OrderSide.SELL, row["dn"])):
            if side == OrderSide.SELL and self.config.sell_filter and not row.get("sell_ok", True):
                self.stats["sells_filtered"] += 1
                continue
            qty = self._qty(r_px)
            if qty <= 0:
                continue
            order = self.order_factory.stop_market(
                instrument_id=self.config.instrument_id,
                order_side=side,
                quantity=Quantity.from_int(qty),
                trigger_price=self.instrument.make_price(level),
                trigger_type=TriggerType.BID_ASK,
                time_in_force=TimeInForce.GTD,
                expire_time=ns_to_dt(row["expire_ns"]),
            )
            trade = Trade(day=day, side=side, level_px=level, r_px=r_px, tp_px=tp_px,
                          start_px=start_px, dist_px=dist_px, qty=qty, arm_ns=now,
                          spread_pts=spread / POINT, entry_coid=order.client_order_id)
            self.by_entry[order.client_order_id] = trade
            self.stats["entries_placed"] += 1
            self.submit_order(order)

    def _on_weekend_flat(self, event) -> None:
        self.stats["weekend_flats"] += 1
        for coid, trade in list(self.by_entry.items()):
            if trade.status == "armed":
                o = self.cache.order(coid)
                if o is not None and not o.is_closed:
                    self.cancel_order(o)
        open_trades = {id(v[0]): v[0] for v in self.by_exit.values()}.values()
        for trade in open_trades:
            if trade.status == "open" and trade.remaining > 0 and "WKND" not in trade.exits:
                self.stats["weekend_closes"] += 1
                self._submit_exit(trade, "WKND", self.order_factory.market(
                    instrument_id=self.config.instrument_id, order_side=self._exit_side(trade),
                    quantity=Quantity.from_int(trade.remaining), reduce_only=True))

    def _distances(self, atr_pts):
        c = self.config
        if c.sl_mode == "ATR" and atr_pts:
            s = min(2.0, max(0.1, atr_pts / c.atr_ref_points))
            sl = max(200.0, c.sl_points * s)
            tp = max(400.0, c.tp_points * s)
            start = max(150.0, c.trail_start_points * s)
            dist = max(80.0, c.trail_dist_points * s)
        else:
            sl, tp, start, dist = c.sl_points, c.tp_points, c.trail_start_points, c.trail_dist_points
        return sl * POINT, tp * POINT, start * POINT, dist * POINT

    def _qty(self, r_px: float) -> int:
        if self.config.size_mode == "FIXED_LOTS":
            return int(round(self.config.lots * OZ_PER_LOT))
        q = int(self.config.risk_usd / r_px + 1e-9)  # $1 per oz per $1 move
        if self.config.exit_mode == "PARTIAL_BE":
            q = max(2, (q // 2) * 2)
        return max(q, 1)

    # ----------------------------------------------------------------- events
    def on_order_filled(self, event) -> None:
        coid = event.client_order_id
        trade = self.by_entry.get(coid)
        if trade is not None and trade.status == "armed":
            self._on_entry(trade, event)
            return
        hit = self.by_exit.get(coid)
        if hit is not None:
            self._on_exit(hit[0], hit[1], event)

    def on_order_expired(self, event) -> None:
        trade = self.by_entry.pop(event.client_order_id, None)
        if trade is not None and trade.status == "armed":
            self.stats["entry_expired"] += 1

    def on_order_canceled(self, event) -> None:
        trade = self.by_entry.get(event.client_order_id)
        if trade is not None and trade.status == "armed":
            self.by_entry.pop(event.client_order_id, None)

    def on_order_rejected(self, event) -> None:
        trade = self.by_entry.get(event.client_order_id)
        if trade is not None and trade.status == "armed":
            # price was already beyond the level when armed (MT5 rejects these too)
            self.stats["entry_rejected"] += 1
            self.by_entry.pop(event.client_order_id, None)
            return
        hit = self.by_exit.get(event.client_order_id)
        if hit is not None:
            trade, kind = hit
            self.stats["exit_rejected"] += 1
            if trade.remaining > 0 and kind in ("SL", "BE"):
                self._close_at_market(trade)

    def on_order_modify_rejected(self, event) -> None:
        hit = self.by_exit.get(event.client_order_id)
        self.stats["modify_rejected"] += 1
        if hit is None:
            return
        trade, _ = hit
        old = self.cache.order(event.client_order_id)
        if old is not None and not old.is_closed:
            self.cancel_order(old)
        trade.sl_trigger = self._be_price(trade)
        self._submit_exit(trade, "BE", self.order_factory.stop_market(
            instrument_id=self.config.instrument_id,
            order_side=self._exit_side(trade),
            quantity=Quantity.from_int(trade.remaining),
            trigger_price=self.instrument.make_price(self._be_price(trade)),
            trigger_type=TriggerType.BID_ASK,
            reduce_only=True,
        ))

    def on_stop(self) -> None:
        self.stats["open_at_end"] = sum(1 for t in {id(v[0]): v[0] for v in self.by_exit.values()}.values()
                                        if t.status == "open")

    # ------------------------------------------------------------------ exits
    def _exit_side(self, t: Trade) -> OrderSide:
        return OrderSide.SELL if t.side == OrderSide.BUY else OrderSide.BUY

    def _be_price(self, t: Trade) -> float:
        return t.entry_px + t.sign * self.config.be_buffer_points * POINT

    def _submit_exit(self, t: Trade, kind: str, order) -> None:
        t.exits[kind] = order.client_order_id
        self.by_exit[order.client_order_id] = (t, kind)
        self.submit_order(order, position_id=t.position_id)

    def _on_entry(self, t: Trade, ev) -> None:
        self.by_entry.pop(t.entry_coid, None)
        t.status = "open"
        t.entry_ns = ev.ts_event
        t.entry_px = float(ev.last_px)
        t.position_id = ev.position_id
        t.remaining = t.qty
        c, s, side = self.config, t.sign, self._exit_side(t)
        mk = self.instrument.make_price
        t.entry_slip_pts = round(s * (t.entry_px - t.level_px) / POINT, 1)
        t.sl_trigger = t.level_px - s * t.r_px

        self._submit_exit(t, "SL", self.order_factory.stop_market(
            instrument_id=c.instrument_id, order_side=side, quantity=Quantity.from_int(t.qty),
            trigger_price=mk(t.sl_trigger), trigger_type=TriggerType.BID_ASK,
            reduce_only=True))

        if c.exit_mode == "PARTIAL_BE":
            q1 = max(1, min(t.qty - 1, int(round(t.qty * c.partial_frac))))
            q2 = t.qty - q1
            self._submit_exit(t, "TP1", self.order_factory.limit(
                instrument_id=c.instrument_id, order_side=side, quantity=Quantity.from_int(q1),
                price=mk(t.level_px + s * c.tp1_r * t.r_px), reduce_only=True))
            self._submit_exit(t, "TP2", self.order_factory.limit(
                instrument_id=c.instrument_id, order_side=side, quantity=Quantity.from_int(q2),
                price=mk(t.level_px + s * c.final_r * t.r_px), reduce_only=True))
        else:
            self._submit_exit(t, "TP", self.order_factory.limit(
                instrument_id=c.instrument_id, order_side=side, quantity=Quantity.from_int(t.qty),
                price=mk(t.level_px + s * t.tp_px), reduce_only=True))
            self._submit_exit(t, "TRAIL", self.order_factory.trailing_stop_market(
                instrument_id=c.instrument_id, order_side=side, quantity=Quantity.from_int(t.qty),
                trailing_offset=Decimal(f"{t.dist_px:.2f}"),
                activation_price=mk(t.entry_px + s * t.start_px),
                trigger_type=TriggerType.BID_ASK,
                trailing_offset_type=TrailingOffsetType.PRICE,
                reduce_only=True))

    def _on_exit(self, t: Trade, kind: str, ev) -> None:
        if t.status != "open":
            return
        q = min(int(ev.last_qty), t.remaining)
        px = float(ev.last_px)
        t.legs.append((kind, ev.ts_event, px, q))
        t.remaining -= q
        if kind in ("SL", "BE"):
            t.max_stop_slip_pts = max(t.max_stop_slip_pts, round(t.sign * (t.sl_trigger - px) / POINT, 1))
        if kind == "TP1":
            t.tp1_hit = True
        if t.remaining <= 0:
            self._cancel_exits(t)
            self._finalize(t)
            return
        if kind == "TP1" and self.config.exit_mode == "PARTIAL_BE":
            sl = self.cache.order(t.exits["SL"])
            if sl is not None and not sl.is_closed:
                self.modify_order(sl, quantity=Quantity.from_int(t.remaining),
                                  trigger_price=self.instrument.make_price(self._be_price(t)))
                t.sl_trigger = self._be_price(t)
                t.be_moved = True
            if self.config.runner_mode == "TRAIL":
                tp2 = self.cache.order(t.exits["TP2"]) if "TP2" in t.exits else None
                if tp2 is not None and not tp2.is_closed:
                    self.cancel_order(tp2)
                self.stats["runner_trails"] += 1
                self._submit_exit(t, "TRAIL", self.order_factory.trailing_stop_market(
                    instrument_id=self.config.instrument_id, order_side=self._exit_side(t),
                    quantity=Quantity.from_int(t.remaining),
                    trailing_offset=Decimal(f"{self.config.runner_trail_r * t.r_px:.2f}"),
                    trigger_type=TriggerType.BID_ASK,
                    trailing_offset_type=TrailingOffsetType.PRICE,
                    reduce_only=True))

    def _close_at_market(self, t: Trade) -> None:
        self._submit_exit(t, "MKT", self.order_factory.market(
            instrument_id=self.config.instrument_id, order_side=self._exit_side(t),
            quantity=Quantity.from_int(t.remaining), reduce_only=True))

    def _cancel_exits(self, t: Trade) -> None:
        for coid in t.exits.values():
            o = self.cache.order(coid)
            if o is not None and not o.is_closed:
                self.cancel_order(o)

    def _finalize(self, t: Trade) -> None:
        s = t.sign
        pnl = sum(s * (px - t.entry_px) * q for _, _, px, q in t.legs)
        risk_usd = t.qty * t.r_px
        exit_ns = max(ts for _, ts, _, _ in t.legs)
        nights = swap_nights(t.entry_ns, exit_ns)
        swap_usd = nights * SWAP_POINTS_PER_LOT[t.side] * (t.qty / OZ_PER_LOT)
        self.closed.append(dict(
            day=t.day, side="BUY" if s > 0 else "SELL", level_px=t.level_px,
            r_pts=round(t.r_px / POINT, 1), qty=t.qty, spread_at_arm_pts=round(t.spread_pts, 1),
            arm_ns=t.arm_ns, entry_ns=t.entry_ns, entry_px=t.entry_px, exit_ns=exit_ns,
            exit_kind=t.legs[-1][0],
            legs="|".join(f"{k}@{px:.2f}x{q}" for k, _, px, q in t.legs),
            tp1_hit=t.tp1_hit, be_moved=t.be_moved,
            entry_slip_pts=t.entry_slip_pts, max_stop_slip_pts=t.max_stop_slip_pts,
            pnl_usd=round(pnl, 2), pnl_R=pnl / risk_usd if risk_usd else 0.0,
            hold_min=round((exit_ns - t.entry_ns) / 6e10, 2),
            swap_nights=nights, swap_usd_est=round(swap_usd, 2),
        ))
        t.status = "closed"
        for coid in t.exits.values():
            self.by_exit.pop(coid, None)
