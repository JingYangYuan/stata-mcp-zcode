# deploy.ps1 - One-shot deployment of stata-mcp for ZCode on Windows.
#
# What it does:
#   1. Verifies prerequisites (Stata, uv, VS Code)
#   2. Installs the DeepEcon.stata-mcp VS Code extension
#   3. Pre-builds the extension's Python 3.11 venv (the slow first-run step)
#   4. Installs the SessionStart hook script to %USERPROFILE%\.zcode\scripts\
#   5. Merges the stata-mcp MCP server + SessionStart hook into %USERPROFILE%\.zcode\cli\config.json
#      (only touches the "stata-mcp" server entry and the hook; everything else is preserved)
#   6. Starts the server and verifies it is healthy
#
# Usage (PowerShell):
#   powershell -ExecutionPolicy Bypass -File deploy.ps1                          # defaults: E:\Stata18, port 4001
#   powershell -ExecutionPolicy Bypass -File deploy.ps1 -StataPath "D:\Stata21" -Port 4001

param(
    [string]$StataPath = "E:\Stata18",
    [int]$Port = 4001
)

$ErrorActionPreference = "Stop"

function Step($msg) { Write-Host "`n==> $msg" -ForegroundColor Cyan }
function Ok($msg)   { Write-Host "    OK: $msg" -ForegroundColor Green }

# ---------------------------------------------------------------------------
Step "1/6 Checking Stata installation at $StataPath"
$stataExe = Get-ChildItem -Path $StataPath -Filter "*.exe" -ErrorAction SilentlyContinue | Select-Object -First 1
if (-not $stataExe) {
    throw "No Stata executable found in '$StataPath'. Re-run with -StataPath pointing to your Stata 17+ install folder."
}
Ok ("Found " + $stataExe.Name)

# ---------------------------------------------------------------------------
Step "2/6 Checking uv package manager"
$uv = Get-Command uv -ErrorAction SilentlyContinue
if (-not $uv) {
    Write-Host "    uv not found, installing..."
    Invoke-RestMethod https://astral.sh/uv/install.ps1 | Invoke-Expression
    $env:PATH = "$env:USERPROFILE\.local\bin;$env:PATH"
    $uv = Get-Command uv -ErrorAction SilentlyContinue
    if (-not $uv) { throw "uv installation failed. Install it manually: https://docs.astral.sh/uv/" }
}
Ok ("uv " + (& uv --version))

# ---------------------------------------------------------------------------
Step "3/6 Installing VS Code extension DeepEcon.stata-mcp"
$findExt = {
    Get-ChildItem "$env:USERPROFILE\.vscode\extensions" -Directory -Filter "deepecon.stata-mcp-*" |
        Sort-Object { try { [version]($_.Name -replace '^deepecon\.stata-mcp-', '') } catch { [version]'0.0.0' } } -Descending |
        Select-Object -First 1
}
$extDir = & $findExt
if ($extDir) {
    Ok ("Extension already installed at " + $extDir.FullName)
} else {
    $code = Get-Command code -ErrorAction SilentlyContinue
    if (-not $code) {
        $candidate = "$env:LOCALAPPDATA\Programs\Microsoft VS Code\bin\code.cmd"
        if (Test-Path $candidate) { $code = $candidate } else { throw "VS Code CLI not found. Install VS Code first: https://code.visualstudio.com/" }
    }
    & $code --install-extension DeepEcon.stata-mcp 2>$null | Select-Object -Last 1
    Start-Sleep -Seconds 2
    $extDir = & $findExt
    if (-not $extDir) { throw "Extension directory not found after installation." }
    Ok ("Extension installed at " + $extDir.FullName)
}

# ---------------------------------------------------------------------------
Step "4/6 Building extension Python environment (skip if already built)"
$venvDir = Join-Path $extDir.FullName ".venv"
$venvPy  = Join-Path $venvDir "Scripts\python.exe"
if (Test-Path $venvPy) {
    Ok "Python venv already exists, skipping"
} else {
    & uv python install 3.11
    & uv venv $venvDir --python 3.11
    if ($LASTEXITCODE -ne 0) { throw "uv venv failed" }
    & uv pip install --python $venvPy -r (Join-Path $extDir.FullName "src\requirements.txt")
    if ($LASTEXITCODE -ne 0) { throw "uv pip install failed" }
    Ok "Python 3.11 venv created and dependencies installed"
}

