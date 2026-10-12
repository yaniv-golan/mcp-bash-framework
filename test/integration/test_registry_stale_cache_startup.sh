#!/usr/bin/env bash
# shellcheck disable=SC2034  # Used by test runner for reporting.
TEST_DESC="A new server rescans a registry cache older than the TTL instead of serving it."
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../common/env.sh
# shellcheck disable=SC1091
. "${SCRIPT_DIR}/../common/env.sh"
# shellcheck source=../common/assert.sh
# shellcheck disable=SC1091
. "${SCRIPT_DIR}/../common/assert.sh"

test_require_command jq
test_create_tmpdir

# A server loads .registry/*.json left by an earlier run. It used to treat a
# loaded cache as scanned "now", so for the first TTL seconds (5 by default,
# when a client lists and makes its first call) it served whatever the cache
# held: a tool's old outputSchema made its first call fail with "Tool output
# does not satisfy outputSchema". A cache is now dated by its file's mtime.

WS="${TEST_TMPDIR}/ws"
test_stage_workspace "${WS}"
mkdir -p "${WS}/server.d" "${WS}/tools/greet" "${WS}/prompts" "${WS}/resources"
printf '%s\n' '{"name": "stale-cache"}' >"${WS}/server.d/server.meta.json"

# write_project FIELD DESCRIPTION: the tool returns {FIELD: "hi"} and declares
# it in its outputSchema; the prompt, resource and template carry DESCRIPTION.
write_project() {
	local field="$1" desc="$2"
	cat >"${WS}/tools/greet/tool.meta.json" <<EOF
{"name":"greet","description":"${desc}","inputSchema":{"type":"object","properties":{}},
 "outputSchema":{"type":"object","required":["${field}"],"properties":{"${field}":{"type":"string"}}}}
EOF
	cat >"${WS}/tools/greet/tool.sh" <<EOF
#!/usr/bin/env bash
set -euo pipefail
source "\${MCP_SDK}/tool-sdk.sh"
mcp_result_json "\$(mcp_json_obj ${field} hi)"
EOF
	chmod +x "${WS}/tools/greet/tool.sh"
	printf 'Hello\n' >"${WS}/prompts/hello.txt"
	cat >"${WS}/prompts/hello.meta.json" <<EOF
{"name":"hello","description":"${desc}","path":"hello.txt","arguments":{"type":"object","properties":{}}}
EOF
	printf 'note\n' >"${WS}/resources/note.txt"
	cat >"${WS}/resources/note.meta.json" <<EOF
{"name":"note","description":"${desc}","uri":"file://./resources/note.txt","mimeType":"text/plain","provider":"file"}
EOF
	cat >"${WS}/resources/files.meta.json" <<EOF
{"name":"files","uriTemplate":"file:///{+path}","description":"${desc}"}
EOF
}

run_session() {
	local out="$1"
	cat >"${TEST_TMPDIR}/requests.ndjson" <<'JSON'
{"jsonrpc":"2.0","id":"init","method":"initialize","params":{}}
{"jsonrpc":"2.0","method":"notifications/initialized"}
{"jsonrpc":"2.0","id":"tools","method":"tools/list","params":{}}
{"jsonrpc":"2.0","id":"prompts","method":"prompts/list","params":{}}
{"jsonrpc":"2.0","id":"resources","method":"resources/list","params":{}}
{"jsonrpc":"2.0","id":"templates","method":"resources/templates/list","params":{}}
{"jsonrpc":"2.0","id":"call","method":"tools/call","params":{"name":"greet","arguments":{}}}
JSON
	MCPBASH_TOOL_ALLOWLIST=greet test_run_mcp "${WS}" "${TEST_TMPDIR}/requests.ndjson" "${out}"
}

# First run builds the caches.
write_project message "old description"
run_session "${TEST_TMPDIR}/first.ndjson"
for f in tools prompts resources resource-templates; do
	[ -f "${WS}/.registry/${f}.json" ] || test_fail "first run left no .registry/${f}.json"
done

# The project changes; the caches are what an earlier session left behind.
write_project greeting "new description"
for f in tools prompts resources resource-templates; do
	touch -t 202001010000 "${WS}/.registry/${f}.json"
done

# check_fresh LABEL: the second session saw the project, not the cache.
check_fresh() {
	local label="$1" out="${TEST_TMPDIR}/$1.ndjson"
	run_session "${out}"
	assert_json_lines "${out}"

	local call greeting
	call="$(jq -c 'select(.id=="call")' "${out}")"
	greeting="$(printf '%s' "${call}" | jq -r '.result.structuredContent.greeting // empty')"
	[ "${greeting}" = "hi" ] || test_fail "${label}: first tools/call used the cached outputSchema: ${call}"

	check_desc() {
		local id="$1" path="$2" got
		got="$(jq -r --arg id "${id}" "select(.id == \$id) | ${path}" "${out}")"
		assert_eq "new description" "${got}" "${label}: ${id}: description from the cache instead of the project"
	}
	check_desc tools '.result.tools[] | select(.name == "greet") | .description'
	check_desc prompts '.result.prompts[] | select(.name == "hello") | .description'
	check_desc resources '.result.resources[] | select(.name == "note") | .description'
	check_desc templates '.result.resourceTemplates[] | select(.name == "files") | .description'
}

check_fresh old-cache

# A cache dated in the future (copied or extracted project, clock skew) is
# stale too, not fresh until the clock catches up.
write_project message "old description"
test_invalidate_registry_cache "${WS}"
run_session "${TEST_TMPDIR}/rebuild.ndjson"
write_project greeting "new description"
for f in tools prompts resources resource-templates; do
	touch -t 209901010000 "${WS}/.registry/${f}.json"
done
check_fresh future-cache

printf 'Stale registry cache test passed.\n'
