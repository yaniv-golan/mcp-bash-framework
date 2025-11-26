#!/usr/bin/env bash
# Spec §18.2 (Examples layer): replay example workspaces with canned NDJSON.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../common/env.sh
# shellcheck disable=SC1091
. "${SCRIPT_DIR}/../common/env.sh"
# shellcheck source=../common/assert.sh
# shellcheck disable=SC1091
. "${SCRIPT_DIR}/../common/assert.sh"
# shellcheck source=../common/fixtures.sh
# shellcheck disable=SC1091
. "${SCRIPT_DIR}/../common/fixtures.sh"

test_require_command python3 || test_require_command python

discover_examples() {
	local entry
	for entry in "${MCPBASH_HOME}/examples/"[0-9][0-9]-*; do
		[ -d "${entry}" ] || continue
		basename "${entry}"
	done
}

run_example_suite() {
	local example_id="$1"
	printf 'Example %s\n' "${example_id}"

	test_stage_example "${example_id}"
	local workdir="${MCP_TEST_WORKDIR}"

	local tool_name=""
	local py_meta
	py_meta="$(command -v python3 2>/dev/null || command -v python)"
	if [ -n "${py_meta}" ] && [ -d "${MCPBASH_HOME}/examples/${example_id}/tools" ]; then
		if ! tool_name="$(
			"${py_meta}" - "${MCPBASH_HOME}/examples/${example_id}/tools" <<'PY'
import json, os, sys
tools_dir = sys.argv[1]
for entry in sorted(os.listdir(tools_dir)):
    if entry.endswith(".meta.json") or entry.endswith(".meta.yaml"):
        path = os.path.join(tools_dir, entry)
        with open(path, encoding="utf-8") as handle:
            data = json.load(handle)
        name = data.get("name")
        if name:
            print(name)
            break
PY
		)"; then
			tool_name=""
		fi
	fi

	cat <<'JSON' >"${workdir}/requests.ndjson"
{"jsonrpc":"2.0","id":"init","method":"initialize","params":{}}
{"jsonrpc":"2.0","method":"notifications/initialized"}
JSON

	if [ -n "${tool_name}" ]; then
		printf '{"jsonrpc":"2.0","id":"tools","method":"tools/list","params":{"limit":5}}\n' >>"${workdir}/requests.ndjson"
	fi

	cat <<'JSON' >>"${workdir}/requests.ndjson"
{"jsonrpc":"2.0","id":"shutdown","method":"shutdown"}
{"jsonrpc":"2.0","id":"exit","method":"exit"}
JSON

	test_run_mcp "${workdir}" "${workdir}/requests.ndjson" "${workdir}/responses.ndjson"
	assert_json_lines "${workdir}/responses.ndjson"

	PY_BIN="$(command -v python3 2>/dev/null || command -v python)"
	WORKDIR="${workdir}" TOOL_NAME="${tool_name}" "${PY_BIN}" <<'PY'
import json, os

path = os.path.join(os.environ["WORKDIR"], "responses.ndjson")
tool_name = os.environ.get("TOOL_NAME", "")
messages = []
with open(path, encoding="utf-8") as handle:
    for raw in handle:
        raw = raw.strip()
        if not raw:
            continue
        messages.append(json.loads(raw))

def by_id(identifier):
    for msg in messages:
        if msg.get("id") == identifier:
            return msg
    raise SystemExit(f"{identifier} missing from responses")

init = by_id("init")
result = init.get("result") or {}
if result.get("protocolVersion") != "2025-06-18":
    raise SystemExit("protocol negotiation mismatch for example")

caps = result.get("capabilities") or {}
if "logging" not in caps:
    raise SystemExit("logging capability should always be present")

if tool_name:
    tools = by_id("tools").get("result", {}).get("items", [])
    names = {item.get("name") for item in tools}
    if tool_name not in names:
        raise SystemExit(f"expected tool {tool_name} not found in example registry")
PY
}

examples=()
while IFS= read -r entry; do
	examples+=("${entry}")
done < <(discover_examples)

if [ "${#examples[@]}" -eq 0 ]; then
	printf 'No examples discovered under %s\n' "${MCPBASH_HOME}/examples" >&2
	exit 1
fi

for example in "${examples[@]}"; do
	run_example_suite "${example}"
done
