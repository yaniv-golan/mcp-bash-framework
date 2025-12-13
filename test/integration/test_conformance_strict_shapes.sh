#!/usr/bin/env bash
# shellcheck disable=SC2034  # Used by test runner for reporting.
TEST_DESC="Strict MCP shape conformance (Inspector-style schema validation)."
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../common/env.sh
# shellcheck disable=SC1091
. "${SCRIPT_DIR}/../common/env.sh"
# shellcheck source=../common/assert.sh
# shellcheck disable=SC1091
. "${SCRIPT_DIR}/../common/assert.sh"

test_create_tmpdir

TEST_FAILURE_BUNDLE_LABEL="test_conformance_strict_shapes.sh"
TEST_FAILURE_BUNDLE_WORKSPACE=""
TEST_FAILURE_BUNDLE_STATE_DIR=""
TEST_FAILURE_BUNDLE_EXTRA_FILES=""

pick_server_json_tool() {
	local requested="${MCPBASH_CONFORMANCE_SERVER_JSON_TOOL:-}"
	if [ -n "${requested}" ]; then
		case "${requested}" in
		jq | gojq) ;;
		*) test_fail "invalid MCPBASH_CONFORMANCE_SERVER_JSON_TOOL: ${requested}" ;;
		esac
		if ! command -v "${requested}" >/dev/null 2>&1; then
			test_fail "required JSON tool not found: ${requested}"
		fi
		printf '%s' "${requested}"
		return 0
	fi

	# Default: use the same JSON tool the test harness uses for assertions.
	# (env.sh prefers gojq on non-Windows, jq on Windows when available.)
	local bin="${TEST_JSON_TOOL_BIN}"
	local base
	base="$(basename -- "${bin}")"
	case "${base}" in
	jq | gojq)
		printf '%s' "${base}"
		return 0
		;;
	esac
	# Fallback: prefer gojq if present, else jq.
	if command -v gojq >/dev/null 2>&1; then
		printf '%s' "gojq"
		return 0
	fi
	if command -v jq >/dev/null 2>&1; then
		printf '%s' "jq"
		return 0
	fi
	test_fail "no jq/gojq available for server"
}

run_server() {
	local workspace="$1"
	local requests_file="$2"
	local responses_file="$3"
	local server_json_tool="$4"
	local stderr_file="${responses_file}.stderr"
	# Configure failure bundle context for test_fail() to capture on assertion failure.
	TEST_FAILURE_BUNDLE_WORKSPACE="${workspace}"
	TEST_FAILURE_BUNDLE_STATE_DIR=""
	TEST_FAILURE_BUNDLE_EXTRA_FILES="${stderr_file}"

	(
		cd "${workspace}" || exit 1
		MCPBASH_PROJECT_ROOT="${workspace}" \
			MCPBASH_ALLOW_PROJECT_HOOKS="true" \
			MCPBASH_JSON_TOOL="${server_json_tool}" \
			MCPBASH_JSON_TOOL_BIN="$(command -v "${server_json_tool}")" \
			./bin/mcp-bash <"${requests_file}" >"${responses_file}" 2>"${stderr_file}"
	)

	# If the server preserved state, capture that directory too.
	if command -v test_extract_state_dir_from_stderr >/dev/null 2>&1; then
		TEST_FAILURE_BUNDLE_STATE_DIR="$(test_extract_state_dir_from_stderr "${stderr_file}" 2>/dev/null || true)"
	fi
}

assert_optional_next_cursor_string() {
	local result="$1"
	printf '%s' "${result}" | jq -e '
		if has("nextCursor") then
			(.nextCursor | type) == "string"
		else
			true
		end
	' >/dev/null || test_fail "nextCursor must be omitted or a string"
}

server_json_tool="$(pick_server_json_tool)"

#
# Conformance: completion/complete (manual completion + pagination cursors).
#
COMP_ROOT="${TEST_TMPDIR}/conformance-completion"
test_stage_workspace "${COMP_ROOT}"
mkdir -p "${COMP_ROOT}/completions"
cp -a "${MCPBASH_HOME}/examples/10-completions/server.d/register.json" "${COMP_ROOT}/server.d/register.json"
cp -a "${MCPBASH_HOME}/examples/10-completions/completions/suggest.sh" "${COMP_ROOT}/completions/suggest.sh"

cat >"${COMP_ROOT}/requests.ndjson" <<'EOF'
{"jsonrpc":"2.0","id":"init","method":"initialize","params":{}}
{"jsonrpc":"2.0","method":"notifications/initialized"}
{"jsonrpc":"2.0","id":"c1","method":"completion/complete","params":{"name":"demo.completion","arguments":{"query":"re"},"limit":3}}
EOF

run_server "${COMP_ROOT}" "${COMP_ROOT}/requests.ndjson" "${COMP_ROOT}/responses.ndjson" "${server_json_tool}"
assert_json_lines "${COMP_ROOT}/responses.ndjson"

cursor="$(jq -r 'select(.id=="c1") | .result.completion.nextCursor // empty' "${COMP_ROOT}/responses.ndjson")"
if [ -z "${cursor}" ] || [ "${cursor}" = "null" ]; then
	test_fail "expected completion cursor for demo.completion page 1"
fi

if ! jq -e '
	select(.id=="c1") |
	(.result.completion | type) == "object" and
	(.result.completion.values | type) == "array" and
	(.result.completion.values | length) == 3 and
	(.result.completion.hasMore | type) == "boolean" and
	(.result.completion.hasMore == true) and
	(.result.completion.nextCursor | type) == "string"
' "${COMP_ROOT}/responses.ndjson" >/dev/null; then
	test_fail "completion/complete response shape mismatch (page 1)"
