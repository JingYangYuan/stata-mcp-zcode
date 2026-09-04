# ZCode SessionStart hook: ensure the stata-mcp standalone server is running on the configured port.
# Exits 0 when the server is healthy (already running or started successfully), non-zero on failure.
# Default values below are rewritten by deploy.ps1 when custom -StataPath / -Port are used.

$ErrorActionPreference = "Stop"
$Port      = 4001
$StataPath = "E:\Stata18"
$LogFile   = Join-Path $env:TEMP "stata-mcp-standalone.log"
$HealthUrl = "http://localhost:$Port/health"

function Test-Healthy {
    try {
        $r = Invoke-WebRequest -Uri $HealthUrl -TimeoutSec 2 -UseBasicParsing
        return ($r.StatusCode -eq 200)
    } catch { return $false }
}

if (Test-Healthy) { exit 0 }

# Pick the highest installed version of the extension so this survives extension updates
$extDir = Get-ChildItem "$env:USERPROFILE\.vscode\extensions" -Directory -Filter "deepecon.stata-mcp-*" |
    Sort-Object { try { [version]($_.Name -replace '^deepecon\.stata-mcp-', '') } catch { [version]'0.0.0' } } -Descending |
    Select-Object -First 1
if (-not $extDir) { exit 1 }

$python = Join-Path $extDir.FullName ".venv\Scripts\python.exe"
$server = Join-Path $extDir.FullName "src\stata_mcp_server.py"
if (-not (Test-Path $python) -or -not (Test-Path $server)) { exit 1 }

$serverArgs = "`"$server`" --stata-path `"$StataPath`" --port $Port --log-file `"$LogFile`""
Start-Process -FilePath $python -ArgumentList $serverArgs -WindowStyle Hidden

# Wait until healthy so ZCode can connect right after session start
$deadline = (Get-Date).AddSeconds(25)
while ((Get-Date) -lt $deadline) {
    if (Test-Healthy) { exit 0 }
    Start-Sleep -Milliseconds 800
}
exit 1
