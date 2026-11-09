"""Single-shot holdout for the declared gold-lab champion:
Family A, s_atr=0.35, trail 0.15/0.10, bank=False, trend=ma20."""
import sys

sys.stdout.reconfigure(encoding="utf-8", errors="replace")
sys.path.insert(0, r"E:\Documents\Quant Trading\QQQ")
from gold_lab import famA, stats, dev_days, hold_days

for label, days in [("DEV 2022-07..2024-12", dev_days),
                    ("HOLDOUT 2025-01..2026-07", hold_days)]:
    print(label, stats(famA(days, 0.35, 0.15, 0.10, False, "ma20")))