fi

cat >"${COMP_ROOT}/requests_page2.ndjson" <<EOF
{"jsonrpc":"2.0","id":"init2","method":"initialize","params":{}}
{"jsonrpc":"2.0","method":"notifications/initialized"}
{"jsonrpc":"2.0","id":"c2","method":"completion/complete","params":{"name":"demo.completion","cursor":"${cursor}","limit":3}}
EOF

run_server "${COMP_ROOT}" "${COMP_ROOT}/requests_page2.ndjson" "${COMP_ROOT}/responses_page2.ndjson" "${server_json_tool}"
assert_json_lines "${COMP_ROOT}/responses_page2.ndjson"

if ! jq -e '
	select(.id=="c2") |
	(.result.completion.values | type) == "array" and
	(.result.completion.values | length) == 3 and
	(.result.completion.hasMore | type) == "boolean"
' "${COMP_ROOT}/responses_page2.ndjson" >/dev/null; then
	test_fail "completion/complete response shape mismatch (page 2)"
fi

#
# Conformance: manual registration (tools/resources/prompts) + custom provider by URI.
#
MANUAL_ROOT="${TEST_TMPDIR}/conformance-manual"
test_stage_workspace "${MANUAL_ROOT}"
cp -a "${MCPBASH_HOME}/examples/09-registry-overrides/server.d" "${MANUAL_ROOT}/"
cp -a "${MCPBASH_HOME}/examples/09-registry-overrides/tools" "${MANUAL_ROOT}/"
cp -a "${MCPBASH_HOME}/examples/09-registry-overrides/resources" "${MANUAL_ROOT}/"
cp -a "${MCPBASH_HOME}/examples/09-registry-overrides/prompts" "${MANUAL_ROOT}/"

cat >"${MANUAL_ROOT}/requests.ndjson" <<'EOF'
{"jsonrpc":"2.0","id":"init","method":"initialize","params":{}}
{"jsonrpc":"2.0","method":"notifications/initialized"}
{"jsonrpc":"2.0","id":"tlist","method":"tools/list","params":{}}
{"jsonrpc":"2.0","id":"rlist","method":"resources/list","params":{}}
{"jsonrpc":"2.0","id":"plist","method":"prompts/list","params":{}}
{"jsonrpc":"2.0","id":"tcall","method":"tools/call","params":{"name":"manual.progress","arguments":{},"_meta":{"progressToken":"p1"}}}
{"jsonrpc":"2.0","id":"rread","method":"resources/read","params":{"uri":"echo://Hello-from-manual-registry"}}
{"jsonrpc":"2.0","id":"pget","method":"prompts/get","params":{"name":"manual.prompt","arguments":{"topic":"testing"}}}
EOF

run_server "${MANUAL_ROOT}" "${MANUAL_ROOT}/requests.ndjson" "${MANUAL_ROOT}/responses.ndjson" "${server_json_tool}"
assert_json_lines "${MANUAL_ROOT}/responses.ndjson"

# tools/list shape + optional nextCursor
tools_list="$(jq -c 'select(.id=="tlist") | .result' "${MANUAL_ROOT}/responses.ndjson")"
printf '%s' "${tools_list}" | jq -e '
	(.tools | type) == "array" and
	(.tools[0].name | type) == "string"
' >/dev/null || test_fail "tools/list shape mismatch"
assert_optional_next_cursor_string "${tools_list}"

# resources/list shape + optional nextCursor
resources_list="$(jq -c 'select(.id=="rlist") | .result' "${MANUAL_ROOT}/responses.ndjson")"
printf '%s' "${resources_list}" | jq -e '
	(.resources | type) == "array" and
	(.resources[0].uri | type) == "string" and
	(.resources[0].provider | type) == "string" and
	(.resources[0].provider == "echo")
' >/dev/null || test_fail "resources/list shape mismatch"
assert_optional_next_cursor_string "${resources_list}"

# prompts/list shape (arguments must be list, not schema object)
prompts_list="$(jq -c 'select(.id=="plist") | .result' "${MANUAL_ROOT}/responses.ndjson")"
printf '%s' "${prompts_list}" | jq -e '
	(.prompts | type) == "array" and
	(.prompts[0].arguments | type) == "array"
' >/dev/null || test_fail "prompts/list shape mismatch"
assert_optional_next_cursor_string "${prompts_list}"

# resources/read must resolve by uri and honor custom provider
if ! jq -e '
	select(.id=="rread") |
	(.result.contents | type) == "array" and
	(.result.contents[0].uri == "echo://Hello-from-manual-registry") and
	(.result.contents[0].text == "Hello-from-manual-registry")
' "${MANUAL_ROOT}/responses.ndjson" >/dev/null; then
	test_fail "resources/read shape mismatch for echo:// provider"
fi

# prompts/get message content must be a single object
if ! jq -e '
	select(.id=="pget") |
	(.result.messages | type) == "array" and
	(.result.messages[0].content | type) == "object" and
	(.result.messages[0].content.type == "text") and
	(.result.messages[0].content.text | type) == "string"
' "${MANUAL_ROOT}/responses.ndjson" >/dev/null; then
	test_fail "prompts/get message content shape mismatch"
fi

# progress notifications present and well-typed
# Use -s to slurp NDJSON into an array; without it, jq processes each line
# independently and -e fails if ANY line produces false (non-progress lines).
if ! jq -s -e '
	[.[] | select(.method=="notifications/progress") | .params.progress] as $p
	| ($p | length) >= 1
' "${MANUAL_ROOT}/responses.ndjson" >/dev/null; then
	test_fail "expected at least one notifications/progress event"
fi
