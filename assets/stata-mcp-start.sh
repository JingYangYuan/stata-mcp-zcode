#!/bin/bash
# ZCode & OMP SessionStart hook: ensure the stata-mcp standalone server is running on the configured port.
# Exits 0 when the server is healthy (already running or started successfully), non-zero on failure.
# Uses --noproxy "*" to prevent 502 errors when terminal proxy environment variables are set.

PORT=4001
STATA_PATH="/Applications/Stata"
LOG_FILE="${TMPDIR:-/tmp}/stata-mcp-standalone.log"
HEALTH_URL="http://127.0.0.1:$PORT/health"

healthy() {
  [ "$(curl --noproxy "*" -s -o /dev/null -m 2 -w '%{http_code}' "$HEALTH_URL" 2>/dev/null)" = "200" ]
}

healthy && exit 0

# Pick the highest installed version of the extension so this survives extension updates
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
[ -n "$EXT_DIR" ] || exit 1

PYTHON="$EXT_DIR/.venv/bin/python"
SERVER="$EXT_DIR/src/stata_mcp_server.py"
[ -x "$PYTHON" ] && [ -f "$SERVER" ] || exit 1

nohup "$PYTHON" "$SERVER" --stata-path "$STATA_PATH" --port "$PORT" --log-file "$LOG_FILE" >/dev/null 2>&1 &
disown

# Wait until healthy so clients can connect right after start
for _ in $(seq 1 120); do
  healthy && exit 0
  sleep 0.8
done
exit 1
