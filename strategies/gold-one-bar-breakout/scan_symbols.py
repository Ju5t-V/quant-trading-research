"""Rank MetaQuotes-Demo symbols by daily ATR / spread (vol-to-cost ratio)."""
import MetaTrader5 as mt5
import pandas as pd
import numpy as np

mt5.initialize()
rows = []
for s in mt5.symbols_get():
    name = s.name
    rates = mt5.copy_rates_from_pos(name, mt5.TIMEFRAME_D1, 1, 60)
    if rates is None or len(rates) < 40:
        continue
    df = pd.DataFrame(rates)
    atr = (df["high"] - df["low"]).mean()
    spread_price = s.spread * s.point
    if spread_price <= 0 or atr <= 0:
        continue
    rows.append(dict(sym=name, atr=atr, spread_pts=s.spread,
                     ratio=atr / spread_price,
                     atr_pct=100 * atr / df["close"].iloc[-1]))
out = pd.DataFrame(rows).sort_values("ratio", ascending=False)
print(out.head(25).to_string(index=False, float_format=lambda v: f"{v:.4g}"))
mt5.shutdown()
