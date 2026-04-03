#Requires -Version 5.1
<#
.SYNOPSIS
    Switch Ollama to remote Colab instance via reverse proxy.
.EXAMPLE
    .\switch-to-colab.ps1 https://xxxx.trycloudflare.com
#>
param(
    [Parameter(Mandatory = $true, Position = 0)]
    [string]$Url
)

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

function Stop-ProxyProcess {
    try {
        $procs = Get-CimInstance Win32_Process -ErrorAction Stop |
            Where-Object { $_.Name -like "python*" -and $_.CommandLine -like "*proxy.py*" }
        if ($procs) {
            foreach ($p in $procs) {
                Stop-Process -Id $p.ProcessId -Force -ErrorAction SilentlyContinue
            }
            Write-Host "[OK] Stopped existing proxy.py"
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
}

# ── Validate URL ──────────────────────────────────────────────────────────────

if ($Url -notmatch "^https?://") {
    Write-Host "[ERROR] URL must start with http:// or https://"
    exit 1
}
$Url = $Url.TrimEnd("/")

Write-Log "=== Switching to Colab: $Url ==="

# ── Step 1: Stop local Ollama ─────────────────────────────────────────────────

try {
    # Kill tray app first so it doesn't auto-restart ollama serve
    $trayProcs = Get-Process -Name "ollama app" -ErrorAction SilentlyContinue
    if ($trayProcs) {
        Stop-Process -Name "ollama app" -Force -ErrorAction SilentlyContinue
        Write-Host "[OK] Stopped Ollama tray app (prevents auto-restart)"
    }
    $ollamaProcs = Get-Process -Name "ollama" -ErrorAction SilentlyContinue
    if ($ollamaProcs) {
        Stop-Process -Name "ollama" -Force -ErrorAction Stop
        Start-Sleep -Milliseconds 500  # give it time to release port 11434
        Write-Host "[OK] Stopped local Ollama"
    }
    else {
        Write-Host "[OK] Local Ollama was not running"
    }
}
catch {
    Write-Host "[WARN] Could not stop Ollama: $_"
}

# ── Step 2: Update COLAB_URL in .env ─────────────────────────────────────────

try {
    $envFile = "$PSScriptRoot\.env"
    if (-not (Test-Path $envFile)) {
        "COLAB_URL=$Url" | Out-File -FilePath $envFile -Encoding utf8
        Write-Host "[OK] Created .env with COLAB_URL=$Url"
    }
    else {
        $content = Get-Content $envFile -Raw
        if ($content -match "(?m)^COLAB_URL=") {
            $content = $content -replace "(?m)^COLAB_URL=.*", "COLAB_URL=$Url"
        }
        else {
            $content = $content.TrimEnd() + "`nCOLAB_URL=$Url`n"
        }
        Set-Content -Path $envFile -Value $content -Encoding utf8 -NoNewline
        Write-Host "[OK] Updated .env COLAB_URL=$Url"
    }
}
catch {
    Write-Host "[ERROR] Failed to update .env: $_"
    exit 1
}

# ── Step 3: Kill any existing proxy.py ───────────────────────────────────────

Stop-ProxyProcess

# ── Step 4: Find Python ───────────────────────────────────────────────────────

$pythonExe = $null
foreach ($candidate in @("python", "python3")) {
    $found = Get-Command $candidate -ErrorAction SilentlyContinue
    if ($found) { $pythonExe = $found.Source; break }
}
if (-not $pythonExe) {
    Write-Host "[ERROR] Python not found in PATH. Install Python and ensure it's on PATH."
    exit 1
}
Write-Host "[OK] Using Python: $pythonExe"

# ── Step 5: Start proxy.py ────────────────────────────────────────────────────

try {
    $proxyScript = "$PSScriptRoot\proxy.py"
    if (-not (Test-Path $proxyScript)) {
        Write-Host "[ERROR] proxy.py not found at $proxyScript"
        exit 1
    }
    $proc = Start-Process -FilePath $pythonExe `
        -ArgumentList "`"$proxyScript`"" `
        -WindowStyle Hidden `
        -PassThru `
        -ErrorAction Stop
    Start-Sleep -Milliseconds 800  # brief wait to catch immediate crashes
    if ($proc.HasExited) {
        Write-Host "[ERROR] proxy.py exited immediately (exit code $($proc.ExitCode)). Check proxy.log."
        exit 1
    }
    $proc.Id | Out-File -FilePath "$PSScriptRoot\proxy.pid" -Encoding ascii
    Write-Host "[OK] proxy.py started (PID $($proc.Id))"
}
catch {
    Write-Host "[ERROR] Failed to start proxy.py: $_"
    exit 1
}

# ── Step 6: Toast + summary ───────────────────────────────────────────────────

Send-Toast "Switched to Colab T4"
Write-Log "SWITCH -> colab: $Url (proxy PID $($proc.Id))"

Write-Host ""
Write-Host "Done. Summary:"
Write-Host "  Ollama (local) : stopped"
Write-Host "  proxy.py       : running on 0.0.0.0:11434 -> $Url"
Write-Host "  OpenClaw (manual): go to http://localhost:3000 -> Settings -> Connections -> set Ollama URL to http://localhost:11434"
Write-Host ""
Write-Host "To switch back: .\switch-to-local.ps1"