# ---------------------------------------------------------------------------
Step "5/6 Installing ZCode hook script and merging configuration"
$zcodeScripts = "$env:USERPROFILE\.zcode\scripts"
New-Item -ItemType Directory -Force -Path $zcodeScripts | Out-Null
$hookScriptPath = Join-Path $zcodeScripts "stata-mcp-start.ps1"

# Copy the hook script from repo assets, patching in the chosen StataPath / Port
$assetScript = Join-Path $PSScriptRoot "assets\stata-mcp-start.ps1"
$content = Get-Content $assetScript -Raw -Encoding UTF8
$content = $content.Replace('$Port      = 4001', ('$Port      = ' + $Port))
$content = $content.Replace('$StataPath = "E:\Stata18"', ('$StataPath = "' + $StataPath + '"'))
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
[System.IO.File]::WriteAllText($hookScriptPath, $content, $utf8NoBom)
Ok ("Hook script written to " + $hookScriptPath)

# Merge into ~/.zcode/cli/config.json without touching unrelated keys (e.g. other servers, API keys)
$configPath = "$env:USERPROFILE\.zcode\cli\config.json"
New-Item -ItemType Directory -Force -Path (Split-Path $configPath) | Out-Null
if (Test-Path $configPath) {
    $config = Get-Content $configPath -Raw -Encoding UTF8 | ConvertFrom-Json
} else {
    $config = New-Object PSObject
}

function Ensure-Prop($obj, $name, $value) {
    if ($obj.PSObject.Properties[$name]) { $obj.$name = $value }
    else { $obj | Add-Member -NotePropertyName $name -NotePropertyValue $value }
}

# MCP server entry
if (-not $config.PSObject.Properties["mcp"]) { $config | Add-Member -NotePropertyName "mcp" -NotePropertyValue (New-Object PSObject) }
if (-not $config.mcp.PSObject.Properties["servers"]) { Ensure-Prop $config.mcp "servers" (New-Object PSObject) }
Ensure-Prop $config.mcp.servers "stata-mcp" ([pscustomobject]@{ type = "http"; url = ("http://localhost:" + $Port + "/mcp-streamable") })

# SessionStart hook
$hookEntry = [pscustomobject]@{
    type          = "process"
    command       = "powershell.exe"
    args          = @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", $hookScriptPath)
    timeoutMs     = 45000
    statusMessage = "Ensure Stata MCP server is running"
}
if (-not $config.PSObject.Properties["hooks"]) {
    Ensure-Prop $config "hooks" ([pscustomobject]@{
        enabled = $true
        events  = [pscustomobject]@{ SessionStart = @([pscustomobject]@{ hooks = @($hookEntry) }) }
    })
} else {
    Ensure-Prop $config.hooks "enabled" $true
    if (-not $config.hooks.PSObject.Properties["events"]) { Ensure-Prop $config.hooks "events" (New-Object PSObject) }
    if (-not $config.hooks.events.PSObject.Properties["SessionStart"]) { Ensure-Prop $config.hooks.events "SessionStart" @() }
    $already = $false
    foreach ($grp in @($config.hooks.events.SessionStart)) {
        foreach ($h in @($grp.hooks)) { if (("$($h.args)" -like "*stata-mcp-start.ps1")) { $already = $true } }
    }
    if (-not $already) {
        $config.hooks.events.SessionStart = @($config.hooks.events.SessionStart) + @([pscustomobject]@{ hooks = @($hookEntry) })
    }
}

[System.IO.File]::WriteAllText($configPath, ($config | ConvertTo-Json -Depth 64), $utf8NoBom)
Ok ("ZCode configuration merged into " + $configPath)

# ---------------------------------------------------------------------------
Step "6/6 Starting server and verifying health"
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $hookScriptPath
if ($LASTEXITCODE -ne 0) { throw "Hook script could not bring the server up. Check log: $env:TEMP\stata-mcp-standalone.log" }
$health = Invoke-WebRequest -Uri ("http://localhost:" + $Port + "/health") -TimeoutSec 5 -UseBasicParsing
Ok ("Server healthy: " + $health.Content.Trim())

Write-Host "`n=============================================" -ForegroundColor Yellow
Write-Host " Deployment complete. Restart ZCode (open a new session) and the stata-mcp tools" -ForegroundColor Yellow
Write-Host " (stata_run_selection / stata_run_file / stata_session) will be available." -ForegroundColor Yellow
Write-Host "=============================================" -ForegroundColor Yellow
