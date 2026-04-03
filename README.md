# ollama-switcher

Switches Windows Ollama between local GPU and a remote Google Colab instance via a reverse proxy. Kali Linux VM never needs changes — it always talks to `localhost:11434`.

## How it works

**Colab mode** — `proxy.py` runs on port 11434, forwarding all requests to the Cloudflare tunnel URL. Local Ollama is stopped.

**Local mode** — `proxy.py` is killed, local Ollama serves directly on port 11434.

---

## Daily workflow

### Start a new Colab session
1. Open your Colab notebook and start the Ollama + Cloudflare tunnel cell
2. Copy the tunnel URL (e.g. `https://xxxx.trycloudflare.com`)
3. Run:
   ```powershell
   cd C:\Users\apoor\ollama-switcher
   .\switch-to-colab.ps1 https://xxxx.trycloudflare.com
   ```
4. You'll get a Windows toast and a summary. Done.

### Switch back to local GPU
```powershell
.\switch-to-local.ps1
```

---

## Watcher (auto-fallback)

The watcher pings `localhost:11434` every 30 seconds. If it fails 3 times in a row (~90s), it automatically calls `switch-to-local.ps1` and sends a toast notification.

### Start the watcher
```powershell
.\start-watch.ps1
```
Note the **Job ID** it prints.

### Stop the watcher
```powershell
Stop-Job <id>; Remove-Job <id>
```

### Check watcher output
```powershell
Receive-Job <id> -Keep
```

---

## Add watcher to Windows startup

Run `.\start-watch.ps1` and copy the `schtasks` command it prints at the bottom. Paste it into an elevated PowerShell prompt and run it once.

To remove the startup task:
```powershell
schtasks /Delete /TN "OllamaWatcher" /F
```

---

## Logs

| File | Contents |
|------|----------|
| `switcher.log` | All switch events with timestamps |
| `proxy.log` | Per-request log from proxy.py (method, path, status) |

---

## Troubleshooting

**Execution policy error on first run:**
```powershell
Set-ExecutionPolicy -Scope CurrentUser -ExecutionPolicy RemoteSigned
```

**proxy.py exits immediately:**
Check `proxy.log` for the error. Most likely: port 11434 already in use (local Ollama still running) or Python not in PATH.

**Toast notifications not appearing:**
Focus notifications may be suppressed. Check Windows notification settings. The scripts still work without toasts.

**Watcher not auto-switching:**
Run `Receive-Job <id> -Keep` to see watcher output. Check `switcher.log`.

**Test proxy manually:**
```powershell
# Should return model list from Colab
Invoke-WebRequest http://localhost:11434/api/tags | Select-Object -ExpandProperty Content
```
