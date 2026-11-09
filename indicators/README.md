# Indicators

All the custom MT5 indicators built for this project, collected in one place.
Each subfolder matches the folder they sit in inside MT5 (Navigator → Indicators).

| Folder | Indicator | What it does |
|---|---|---|
| `OrderFlow` | `OF_Heatmap` | Volume heatmap + profile with POC / value area / HVN / LVN |
| `OrderFlow` | `OF_Absorption` | Volume bubbles / absorption annotations (context, not a signal) |
| `OrderFlow` | `OF_Sessions` | See-through Asia / London / NY boxes with each session's high and low |
| `MomoRider` | `MomoRider_Ribbon` | Port of JS Tradventure's Heikin-Ashi EMA ribbon + higher-TF staircase |
| `MomoRider` | `MomoRider_Momentum` | Port of JS Tradventure's momentum oscillator with zones and 4G / 4R signals |
| `MomoRider` | `MIM_GEX` | End-of-day intraday momentum, gated on dealer gamma exposure |

`.mq5` is the source code, `.ex5` the compiled file MT5 runs.

**To reinstall** (new PC or new broker terminal): in MT5 go File → Open Data Folder →
`MQL5\Indicators`, copy a whole subfolder there, then right-click Indicators in Navigator →
Refresh.

**Where the working copies live:** the OrderFlow sources, the `OF_Probe` script and the guides are
in `Futures\MT5_OrderFlow\` — its `README.md` and `TRADING_GUIDE.md` explain how to read each
tool. The MomoRider indicators exist only in MT5 and in this folder. After an indicator is
changed, it is recopied here so this folder stays current.
