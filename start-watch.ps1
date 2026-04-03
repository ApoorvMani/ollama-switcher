#Requires -Version 5.1
<#
.SYNOPSIS
    Starts watch.ps1 as a hidden background job.
    Prints the schtasks command to add it to Windows startup.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = "Continue"

$pidFile = "$PSScriptRoot\watcher.pid"
$watchScript = "$PSScriptRoot\watch.ps1"

# ── Check for existing watcher ────────────────────────────────────────────────

if (Test-Path $pidFile) {
    $existingId = (Get-Content $pidFile -Raw).Trim()
    if ($existingId) {
        $existingJob = Get-Job -Id $existingId -ErrorAction SilentlyContinue
        if ($existingJob -and $existingJob.State -in @("Running", "NotStarted")) {
            Write-Host "[WARN] Watcher already running as Job ID $existingId."
            Write-Host "       To stop it: Stop-Job $existingId; Remove-Job $existingId"
            Write-Host "       Or delete $pidFile and run this script again."
            exit 0
        }
    }
    # Stale pid file - clean up
    Remove-Item $pidFile -Force -ErrorAction SilentlyContinue
}

# ── Verify watch.ps1 exists ───────────────────────────────────────────────────

if (-not (Test-Path $watchScript)) {
    Write-Host "[ERROR] watch.ps1 not found at $watchScript"
    exit 1
}

# ── Start watcher job ─────────────────────────────────────────────────────────

try {
    $job = Start-Job -ScriptBlock {
        param($script)
        & $script
    } -ArgumentList $watchScript -ErrorAction Stop

    $job.Id | Out-File -FilePath $pidFile -Encoding ascii
    Write-Host "[OK] Watcher started as background job."
    Write-Host "     Job ID  : $($job.Id)"
    Write-Host "     Job Name: $($job.Name)"
    Write-Host ""
    Write-Host "To stop the watcher:"
    Write-Host "     Stop-Job $($job.Id); Remove-Job $($job.Id)"
    Write-Host ""
    Write-Host "To see watcher output:"
    Write-Host "     Receive-Job $($job.Id) -Keep"
}
catch {
    Write-Host "[ERROR] Failed to start watcher job: $_"
    exit 1
}

# ── Print startup registration command (not run automatically) ────────────────

$scriptPath = "$PSScriptRoot\start-watch.ps1"
$schtasksCmd = "schtasks /Create /TN `"OllamaWatcher`" /TR `"powershell.exe -WindowStyle Hidden -NonInteractive -File `\`"$scriptPath`\`"`" /SC ONLOGON /RL HIGHEST /F"

Write-Host ""
Write-Host "─────────────────────────────────────────────────────────"
Write-Host "To add this watcher to Windows startup, run this command:"
Write-Host ""
Write-Host "  $schtasksCmd"
Write-Host ""
Write-Host "To remove the startup task later:"
Write-Host "  schtasks /Delete /TN `"OllamaWatcher`" /F"
Write-Host "─────────────────────────────────────────────────────────"
