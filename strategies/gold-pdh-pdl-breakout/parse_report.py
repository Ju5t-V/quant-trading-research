"""Parse the MT5 Strategy Tester HTML report and distill the key numbers."""
import io
import re

import pandas as pd

path = r"E:\Documents\Quant Trading\MT5\tester_report_v110.html"
raw = open(path, "rb").read()
for enc in ("utf-16", "utf-8", "cp1252"):
    try:
        html = raw.decode(enc)
        if "<html" in html.lower() or "<table" in html.lower():
            break
    except (UnicodeDecodeError, UnicodeError):
        continue

tables = pd.read_html(io.StringIO(html))
print(f"Tables found: {len(tables)}")

# ---- summary block: first table(s) hold Settings + Results key/value pairs ----
def dump_pairs(df):
    vals = df.values.tolist()
    for row in vals:
        cells = [str(c) for c in row if str(c) != "nan"]
        if len(cells) >= 2:
            print("  " + " | ".join(cells))

print("\n===== SUMMARY / SETTINGS =====")
dump_pairs(tables[0])
if len(tables) > 1 and len(tables[1]) < 80:
    print("\n===== RESULTS =====")
    dump_pairs(tables[1])

# ---- find the deals table (has Time / Deal / Type / Direction / Price columns) ----
deals = None
for t in tables:
    cols = [str(c).lower() for c in (t.iloc[0].tolist() if t.columns.dtype != object else t.columns.tolist())]
    joined = " ".join(cols)
    if "deal" in joined and "direction" in joined:
        deals = t
        break
if deals is None:
    # MT5 reports often put everything in one giant table; find header row inside
    big = max(tables, key=len)
    hdr_idx = None
    for i in range(min(len(big), 2000)):
        rowtxt = " ".join(str(x).lower() for x in big.iloc[i].tolist())
        if "deal" in rowtxt and "direction" in rowtxt:
            hdr_idx = i
            break
    if hdr_idx is not None:
        deals = big.iloc[hdr_idx + 1:].copy()
        deals.columns = [str(x) for x in big.iloc[hdr_idx].tolist()]
print("\n===== DEALS TABLE =====")
if deals is None:
    print("Could not locate deals table; table sizes:", [len(t) for t in tables])
else:
    deals = deals.dropna(how="all")
    print("Columns:", list(deals.columns))
    print("Rows:", len(deals))
    deals.to_csv(r"E:\Documents\Quant Trading\MT5\tester_deals.csv", index=False)
    print(deals.head(12).to_string(index=False))
