"""Parse OneBarGold MT5 tester reports: summary + inputs + yearly PF from deals."""
import re
import sys
from pathlib import Path
import pandas as pd


def parse(path: Path, show_inputs=False):
    raw = path.read_bytes()
    for enc in ("utf-16", "utf-8", "cp1252"):
        try:
            html = raw.decode(enc)
            break
        except UnicodeError:
            continue
    text = re.sub(r"<[^>]+>", "|", html)
    text = re.sub(r"[\|\s]*\|[\|\s]*", "|", text)

    def grab(label):
        m = re.search(re.escape(label) + r":?\s*\|([^|]+)", text, re.I)
        return m.group(1).strip() if m else None

    print(f"\n=== {path.name} ===")
    for k in ("Total Net Profit", "Profit Factor", "Balance Drawdown Maximal",
              "Equity Drawdown Maximal", "Total Trades",
              "Profit Trades (% of total)", "Expected Payoff", "History Quality"):
        v = grab(k)
        if v:
            print(f"  {k}: {v}")
    if show_inputs:
        m = re.search(r"Inputs:\|(.*?)Company", text, re.S)
        if m:
            print("  inputs:", m.group(1)[:600].replace("|", " "))

    # deals table = last table; positional columns:
    # 0 Time, 1 Deal, 2 Symbol, 3 Type, 4 Direction, 5 Volume, 6 Price,
    # 7 Order, 8 Commission, 9 Swap, 10 Profit, 11 Balance, 12 Comment
    try:
        tables = pd.read_html(path)
        t = tables[-1]
    except Exception as e:
        print("  (deals parse failed:", e, ")")
        return
    df = pd.DataFrame({
        "t": pd.to_datetime(t.iloc[:, 0], errors="coerce"),
        "dir": t.iloc[:, 4].astype(str).str.strip().str.lower(),
        "p": pd.to_numeric(
            t.iloc[:, 10].astype(str).str.replace(r"[^\d\.\-]", "", regex=True),
            errors="coerce"),
    })
    df = df[df["dir"] == "out"].dropna(subset=["t", "p"])
    if len(df) == 0:
        print("  (no out-deals found)")
        return
    df["year"] = df["t"].dt.year
    print("  year   n     sum$      PF")
    for y, g in df.groupby("year"):
        w = g.loc[g["p"] > 0, "p"].sum()
        l = -g.loc[g["p"] <= 0, "p"].sum()
        pf = w / l if l > 0 else float("inf")
        print(f"  {y}  {len(g):4d}  {g['p'].sum():+9.2f}  {pf:6.2f}")


if __name__ == "__main__":
    args = [a for a in sys.argv[1:] if not a.startswith("-")]
    show_inputs = "-i" in sys.argv
    files = [Path(a) for a in args] or sorted(
        Path(r"E:\Documents\Quant Trading\OneBar_Gold\tester").glob("*.htm*"))
    for f in files:
        parse(f, show_inputs)
