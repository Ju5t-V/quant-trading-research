"""Rank curated high-liquidity symbols by daily ATR / spread (vol-to-cost)."""
import MetaTrader5 as mt5
import pandas as pd

CANDIDATES = [
    "EURUSD", "GBPUSD", "USDJPY", "AUDUSD", "USDCAD", "USDCHF", "NZDUSD",
    "GBPJPY", "EURJPY", "AUDJPY", "CHFJPY", "CADJPY", "NZDJPY",
    "EURGBP", "EURAUD", "GBPAUD", "GBPCAD", "GBPNZD", "EURNZD", "EURCAD",
    "XAUUSD", "XAGUSD", "XPTUSD", "XPDUSD",
    "USDMXN", "USDZAR", "USDTRY", "USDSEK", "USDNOK",
]

mt5.initialize()
rows = []
for name in CANDIDATES:
    if not mt5.symbol_select(name, True):
        print(f"-- {name}: not available")
        continue
    s = mt5.symbol_info(name)
    rates = mt5.copy_rates_from_pos(name, mt5.TIMEFRAME_D1, 1, 60)
    if rates is None or len(rates) < 40:
        print(f"-- {name}: no D1 history")
        continue
    df = pd.DataFrame(rates)
    atr = (df["high"] - df["low"]).mean()
    spread_price = s.spread * s.point
    if spread_price <= 0 or atr <= 0:
        continue
    rows.append(dict(sym=name, atr=round(atr, 5), spread_pts=s.spread,
                     ratio=atr / spread_price,
                     atr_pct=100 * atr / df["close"].iloc[-1]))
out = pd.DataFrame(rows).sort_values("ratio", ascending=False)
print(out.to_string(index=False, float_format=lambda v: f"{v:.4g}"))
mt5.shutdown()
