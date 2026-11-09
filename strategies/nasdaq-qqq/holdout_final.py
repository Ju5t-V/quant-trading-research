"""SINGLE-SHOT holdout validation of the declared champion.
Champion (fixed before this run): B=30 opp-stop long-only, trend=prev+ma,
bank half @ +1R (runner stop->BE), runner trailed 0.25xADR, cutoff 22:00.
Holdout: Jan 2025 - Jul 2026 (never used for selection)."""
import sys

import numpy as np
import pandas as pd

sys.stdout.reconfigure(encoding="utf-8", errors="replace")
sys.path.insert(0, r"E:\Documents\Quant Trading\QQQ")
from ablation_round3 import run, dev_days, hold_days  # reuses engine + data

for label, days in [("DEV 2022-07..2024-12", dev_days),
                    ("HOLDOUT 2025-01..2026-07", hold_days),
                    ("FULL PERIOD", dev_days + hold_days)]:
    res = run(days, bankR=1.0, runner="trail25", trendf="prev+ma")
    print(f"{label}: {res}")
