#!/usr/bin/env bash
# Spec §18 compatibility: sanity-check handshake output expected by Inspector clients.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/mcp-inspector.XXXXXX")"
cleanup() {
	if [ -n "${TMP_ROOT:-}" ] && [ -d "${TMP_ROOT}" ]; then
		rm -rf "${TMP_ROOT}"
	fi
}
trap cleanup EXIT

stage_workspace() {
	local dest="$1"
	mkdir -p "${dest}"
	cp -a "${REPO_ROOT}/bin" "${dest}/"
	cp -a "${REPO_ROOT}/lib" "${dest}/"
	cp -a "${REPO_ROOT}/handlers" "${dest}/"
	cp -a "${REPO_ROOT}/providers" "${dest}/"
	cp -a "${REPO_ROOT}/sdk" "${dest}/"
}

WORKSPACE="${TMP_ROOT}/workspace"
stage_workspace "${WORKSPACE}"
export WORKSPACE

python3 <<'PY'
import json
import os
import subprocess
import sys
import time

workspace = os.environ["WORKSPACE"]
proc = subprocess.Popen(
    ["./bin/mcp-bash"],
    cwd=workspace,
    stdin=subprocess.PIPE,
    stdout=subprocess.PIPE,
    stderr=subprocess.PIPE,
    text=True,
)

def send(obj):
    line = json.dumps(obj, separators=(",", ":")) + "\n"
    proc.stdin.write(line)
    proc.stdin.flush()

def next_message(deadline):
    while True:
        if time.time() > deadline:
            raise SystemExit("timeout waiting for server output")
        line = proc.stdout.readline()
        if not line:
            raise SystemExit("server exited unexpectedly")
        line = line.strip()
        if not line:
            continue
        return json.loads(line)

def recv_expected(expected_id, deadline, allow_eof=False):
    while True:
        try:
            msg = next_message(deadline)
        except SystemExit as exc:
            if allow_eof and "server exited unexpectedly" in str(exc):
                return None
            raise
        if msg.get("id") == expected_id:
            return msg

send({"jsonrpc": "2.0", "id": "init", "method": "initialize", "params": {}})
msg = recv_expected("init", time.time() + 5)
result = msg.get("result") or {}
if result.get("protocolVersion") != "2025-06-18":
    raise SystemExit("unexpected protocolVersion")
caps = result.get("capabilities") or {}
for key in ("logging", "tools", "resources", "prompts", "completion"):
    if key not in caps:
        raise SystemExit(f"missing capability {key}")

send({"jsonrpc": "2.0", "method": "notifications/initialized"})
send({"jsonrpc": "2.0", "id": "shutdown", "method": "shutdown"})
shutdown = recv_expected("shutdown", time.time() + 5)
if shutdown.get("result") != {}:
    raise SystemExit("shutdown acknowledgement missing")

send({"jsonrpc": "2.0", "id": "exit", "method": "exit"})
exit_msg = recv_expected("exit", time.time() + 5, allow_eof=True)
if exit_msg is not None and exit_msg.get("result") != {}:
    raise SystemExit("exit acknowledgement missing")

proc.stdin.close()
try:
    proc.wait(timeout=2)
except subprocess.TimeoutExpired:
    proc.kill()
    proc.wait()

if proc.returncode not in (0, None):
    sys.stderr.write(proc.stderr.read())
    raise SystemExit(f"mcp-bash exited with {proc.returncode}")
PY
