#Requires -Version 5.1
<#
.SYNOPSIS
    Background watcher: pings localhost:11434 every 30s.
    After 3 consecutive failures, auto-switches to local Ollama.
    Runs until killed. Start via start-watch.ps1.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = "Continue"

$POLL_INTERVAL_SEC = 30
$FAIL_THRESHOLD = 3
$TARGET_URL = "http://localhost:11434/api/tags"

# ── Helpers ──────────────────────────────────────────────────────────────────

function Write-Log {
    param([string]$Msg)
    $ts = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $line = "[$ts] $Msg"
    Write-Host $line
    Add-Content -Path "$PSScriptRoot\switcher.log" -Value $line -ErrorAction SilentlyContinue
}

function Send-Toast {
    param([string]$Msg)
    try {
        [Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime] | Out-Null
        [Windows.Data.Xml.Dom.XmlDocument, Windows.Data.Xml.Dom.XmlDocument, ContentType = WindowsRuntime] | Out-Null
        $escaped = [System.Security.SecurityElement]::Escape($Msg)
        $xml = [Windows.Data.Xml.Dom.XmlDocument]::new()
        $xml.LoadXml("<toast><visual><binding template='ToastText01'><text id='1'>$escaped</text></binding></visual></toast>")
        $toast = [Windows.UI.Notifications.ToastNotification]::new($xml)
        [Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier("OllamaSwitcher").Show($toast)
    }
    catch {
        # Toast failure is non-fatal
    }
}

# ── Main loop ─────────────────────────────────────────────────────────────────

Write-Log "Watcher started. Polling $TARGET_URL every ${POLL_INTERVAL_SEC}s (threshold: $FAIL_THRESHOLD failures)"

$failCount = 0

while ($true) {
    try {
        $response = Invoke-WebRequest -Uri $TARGET_URL `
            -TimeoutSec 5 `
            -UseBasicParsing `
            -ErrorAction Stop

        if ($response.StatusCode -eq 200) {
            if ($failCount -gt 0) {
                Write-Log "RECOVER: endpoint back online after $failCount failure(s)"
            }
            $failCount = 0
        }
        else {
            $failCount++
            Write-Log "FAIL ($failCount/$FAIL_THRESHOLD): HTTP $($response.StatusCode) from $TARGET_URL"
        }
    }
    catch {
        $failCount++
        $reason = $_.Exception.Message
        Write-Log "FAIL ($failCount/$FAIL_THRESHOLD): $reason"
    }

    if ($failCount -ge $FAIL_THRESHOLD) {
        Write-Log "AUTO-SWITCH: $failCount consecutive failures -> switching to local"
        try {
            & "$PSScriptRoot\switch-to-local.ps1"
        }
        catch {
            Write-Log "ERROR running switch-to-local.ps1: $_"
        }
        Send-Toast "Auto-switched to local Ollama (remote unreachable)"
        $failCount = 0
    }

    Start-Sleep -Seconds $POLL_INTERVAL_SEC
}
