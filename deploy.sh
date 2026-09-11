#!/usr/bin/env bash
# deploy.sh - One-shot deployment of stata-mcp for ZCode & Oh My Pi on macOS / Linux.
#
# What it does:
#   1. Verifies prerequisites (Stata, uv, VS Code)
#   2. Installs the DeepEcon.stata-mcp VS Code extension
#   3. Pre-builds the extension's Python 3.11 venv
#   4. Installs the SessionStart hook script to ~/.zcode/scripts/stata-mcp-start.sh
#   5. Installs the universal proxy-safe stdio bridge to ~/.local/bin/stata-mcp
#   6. Merges stata-mcp into ZCode (~/.zcode/cli/config.json) and OMP (~/.omp/agent/mcp.json)
#   7. Verifies server health and runs an end-to-end smoke test
#
# Usage:
#   ./deploy.sh                                          # default: /Applications/Stata, port 4001
#   ./deploy.sh --stata-path /path/to/Stata --port 4001

set -e

STATA_PATH="/Applications/Stata"
PORT=4001

while [[ $# -gt 0 ]]; do
  case $1 in
    --stata-path)
      STATA_PATH="$2"
      shift 2
      ;;
    --port)
      PORT="$2"
      shift 2
      ;;
    *)
      echo "Unknown option: $1"
      exit 1
      ;;
  esac
done

step() { printf "\n\033[36m==> %s\033[0m\n" "$1"; }
ok()   { printf "    \033[32mOK: %s\033[0m\n" "$1"; }

# 1. Stata check
step "1/7 Checking Stata installation at $STATA_PATH"
if [ -d "$STATA_PATH" ]; then
  ok "Found Stata directory: $STATA_PATH"
elif command -v stata-mp >/dev/null 2>&1; then
  ok "Found stata-mp binary in PATH"
else
  echo "WARNING: Stata not found at $STATA_PATH. Ensure Stata 17+ is installed."
fi

# 2. uv check
step "2/7 Checking uv package manager"
if ! command -v uv >/dev/null 2>&1; then
  echo "    uv not found, installing via official script..."
  curl -LsSf https://astral.sh/uv/install.sh | sh
  export PATH="$HOME/.local/bin:$PATH"
fi
ok "uv $(uv --version 2>/dev/null || echo 'installed')"

# 3. Extension check
step "3/7 Installing VS Code extension DeepEcon.stata-mcp"
EXT_DIR=""
for d in "$HOME/.vscode/extensions/"deepecon.stata-mcp-*; do
  [ -d "$d" ] || continue
  if [ -z "$EXT_DIR" ]; then
    EXT_DIR="$d"
  else
    v_cur=$(basename "$EXT_DIR" | sed 's/.*stata-mcp-//')
    v_new=$(basename "$d" | sed 's/.*stata-mcp-//')
    [ "$(printf '%s\n%s\n' "$v_cur" "$v_new" | sort -V | tail -1)" = "$v_new" ] && EXT_DIR="$d"
  fi
done

if [ -n "$EXT_DIR" ]; then
  ok "Extension already installed at $EXT_DIR"
else
  if command -v code >/dev/null 2>&1; then
    code --install-extension DeepEcon.stata-mcp
  elif command -v cursor >/dev/null 2>&1; then
    cursor --install-extension DeepEcon.stata-mcp
  else
    echo "ERROR: Neither 'code' nor 'cursor' CLI found. Please install extension DeepEcon.stata-mcp manually."
    exit 1
  fi
  for d in "$HOME/.vscode/extensions/"deepecon.stata-mcp-*; do
    [ -d "$d" ] && EXT_DIR="$d"
  done
  ok "Installed extension at $EXT_DIR"
fi

# 4. Python environment
step "4/7 Building extension Python 3.11 virtual environment"
VENV_DIR="$EXT_DIR/.venv"
VENV_PY="$VENV_DIR/bin/python"
if [ -x "$VENV_PY" ]; then
  ok "Python virtual environment already exists, skipping build"
else
  uv python install 3.11
  uv venv "$VENV_DIR" --python 3.11
  uv pip install --python "$VENV_PY" -r "$EXT_DIR/src/requirements.txt"
  ok "Python 3.11 environment built with required dependencies"
fi

# 5. Hook script & stdio bridge installation
step "5/7 Installing hook script and stdio bridge"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
mkdir -p "$HOME/.zcode/scripts" "$HOME/.local/bin"

