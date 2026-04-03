#Requires -Version 5.1
<#
.SYNOPSIS
    Switch Ollama back to local instance (kills proxy, starts local Ollama).
.EXAMPLE
    .\switch-to-local.ps1
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = "Continue"

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
        Write-Host "[WARN] Toast failed: $_"
    }
}

# ── Main ──────────────────────────────────────────────────────────────────────

Write-Log "=== Switching to local Ollama ==="

# Step 1: Kill proxy.py
try {
    $procs = Get-CimInstance Win32_Process -ErrorAction Stop |
        Where-Object { $_.Name -like "python*" -and $_.CommandLine -like "*proxy.py*" }
    if ($procs) {
        foreach ($p in $procs) {
            Stop-Process -Id $p.ProcessId -Force -ErrorAction SilentlyContinue
        }
        Write-Host "[OK] Stopped proxy.py"
    }
    else {
        Write-Host "[OK] proxy.py was not running"
    }
    $pidFile = "$PSScriptRoot\proxy.pid"
    if (Test-Path $pidFile) { Remove-Item $pidFile -Force -ErrorAction SilentlyContinue }
}
catch {
    Write-Host "[WARN] Error stopping proxy: $_"
}

# Step 2: Start local Ollama (if not already running)
try {
    $existing = Get-Process -Name "ollama" -ErrorAction SilentlyContinue
    if ($existing) {
        Write-Host "[OK] Local Ollama already running (PID $($existing.Id))"
    }
    else {
        $ollamaCmd = Get-Command ollama -ErrorAction SilentlyContinue
        if (-not $ollamaCmd) {
            Write-Host "[ERROR] 'ollama' not found in PATH. Is Ollama installed?"
            exit 1
        }
        Start-Process -FilePath $ollamaCmd.Source `
            -ArgumentList "serve" `
            -WindowStyle Hidden `
            -ErrorAction Stop
        Start-Sleep -Milliseconds 1000
        $started = Get-Process -Name "ollama" -ErrorAction SilentlyContinue
        if ($started) {
            Write-Host "[OK] Started local Ollama (PID $($started.Id))"
        }
        else {
            Write-Host "[WARN] Ollama may have started but process not visible yet"
        }
    }
}
catch {
    Write-Host "[ERROR] Failed to start local Ollama: $_"
    exit 1
}

# Step 3: Toast + summary
Send-Toast "Switched to local Ollama"
Write-Log "SWITCH -> local"

Write-Host ""
Write-Host "Done. Local Ollama is serving on 0.0.0.0:11434."
Write-Host "  OpenClaw (manual): go to http://localhost:3000 -> Settings -> Connections -> confirm Ollama URL is http://localhost:11434"
