# Ablation battery for OneBarGoldEA, 2025.01-2026.07 window, real ticks.
$run = "E:\Documents\Quant Trading\OneBar_Gold\tester_run.ps1"
$F = "2025.01.01"; $T = "2026.07.18"
$jobs = @(
    @{Tag="abl_noflat";    Set="InpEODFlat=false"},
    @{Tag="abl_notrail";   Set="InpUseTrail=false"},
    @{Tag="abl_noatr";     Set="InpAtrRefPts=0.0"},
    @{Tag="abl_norecov";   Set="InpRecoveryMode=false"},
    @{Tag="abl_longonly";  Set="InpTradeShort=false"},
    @{Tag="abl_shortonly"; Set="InpTradeLong=false"},
    @{Tag="abl_entry0";    Set="InpEntryHour=0"},
    @{Tag="cand_last18";   Set="InpLastEntryHour=18"},
    @{Tag="cand_last20";   Set="InpLastEntryHour=20"},
    @{Tag="cand_last21";   Set="InpLastEntryHour=21"}
)
foreach ($j in $jobs) {
    powershell -File $run -Tag $j.Tag -From $F -To $T -SetBody $j.Set
}
Write-Output "ALL ABLATION RUNS DONE"
