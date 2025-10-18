#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../common/env.sh
# shellcheck disable=SC1091
. "${SCRIPT_DIR}/../common/env.sh"
# shellcheck source=../common/assert.sh
# shellcheck disable=SC1091
. "${SCRIPT_DIR}/../common/assert.sh"

test_create_tmpdir

echo "Resources integration temp root: ${TEST_TMPDIR}"

stage_workspace() {
	local dest="$1"
	mkdir -p "${dest}"
	cp -a "${MCPBASH_ROOT}/bin" "${dest}/"
	cp -a "${MCPBASH_ROOT}/lib" "${dest}/"
	cp -a "${MCPBASH_ROOT}/handlers" "${dest}/"
	cp -a "${MCPBASH_ROOT}/providers" "${dest}/"
	cp -a "${MCPBASH_ROOT}/sdk" "${dest}/"
	cp -a "${MCPBASH_ROOT}/resources" "${dest}/" 2>/dev/null || true
	cp -a "${MCPBASH_ROOT}/prompts" "${dest}/" 2>/dev/null || true
	cp -a "${MCPBASH_ROOT}/server.d" "${dest}/"
}

# --- Auto-discovery and pagination ---
AUTO_ROOT="${TEST_TMPDIR}/auto"
stage_workspace "${AUTO_ROOT}"
chmod -x "${AUTO_ROOT}/server.d/register.sh"
mkdir -p "${AUTO_ROOT}/resources"

echo "  • Auto-discovery workspace: ${AUTO_ROOT}"

cat <<EOF_RES >"${AUTO_ROOT}/resources/alpha.txt"
alpha
EOF_RES

cat <<EOF_RES >"${AUTO_ROOT}/resources/beta.txt"
beta
EOF_RES

cat <<EOF_META >"${AUTO_ROOT}/resources/alpha.meta.yaml"
{"name": "file.alpha", "description": "Alpha resource", "uri": "file://${AUTO_ROOT}/resources/alpha.txt", "mimeType": "text/plain"}
EOF_META

cat <<EOF_META >"${AUTO_ROOT}/resources/beta.meta.yaml"
{"name": "file.beta", "description": "Beta resource", "uri": "file://${AUTO_ROOT}/resources/beta.txt", "mimeType": "text/plain"}
EOF_META

cat <<'JSON' >"${AUTO_ROOT}/requests.ndjson"
{"jsonrpc":"2.0","id":"auto-init","method":"initialize","params":{}}
{"jsonrpc":"2.0","method":"notifications/initialized"}
{"jsonrpc":"2.0","id":"auto-list","method":"resources/list","params":{"limit":1}}
{"jsonrpc":"2.0","id":"auto-read","method":"resources/read","params":{"name":"file.alpha"}}
JSON

(
	cd "${AUTO_ROOT}" || exit 1
	./bin/mcp-bash <"requests.ndjson" >"responses.ndjson"
)

python3 - "${AUTO_ROOT}/responses.ndjson" <<'PY'
import json, sys
path = sys.argv[1]
messages = [json.loads(line) for line in open(path, encoding='utf-8') if line.strip()]

def by_id(msg_id):
    for msg in messages:
        if msg.get("id") == msg_id:
            return msg
    raise SystemExit(f"missing response {msg_id}")

list_resp = by_id("auto-list")
result = list_resp.get("result") or {}
items = result.get("items") or []
if result.get("total") != 2:
    raise SystemExit("expected two resources discovered")
if "nextCursor" not in result:
    raise SystemExit("nextCursor missing for paginated resources")
first = items[0]
if first.get("name") not in {"file.alpha", "file.beta"}:
    raise SystemExit("unexpected resource name")

read_resp = by_id("auto-read")
read_result = read_resp.get("result") or {}
if read_result.get("mimeType") != "text/plain":
    raise SystemExit("unexpected mimeType")
if read_result.get("content") != "alpha":
    raise SystemExit("resource content mismatch")
PY

