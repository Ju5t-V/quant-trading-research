# Runs one MT5 strategy-tester backtest of OneBarBreakoutEA (real ticks).
# Seeds MQL5\Profiles\Tester\OneBarBreakoutEA.set so non-default inputs apply.
param(
    [string]$Tag = "base",
    [string]$Symbol = "XAGUSD",
    [string]$From = "2025.01.01",
    [string]$To = "2026.07.18",
    [string]$SetBody = ""          # extra "Name=Value" lines, semicolon-separated
)
$term = "C:\Program Files\MetaTrader 5\terminal64.exe"
$dd   = "C:\Users\V\AppData\Roaming\MetaQuotes\Terminal\D0E8209F77C8CF37AD8BF550E51FF075"
$base = "E:\Documents\Quant Trading\HighVol_Breakout\tester"
New-Item -ItemType Directory -Force $base | Out-Null

if (Get-Process terminal64 -ErrorAction SilentlyContinue) {
    Write-Output "ERROR: terminal64.exe is running. Close MT5 first."
    exit 1
}

$profileDir = "$dd\MQL5\Profiles\Tester"
New-Item -ItemType Directory -Force $profileDir | Out-Null
$defaults = [ordered]@{
    InpTakeProfitPts="1000.0"; InpStopLossPts="500.0"; InpEntryHour="6"; InpLastEntryHour="24";
    InpEODFlat="true"; InpFlatHour="23"; InpFlatMin="50";
    InpTradeLong="true"; InpTradeShort="false"; InpTrendSmaDays="50"; InpUseTrail="true";
    InpTrailStartPts="300.0"; InpTrailDistPts="150.0"; InpAtrRefPts="14000.0";
    InpAutoLot="true"; InpRiskPercent="2.0"; InpLotSize="0.1";
    InpRecoveryMode="true"; InpRecentTrades="10";
    InpMinSlPts="200.0"; InpMinTpPts="400.0"; InpMinStartPts="150.0"; InpMinDistPts="80.0";
    InpMagicNumber="20260719"
}
if ($SetBody -ne "") {
    foreach ($kv in $SetBody.Split(";")) {
        $p = $kv.Split("="); if ($p.Count -eq 2) { $defaults[$p[0].Trim()] = $p[1].Trim() }
    }
}
$lines = $defaults.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" }
$lines -join "`r`n" | Out-File "$profileDir\OneBarBreakoutEA.set" -Encoding ascii

Remove-Item "$dd\Tester\cache\OneBarBreakoutEA.*" -Force -ErrorAction SilentlyContinue

$runTag = "HVB_$Tag"
$ini = "$base\$runTag.ini"
@"
[Tester]
Expert=OneBarBreakoutEA
Symbol=$Symbol
Period=H1
Model=4
Optimization=0
FromDate=$From
ToDate=$To
Deposit=10000
Currency=USD
Leverage=100
Report=$runTag
ReplaceReport=1
ShutdownTerminal=1
Visual=0
"@ | Out-File -FilePath $ini -Encoding ascii

Write-Output ">>> $runTag $Symbol $From -> $To [$SetBody]"
$p = Start-Process -FilePath $term -ArgumentList "/config:$ini" -PassThru -Wait
Write-Output "    exit $($p.ExitCode)"
foreach ($ext in @("html","htm")) {
    $r = Join-Path $dd "$runTag.$ext"
    if (Test-Path $r) { Copy-Item $r $base -Force; Write-Output "    report -> $base\$runTag.$ext" }
}
