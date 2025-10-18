#!/usr/bin/env bash
# Spec §18 stress: ensure stdout guard stays quiet during rapid ping traffic.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/mcp-guard.XXXXXX")"
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

# isolate state artifacts under a temp TMPDIR
export TMPDIR="${TMP_ROOT}/tmpdir"
mkdir -p "${TMPDIR}"

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

def recv(deadline, expect_id=None, allow_eof=False):
    while True:
        if time.time() > deadline:
            raise SystemExit("timeout waiting for server output")
        line = proc.stdout.readline()
        if not line:
            if allow_eof:
                return None
            raise SystemExit("server exited unexpectedly")
        line = line.strip()
        if not line:
            continue
        msg = json.loads(line)
        if expect_id is None or msg.get("id") == expect_id:
            return msg

send({"jsonrpc": "2.0", "id": "init", "method": "initialize", "params": {}})
recv(time.time() + 5, "init")
send({"jsonrpc": "2.0", "method": "notifications/initialized"})

for idx in range(10):
    send({"jsonrpc": "2.0", "id": f"ping-{idx}", "method": "ping"})
for idx in range(10):
    recv(time.time() + 5, f"ping-{idx}")

tmpdir = os.environ["TMPDIR"]
state_dir = None
for entry in os.listdir(tmpdir):
    candidate = os.path.join(tmpdir, entry)
    if entry.startswith("mcpbash.state.") and os.path.isdir(candidate):
        state_dir = candidate
if state_dir is None:
    raise SystemExit("no state directory captured for guard verification")
guard_log = os.path.join(state_dir, "stdout_corruption.log")
if os.path.exists(guard_log) and os.path.getsize(guard_log) > 0:
    with open(guard_log, "r", encoding="utf-8", errors="replace") as handle:
        sys.stderr.write(handle.read())
    raise SystemExit("stdout guard recorded corruption during ping stress")

send({"jsonrpc": "2.0", "id": "shutdown", "method": "shutdown"})
recv(time.time() + 5, "shutdown")
send({"jsonrpc": "2.0", "id": "exit", "method": "exit"})
recv(time.time() + 5, "exit", allow_eof=True)

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
