# Silver calibration grid (declared, dev window 2025.01-2026.07 only).
# TP = 2*SL, trail start = 2*dist, floors = 40% of each base. ATR ref 3500 pts.
$run = "E:\Documents\Quant Trading\HighVol_Breakout\tester_run.ps1"
$F = "2025.01.01"; $T = "2026.07.18"
foreach ($sl in @(150, 300, 600)) {
    foreach ($dist in @(75, 150, 250)) {
        $tp = 2 * $sl; $start = 2 * $dist
        $set = "InpAtrRefPts=3500.0" +
               ";InpStopLossPts=$sl.0;InpTakeProfitPts=$tp.0" +
               ";InpTrailStartPts=$start.0;InpTrailDistPts=$dist.0" +
               ";InpMinSlPts=$([math]::Round(0.4*$sl,0)).0;InpMinTpPts=$([math]::Round(0.4*$tp,0)).0" +
               ";InpMinStartPts=$([math]::Round(0.4*$start,0)).0;InpMinDistPts=$([math]::Round(0.4*$dist,0)).0"
        powershell -File $run -Tag "cal_s${sl}_d${dist}" -Symbol "XAGUSD" -From $F -To $T -SetBody $set
    }
}
Write-Output "GRID DONE"
