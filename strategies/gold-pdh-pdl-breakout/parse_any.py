"""Distill an MT5 tester report: python parse_any.py <report.html> [deals_out.csv]"""
import re
import sys

import pandas as pd
from bs4 import BeautifulSoup

path = sys.argv[1]
raw = open(path, "rb").read()
if raw[:2] in (b"\xff\xfe", b"\xfe\xff"):
    html = raw.decode("utf-16")
else:
    html = raw.decode("utf-8", errors="replace")

soup = BeautifulSoup(html, "lxml")
tables = soup.find_all("table")
print(f"Tables: {len(tables)}")

# ---- summary: dedupe repeated cells row by row ----
rows_txt = []
for tr in tables[0].find_all("tr"):
    cells = [td.get_text(" ", strip=True) for td in tr.find_all(["td", "th"])]
    uniq = [c for c in dict.fromkeys(cells) if c]
    if uniq:
        rows_txt.append(" | ".join(uniq))
WANT = ("Period:", "Inputs:", "Inp", "History Quality:", "Total Net Profit:",
        "Gross", "Profit Factor:", "Expected Payoff:", "Drawdown Maximal:",
        "Total Trades:", "Total Deals:", "Profit Trades", "Loss Trades",
        "Short Trades", "Long Trades", "Largest", "Average", "holding time",
        "Sharpe", "Recovery")
for r in rows_txt:
    if any(w in r for w in WANT):
        print(r)

# ---- deals table: find the header row ("Deal" + "Direction") in any table ----
data = []
header = None
for t in tables:
    for tr in t.find_all("tr"):
        cells = [td.get_text(" ", strip=True) for td in tr.find_all(["td", "th"])]
        if not cells:
            continue
        low = [c.lower() for c in cells]
        if header is None:
            if "deal" in low and "direction" in low:
                header = cells
            continue
        if len(cells) == len(header):
            data.append(cells)
    if header:
        break
if header:
    df = pd.DataFrame(data, columns=header)
    print(f"\nDeal rows: {len(df)}")
    if len(sys.argv) > 2:
        df.to_csv(sys.argv[2], index=False)
        print("Deals saved:", sys.argv[2])
else:
    print("\nNo deals table found")