# --- Manual registration overrides ---
MANUAL_ROOT="${TEST_TMPDIR}/manual"
stage_workspace "${MANUAL_ROOT}"
mkdir -p "${MANUAL_ROOT}/resources/manual"

echo "  • Manual override workspace: ${MANUAL_ROOT}"

cat <<EOF_RES >"${MANUAL_ROOT}/resources/manual/left.txt"
left
EOF_RES
cat <<EOF_RES >"${MANUAL_ROOT}/resources/manual/right.txt"
right
EOF_RES

cat <<EOF_SCRIPT >"${MANUAL_ROOT}/server.d/register.sh"
#!/usr/bin/env bash
set -euo pipefail

mcp_register_resource '{
  "name": "manual.left",
  "description": "Left resource",
  "uri": "file://${MANUAL_ROOT}/resources/manual/left.txt",
  "mimeType": "text/plain"
}'

mcp_register_resource '{
  "name": "manual.right",
  "description": "Right resource",
  "uri": "file://${MANUAL_ROOT}/resources/manual/right.txt",
  "mimeType": "text/plain"
}'

return 0
EOF_SCRIPT
chmod +x "${MANUAL_ROOT}/server.d/register.sh"

cat <<'JSON' >"${MANUAL_ROOT}/requests.ndjson"
{"jsonrpc":"2.0","id":"manual-init","method":"initialize","params":{}}
{"jsonrpc":"2.0","method":"notifications/initialized"}
{"jsonrpc":"2.0","id":"manual-list","method":"resources/list","params":{"limit":2}}
{"jsonrpc":"2.0","id":"manual-read","method":"resources/read","params":{"name":"manual.right"}}
JSON

(
	cd "${MANUAL_ROOT}" || exit 1
	./bin/mcp-bash <"requests.ndjson" >"responses.ndjson"
)

python3 - "${MANUAL_ROOT}/responses.ndjson" <<'PY'
import json, sys
path = sys.argv[1]
messages = [json.loads(line) for line in open(path, encoding='utf-8') if line.strip()]

def by_id(msg_id):
    for msg in messages:
        if msg.get("id") == msg_id:
            return msg
    raise SystemExit(f"missing response {msg_id}")

list_resp = by_id("manual-list")
result = list_resp.get("result") or {}
items = result.get("items") or []
if result.get("total") != 2:
    raise SystemExit("manual registry should contain two resources")
for item in items:
    if item.get("name") not in {"manual.left", "manual.right"}:
        raise SystemExit("unexpected resource discovered in manual registry")

read_resp = by_id("manual-read")
content = (read_resp.get("result") or {}).get("content")
if content != "right":
    raise SystemExit(f"manual resource content mismatch: {content!r}")
PY

# --- Subscription updates ---
SUB_ROOT="${TEST_TMPDIR}/subscribe"
stage_workspace "${SUB_ROOT}"
chmod -x "${SUB_ROOT}/server.d/register.sh"
mkdir -p "${SUB_ROOT}/resources"

echo "  • Subscription workspace: ${SUB_ROOT}"

cat <<EOF_RES >"${SUB_ROOT}/resources/live.txt"
original
EOF_RES

cat <<EOF_META >"${SUB_ROOT}/resources/live.meta.yaml"
{"name": "file.live", "description": "Live file", "uri": "file://${SUB_ROOT}/resources/live.txt", "mimeType": "text/plain"}
EOF_META

export SUB_ROOT
python3 <<'PY'
import json
import os
import subprocess
import sys
import time

sub_root = os.environ["SUB_ROOT"]
trace_path = os.path.join(sub_root, "trace.log")
log = open(trace_path, "w", encoding="utf-8")
print(f"[resources] trace log -> {trace_path}", file=sys.stderr)

def trace(direction, payload):
    log.write(json.dumps({"dir": direction, "payload": payload}) + "\n")
    log.flush()

proc = subprocess.Popen(
    ["./bin/mcp-bash"],
    cwd=sub_root,
    stdin=subprocess.PIPE,
    stdout=subprocess.PIPE,
    text=True,
)


