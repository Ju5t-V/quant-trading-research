"""Parse MT5 tester HTML report(s): summary stats + deal list -> comparison vs Python engine."""
import re
import sys
from pathlib import Path

import pandas as pd

TESTER = Path(r"E:\Documents\Quant Trading\AOI_MeanReversion\tester")


def parse(path: Path):
    raw = path.read_bytes()
    for enc in ("utf-16", "utf-8", "cp1252"):
        try:
            html = raw.decode(enc)
            break
        except UnicodeError:
            continue
    text = re.sub(r"<[^>]+>", "|", html)
    text = re.sub(r"\|+", "|", text)

    def grab(label):
        m = re.search(re.escape(label) + r":?\|([^|]+)", text)
        return m.group(1).strip() if m else None

    fields = {k: grab(k) for k in (
        "Total Net Profit", "Profit Factor", "Balance Drawdown Maximal",
        "Total Trades", "Profit Trades (% of total)", "Loss Trades (% of total)",
        "Expected Payoff", "Recovery Factor", "Sharpe Ratio", "History Quality")}
    try:
        tables = pd.read_html(path)
        deals = next((t for t in tables if "Profit" in "".join(map(str, t.columns))), None)
    except Exception:
        deals = None
    return fields, deals


if __name__ == "__main__":
    files = [Path(a) for a in sys.argv[1:]] or sorted(TESTER.glob("*.htm*"))
    for f in files:
        fields, deals = parse(f)
        print(f"\n=== {f.name} ===")
        for k, v in fields.items():
            if v:
                print(f"  {k}: {v}")
        if deals is not None:
            print(f"  deals table: {len(deals)} rows")
