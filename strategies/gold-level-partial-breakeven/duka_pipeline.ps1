# Dukascopy holdout data: convert -> clean -> bars -> verify, one after another.
# Runs detached so tool timeouts cannot kill it; stops at the first failing step.
#   powershell -NoProfile -ExecutionPolicy Bypass -File duka_pipeline.ps1
$root = "E:\Documents\Quant Trading\Gold_PartialBE"
$py = "C:\Users\V\Nautilus trading\.venv\Scripts\python.exe"
$log = "$root\results\logs\duka_pipeline.log"
Set-Location $root
"pipeline started $(Get-Date -Format s)" | Out-File $log -Encoding utf8

$steps = @(
    @("convert", "-u export_dukascopy.py convert"),
    @("clean",   "-u clean_ticks.py --feed duka"),
    @("bars",    "-u export_dukascopy.py bars"),
    @("verify",  "-u -W ignore verify_duka.py")
)
foreach ($s in $steps) {
    $name = $s[0]
    "=== STEP $name started $(Get-Date -Format s)" | Out-File $log -Append -Encoding utf8
    $out = "$root\results\logs\duka_$name.out"
    $err = "$root\results\logs\duka_$name.err"
    $p = Start-Process -FilePath $py -ArgumentList $s[1] -WorkingDirectory $root `
        -RedirectStandardOutput $out -RedirectStandardError $err -WindowStyle Hidden -PassThru -Wait
    Get-Content $out | Out-File $log -Append -Encoding utf8
    if ($p.ExitCode -ne 0) {
        "=== STEP $name FAILED exit $($p.ExitCode) $(Get-Date -Format s)" | Out-File $log -Append -Encoding utf8
        Get-Content $err -Tail 20 | Out-File $log -Append -Encoding utf8
        exit 1
    }
    "=== STEP $name done $(Get-Date -Format s)" | Out-File $log -Append -Encoding utf8
}
"PIPELINE DONE $(Get-Date -Format s)" | Out-File $log -Append -Encoding utf8
