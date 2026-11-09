"""Extract every XAUUSD signal from the Smith Trades Gold Telegram export."""
import json
import re
import sys
from datetime import datetime, timezone

sys.stdout.reconfigure(encoding="utf-8", errors="replace")

PATH = r"E:\Downloads\Telegram Desktop\ChatExport_2026-07-17\result.json"
data = json.load(open(PATH, encoding="utf-8"))
msgs = data["messages"]
print(f"channel: {data.get('name')}")
print(f"total messages: {len(msgs)}")


def get_text(m):
    t = m.get("text", "")
    if isinstance(t, str):
        return t
    # list of parts (strings or {type,text})
    out = []
    for p in t:
        out.append(p if isinstance(p, str) else p.get("text", ""))
    return "".join(out)


num = r"([0-9]{3,5}(?:\.[0-9]+)?)"
rows = []
for m in msgs:
    if m.get("type") != "message":
        continue
    txt = get_text(m)
    if "XAUUSD" not in txt.upper() and "GOLD" not in txt.upper():
        continue
    low = txt.lower()
    if "buy" in low and "sell" not in low:
        d = 1
    elif "sell" in low and "buy" not in low:
        d = -1
    else:
        continue
    em = re.search(r"entry[^0-9]*" + num, low)
    sm = re.search(r"stop\s*loss[^0-9]*" + num, low)
    if not em or not sm:
        continue
    entry = float(em.group(1))
    sl = float(sm.group(1))
    tps = []
    for tpm in re.finditer(r"tp\s*\d[^0-9a-z]*(" + num + r"|open)", low):
        v = tpm.group(1)
        tps.append(None if v.startswith("open") else float(v))
    if len(tps) == 0:
        continue
    ts = int(m["date_unixtime"])
    rows.append({"id": m["id"], "utc": ts,
                 "dt": datetime.fromtimestamp(ts, timezone.utc).strftime("%Y-%m-%d %H:%M"),
                 "dir": d, "entry": entry, "sl": sl, "tps": tps})

print(f"\nsignals parsed: {len(rows)}")
if rows:
    print(f"date range: {rows[0]['dt']}  ..  {rows[-1]['dt']}")
    buys = sum(1 for r in rows if r["dir"] == 1)
    print(f"buys: {buys} | sells: {len(rows) - buys}")
    # by year
    from collections import Counter
    yr = Counter(r["dt"][:4] for r in rows)
    print("by year:", dict(sorted(yr.items())))
    print("\nfirst 3 and last 3 signals:")
    for r in rows[:3] + rows[-3:]:
        print(f"  {r['dt']} {'BUY ' if r['dir']==1 else 'SELL'} entry {r['entry']} SL {r['sl']} TPs {r['tps']}")

json.dump(rows, open(r"E:\Documents\Quant Trading\MT5\smith_signals.json", "w"))
print("\nsaved -> smith_signals.json")
