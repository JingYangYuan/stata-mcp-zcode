#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
stata-mcp stdio bridge for Oh My Pi, Claude Code, Codex, and ZCode.
Bypasses local/global HTTP proxy variables by communicating with Stata MCP server directly.
Auto-starts the standalone server if it is not running.
"""

import sys
import json
import time
import os
import subprocess
import glob
import httpx

PORT = 4001
BASE_URL = f"http://127.0.0.1:{PORT}"
STREAM_URL = f"{BASE_URL}/mcp-streamable"
HEALTH_URL = f"{BASE_URL}/health"


def find_extension_python():
    """Locate the Python executable in the installed DeepEcon.stata-mcp extension."""
    ext_dirs = sorted(
        glob.glob(os.path.expanduser("~/.vscode/extensions/deepecon.stata-mcp-*")),
        reverse=True,
    )
    for d in ext_dirs:
        py = os.path.join(d, ".venv", "bin", "python")
        if os.path.isfile(py) and os.access(py, os.X_OK):
            return py
        py_win = os.path.join(d, ".venv", "Scripts", "python.exe")
        if os.path.isfile(py_win) and os.access(py_win, os.X_OK):
            return py_win
    return sys.executable


def ensure_server():
    """Verify Stata MCP server is healthy; start it if necessary."""
    client = httpx.Client(trust_env=False, timeout=2.0)
    try:
        r = client.get(HEALTH_URL)
        if r.status_code == 200:
            return True
    except Exception:
        pass

    # Attempt to start via shell hook script or direct launch
    start_script = os.path.expanduser("~/.zcode/scripts/stata-mcp-start.sh")
    if os.path.exists(start_script):
        try:
            subprocess.Popen(
                ["/bin/bash", start_script],
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
                start_new_session=True,
            )
        except Exception:
            pass

    for _ in range(60):
        time.sleep(0.5)
        try:
            r = client.get(HEALTH_URL)
            if r.status_code == 200:
                return True
        except Exception:
            pass

    return False


def main():
    if not ensure_server():
        sys.stderr.write("stata-mcp: Failed to connect to or start Stata MCP server on port 4001\n")
        sys.stderr.flush()
        sys.exit(1)

    client = httpx.Client(trust_env=False, timeout=600.0)
    session_id = None

    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        try:
            req = json.loads(line)
        except Exception as e:
            sys.stderr.write(f"stata-mcp: Invalid JSON received: {e}\n")
            continue

        req_id = req.get("id")
        headers = {
            "Accept": "application/json, text/event-stream",
            "Content-Type": "application/json",
        }
        if session_id:
            headers["mcp-session-id"] = session_id

        try:
            resp = client.post(STREAM_URL, content=line, headers=headers)
            new_sid = resp.headers.get("mcp-session-id")
            if new_sid:
                session_id = new_sid

            content_type = resp.headers.get("content-type", "")
            if "text/event-stream" in content_type:
                for chunk in resp.iter_lines():
                    if chunk.startswith("data:"):
                        payload = chunk[5:].strip()
                        if payload:
                            sys.stdout.write(payload + "\n")
                            sys.stdout.flush()
            elif "application/json" in content_type:
                body = resp.text.strip()
                if body:
                    sys.stdout.write(body + "\n")
                    sys.stdout.flush()
        except Exception as e:
            sys.stderr.write(f"stata-mcp: Error forwarding request: {e}\n")
            if req_id is not None:
                err_resp = {
                    "jsonrpc": "2.0",
                    "id": req_id,
                    "error": {"code": -32603, "message": str(e)},
                }
                sys.stdout.write(json.dumps(err_resp) + "\n")
                sys.stdout.flush()


if __name__ == "__main__":
    main()