def send(message):
    line = json.dumps(message, separators=(",", ":")) + "\n"
    proc.stdin.write(line)
    proc.stdin.flush()
    trace("send", message)


def next_message(deadline):
    while True:
        remaining = deadline - time.time()
        if remaining <= 0:
            raise SystemExit("timeout waiting for server output")
        line = proc.stdout.readline()
        if not line:
            raise SystemExit("server exited unexpectedly")
        line = line.strip()
        if not line:
            continue
        payload = json.loads(line)
        trace("recv", payload)
        return payload


try:
    send({"jsonrpc": "2.0", "id": "init", "method": "initialize", "params": {}})
    deadline = time.time() + 10
    while True:
        msg = next_message(deadline)
        if msg.get("id") == "init":
            break

    send({"jsonrpc": "2.0", "method": "notifications/initialized"})

    send(
        {
            "jsonrpc": "2.0",
            "id": "sub",
            "method": "resources/subscribe",
            "params": {"name": "file.live"},
        }
    )
    subscription_id = None
    initial_update = None
    deadline = time.time() + 10
    list_changed_seen = 0
    while True:
        msg = next_message(deadline)
        if msg.get("id") == "sub":
            subscription_id = msg.get("result", {}).get("subscriptionId")
            if not subscription_id:
                raise SystemExit("subscriptionId missing")
        elif msg.get("method") == "notifications/resources/updated":
            params = msg.get("params", {})
            if params.get("subscriptionId") == subscription_id:
                initial_update = params
                content = params.get("content")
                if content != "original":
                    raise SystemExit("initial subscription content mismatch")
                break
        elif msg.get("method") == "notifications/resources/list_changed" and msg.get("params"):
            # Ignore list_changed with params payload to avoid JSON parsing error in read loop
            continue
        elif msg.get("method") in {"notifications/resources/list_changed", "notifications/tools/list_changed"}:
            list_changed_seen += 1
            if list_changed_seen > 10:
                raise SystemExit("subscribe response missing after repeated list_changed notifications")

    if subscription_id is None or initial_update is None:
        raise SystemExit("did not receive initial subscription update")

    with open(
        os.path.join(sub_root, "resources", "live.txt"), "w", encoding="utf-8"
    ) as handle:
        handle.write("updated\n")

    send({"jsonrpc": "2.0", "id": "ping", "method": "ping"})
    ping_seen = False
    update_seen = False
    deadline = time.time() + 10
    while True:
        try:
            msg = next_message(deadline)
        except SystemExit as exc:
            raise SystemExit(f"timeout waiting for ping/update: {exc}") from None
        if msg.get("id") == "ping":
            ping_seen = True
        elif msg.get("method") == "notifications/resources/updated":
            params = msg.get("params", {})
            if params.get("subscriptionId") == subscription_id and params.get(
                "content"
            ) == "updated":
                update_seen = True
        if ping_seen and update_seen:
            break

    if not ping_seen:
        raise SystemExit("ping response missing after update")
    if not update_seen:
        raise SystemExit("subscription update not observed after change")

    send(
        {
            "jsonrpc": "2.0",
            "id": "unsub",
            "method": "resources/unsubscribe",
            "params": {"subscriptionId": subscription_id},
        }
    )
    send({"jsonrpc": "2.0", "id": "shutdown", "method": "shutdown"})
    send({"jsonrpc": "2.0", "id": "exit", "method": "exit"})
finally:
    trace("final", {"message": "closing"})
    log.close()
    if proc.stdin:
        try:
            proc.stdin.close()
        except Exception:
            pass
    try:
        proc.wait(timeout=5)
    except subprocess.TimeoutExpired:
        proc.kill()
        proc.wait(timeout=5)
    print(f"[resources] trace log captured at {trace_path}", file=sys.stderr)
    if proc.returncode not in (0, None):
        raise SystemExit(f"server exited with {proc.returncode}")
PY
