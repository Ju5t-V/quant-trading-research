# Wait for a running process (e.g. the previous backtest queue) to exit, then start
# the next job file with run_queue.py. Runs detached so tool timeouts cannot kill it.
#   powershell -NoProfile -ExecutionPolicy Bypass -File chain_queue.ps1 -WaitPid 19728 `
#       -JobFile results\queue_stage2a.txt -Parallel 3 -LogName queue_stage2a
param(
    [int]$WaitPid = 0,
    [Parameter(Mandatory = $true)][string]$JobFile,
    [int]$Parallel = 3,
    [Parameter(Mandatory = $true)][string]$LogName
)
$root = "E:\Documents\Quant Trading\Gold_PartialBE"
$py = "C:\Users\V\Nautilus trading\.venv\Scripts\python.exe"
$chainLog = "$root\results\logs\$LogName.chain"

if ($WaitPid -gt 0) {
    "waiting for pid $WaitPid since $(Get-Date -Format s)" | Out-File $chainLog -Encoding utf8
    while (Get-Process -Id $WaitPid -ErrorAction SilentlyContinue) { Start-Sleep -Seconds 20 }
}
"starting $JobFile with $Parallel parallel at $(Get-Date -Format s)" | Out-File $chainLog -Append -Encoding utf8
Start-Process -FilePath $py -ArgumentList "-u run_queue.py $Parallel $JobFile" -WorkingDirectory $root `
    -RedirectStandardOutput "$root\results\logs\$LogName.out" `
    -RedirectStandardError "$root\results\logs\$LogName.err" -WindowStyle Hidden -Wait
"finished $JobFile at $(Get-Date -Format s)" | Out-File $chainLog -Append -Encoding utf8