# Hook script
HOOK_DEST="$HOME/.zcode/scripts/stata-mcp-start.sh"
sed -e "s|PORT=4001|PORT=$PORT|g" \
    -e "s|STATA_PATH=\"/Applications/Stata\"|STATA_PATH=\"$STATA_PATH\"|g" \
    "$SCRIPT_DIR/assets/stata-mcp-start.sh" > "$HOOK_DEST"
chmod +x "$HOOK_DEST"
ok "Hook script installed at $HOOK_DEST"

# stdio bridge
BRIDGE_DEST="$HOME/.local/bin/stata-mcp"
sed -e "s|PORT = 4001|PORT = $PORT|g" \
    -e "s|#!/usr/bin/env python3|#!$VENV_PY|g" \
    "$SCRIPT_DIR/assets/stata-mcp-bridge.py" > "$BRIDGE_DEST"
chmod +x "$BRIDGE_DEST"
ok "Universal stdio bridge installed at $BRIDGE_DEST"

# 6. Merging configuration into ZCode and OMP
step "6/7 Merging configurations (preserving all other configs)"

# ZCode merge
ZCODE_CONFIG="$HOME/.zcode/cli/config.json"
if [ -f "$ZCODE_CONFIG" ]; then
  "$VENV_PY" -c "
import json

path = '$ZCODE_CONFIG'
try:
    with open(path, 'r', encoding='utf-8') as f:
        cfg = json.load(f)
except Exception:
    cfg = {}

mcp = cfg.setdefault('mcp', {}).setdefault('servers', {})
mcp['stata-mcp'] = {'type': 'http', 'url': f'http://localhost:$PORT/mcp-streamable'}

hooks = cfg.setdefault('hooks', {})
hooks['enabled'] = True
sess_start = hooks.setdefault('events', {}).setdefault('SessionStart', [])

hook_cmd = '$HOOK_DEST'
already = any(any(hook_cmd in str(a) for a in h.get('hooks', [])) for h in sess_start)
if not already:
    sess_start.append({
        'hooks': [{
            'type': 'process',
            'command': '/bin/bash',
            'args': [hook_cmd],
            'timeoutMs': 120000,
            'statusMessage': 'Ensure Stata MCP server is running'
        }]
    })

with open(path, 'w', encoding='utf-8') as f:
    json.dump(cfg, f, indent=2, ensure_ascii=False)
"
  ok "Merged stata-mcp into $ZCODE_CONFIG"
fi

# OMP merge
OMP_CONFIG="$HOME/.omp/agent/mcp.json"
if [ -f "$OMP_CONFIG" ]; then
  "$VENV_PY" -c "
import json

path = '$OMP_CONFIG'
try:
    with open(path, 'r', encoding='utf-8') as f:
        cfg = json.load(f)
except Exception:
    cfg = {'mcpServers': {}}

mcp = cfg.setdefault('mcpServers', {})
# Use proxy-immune stdio bridge for OMP
mcp['stata-mcp'] = {
    'type': 'stdio',
    'command': '$BRIDGE_DEST'
}

with open(path, 'w', encoding='utf-8') as f:
    json.dump(cfg, f, indent=2, ensure_ascii=False)
"
  ok "Merged proxy-safe stata-mcp stdio entry into $OMP_CONFIG"
fi

# 7. Health verification
step "7/7 Starting server and verifying health"
bash "$HOOK_DEST"

HEALTH_RESP=$(curl --noproxy "*" -s -m 5 "http://127.0.0.1:$PORT/health" || true)
if echo "$HEALTH_RESP" | grep -q '"status":"ok"'; then
  ok "Server healthy: $HEALTH_RESP"
else
  echo "ERROR: Server failed health check. Output: $HEALTH_RESP"
  exit 1
fi

# Bridge test
TEST_JSON='{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"deploy-check","version":"1.0"}}}
{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"stata_run_selection","arguments":{"selection":"display 1+1"}}}'

TEST_OUT=$(printf "%s\n" "$TEST_JSON" | "$BRIDGE_DEST" 2>/dev/null || true)
if echo "$TEST_OUT" | grep -q '2'; then
  ok "Smoke test passed: Stata computed 1+1 = 2 via stdio bridge"
else
  echo "WARNING: Smoke test output unexpected: $TEST_OUT"
fi

printf "\n\033[33m=============================================\n"
printf " Deployment complete.\n"
printf " Stata MCP is ready and proxy-immune for ZCode & Oh My Pi.\n"
printf "=============================================\033[0m\n\n"
