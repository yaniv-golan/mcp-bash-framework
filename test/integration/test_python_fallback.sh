#!/usr/bin/env bash
# Spec §18 Integration: verify python JSON tooling fallback activates when jq/gojq absent.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../common/env.sh
# shellcheck disable=SC1091
. "${SCRIPT_DIR}/../common/env.sh"
# shellcheck source=../common/assert.sh
# shellcheck disable=SC1091
. "${SCRIPT_DIR}/../common/assert.sh"

test_require_command python3 || test_require_command python

create_path_shim() {
	local shim_dir="$1"
	local seen_marker_file="${shim_dir}/.seen"
	: >"${seen_marker_file}"
	local dir entry name
	IFS=':' read -r -a path_dirs <<<"${PATH}"
	for dir in "${path_dirs[@]}"; do
		if [ -z "${dir}" ] || [ ! -d "${dir}" ]; then
			continue
		fi
		for entry in "${dir}"/*; do
			name="$(basename "${entry}")"
			case "${name}" in
			'' | '.' | '..' | jq | gojq)
				continue
				;;
			esac
			if [ -e "${shim_dir}/${name}" ]; then
				continue
			fi
			ln -s "${entry}" "${shim_dir}/${name}" 2>/dev/null || true
		done
	done
}

test_create_tmpdir
WORKSPACE="${TEST_TMPDIR}/python"
test_stage_workspace "${WORKSPACE}"

mkdir -p "${WORKSPACE}/tools" "${WORKSPACE}/server.d"

cat <<'SH' >"${WORKSPACE}/tools/fallback.sh"
#!/usr/bin/env bash
set -euo pipefail
printf 'python fallback ok'
SH
chmod +x "${WORKSPACE}/tools/fallback.sh"

cat <<'REG' >"${WORKSPACE}/server.d/register.sh"
#!/usr/bin/env bash
set -euo pipefail

mcp_register_tool '{
  "name": "fallback.echo",
  "description": "Emit a static confirmation message",
  "path": "tools/fallback.sh",
  "arguments": {"type": "object", "properties": {}}
}'
REG
chmod +x "${WORKSPACE}/server.d/register.sh"

cat <<'JSON' >"${WORKSPACE}/requests.ndjson"
{"jsonrpc":"2.0","id":"init","method":"initialize","params":{}}
{"jsonrpc":"2.0","method":"notifications/initialized"}
{"jsonrpc":"2.0","id":"list","method":"tools/list","params":{"limit":5}}
{"jsonrpc":"2.0","id":"call","method":"tools/call","params":{"name":"fallback.echo","arguments":{}}}
{"jsonrpc":"2.0","id":"shutdown","method":"shutdown"}
{"jsonrpc":"2.0","id":"exit","method":"exit"}
JSON

PATH_SHIM="${TEST_TMPDIR}/path-shim"
mkdir -p "${PATH_SHIM}"
create_path_shim "${PATH_SHIM}"

stderr_path="${WORKSPACE}/stderr.log"
(
	cd "${WORKSPACE}" || exit 1
	PATH="${PATH_SHIM}" \
		MCPBASH_FORCE_MINIMAL=false \
		./bin/mcp-bash <"requests.ndjson" >"responses.ndjson"
) 2>"${stderr_path}"

assert_file_exists "${WORKSPACE}/responses.ndjson"
assert_json_lines "${WORKSPACE}/responses.ndjson"

if ! grep -q 'Detected Python JSON fallback' "${stderr_path}"; then
	printf 'stderr contents:\n'
	cat "${stderr_path}"
	test_fail "python fallback detection log missing"
fi

PY_BIN="$(command -v python3 2>/dev/null || command -v python)"
export WORKSPACE
"${PY_BIN}" <<'PY'
import json, os

path = os.path.join(os.environ["WORKSPACE"], "responses.ndjson")
messages = []
with open(path, encoding="utf-8") as handle:
    for raw in handle:
        raw = raw.strip()
        if not raw:
            continue
        messages.append(json.loads(raw))

def by_id(msg_id):
    for msg in messages:
        if msg.get("id") == msg_id:
            return msg
    raise SystemExit(f"missing response {msg_id}")

init = by_id("init")
tool_response = by_id("call")
content = tool_response.get("result", {}).get("content", [])
texts = [entry.get("text") for entry in content if entry.get("type") == "text"]
if "python fallback ok" not in texts:
    raise SystemExit("tool invocation failed under python fallback")

tool_list = by_id("list")
items = tool_list.get("result", {}).get("items", [])
if "fallback.echo" not in {item.get("name") for item in items}:
    raise SystemExit("fallback tool not discovered under python fallback")

if init.get("result", {}).get("protocolVersion") != "2025-06-18":
    raise SystemExit("protocol negotiation unexpected with python fallback")
PY

printf 'Python fallback integration passed.\n'
