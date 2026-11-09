# Runs MT5 strategy-tester backtests for AOI_MeanReversionEA (Asia config = EA defaults).
# PRECONDITION: the MT5 terminal must be CLOSED (one instance per install).
# Usage:  powershell -File tester_run.ps1            (3 validation pairs, H2, 1-min OHLC)
#         powershell -File tester_run.ps1 -Pairs EURUSD -Model 4   (real ticks, one pair)
param(
    [string[]]$Pairs = @("EURUSD","AUDCHF","GBPAUD"),
    [string]$TF = "H2",
    [int]$Model = 1,               # 0=every tick 1=1-min OHLC 2=open prices 4=real ticks
    [string]$From = "2016.01.01",
    [string]$To = "2026.06.01"
)
$term = "C:\Program Files\MetaTrader 5\terminal64.exe"
$base = "E:\Documents\Quant Trading\AOI_MeanReversion\tester"
New-Item -ItemType Directory -Force $base | Out-Null

if (Get-Process terminal64 -ErrorAction SilentlyContinue) {
    Write-Output "ERROR: terminal64.exe is running. Close MT5 first (gold EA keeps server-side SL/TP)."
    exit 1
}

foreach ($sym in $Pairs) {
    $tag = "AOI_${sym}_${TF}_m$Model"
    $ini = "$base\$tag.ini"
    @"
[Tester]
Expert=AOI_MeanReversionEA
Symbol=$sym
Period=$TF
Model=$Model
Optimization=0
FromDate=$From
ToDate=$To
Deposit=10000
Currency=USD
Leverage=100
Report=$tag
ReplaceReport=1
ShutdownTerminal=1
Visual=0
"@ | Out-File -FilePath $ini -Encoding ascii
    Write-Output ">>> $sym $TF model=$Model ..."
    $p = Start-Process -FilePath $term -ArgumentList "/config:$ini" -PassThru -Wait
    Write-Output "    exit $($p.ExitCode)"
    # collect the report from the terminal data dir
    $dd = "C:\Users\V\AppData\Roaming\MetaQuotes\Terminal\D0E8209F77C8CF37AD8BF550E51FF075"
    foreach ($ext in @("html","htm")) {
        $r = Join-Path $dd "$tag.$ext"
        if (Test-Path $r) { Copy-Item $r $base -Force; Write-Output "    report -> $base\$tag.$ext" }
    }
}
Write-Output "done. Reports in $base"
