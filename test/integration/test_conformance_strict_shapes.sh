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

start_server_session() {
	local workspace="$1"
	local responses_file="$2"
	local server_json_tool="$3"
	local stderr_file="${responses_file}.stderr"

	local pipe_in="${workspace}/mcp.pipe.in"
	local pipe_out="${workspace}/mcp.pipe.out"
	rm -f "${pipe_in}" "${pipe_out}"
	mkfifo "${pipe_in}" "${pipe_out}"

	(
		cd "${workspace}" || exit 1
		MCPBASH_PROJECT_ROOT="${workspace}" \
			MCPBASH_ALLOW_PROJECT_HOOKS="true" \
			MCPBASH_JSON_TOOL="${server_json_tool}" \
			MCPBASH_JSON_TOOL_BIN="$(command -v "${server_json_tool}")" \
			./bin/mcp-bash <"${pipe_in}" >"${pipe_out}" 2>"${stderr_file}" &
		printf '%s' "$!" >"${workspace}/mcp.session.pid"
	) || true

	# shellcheck disable=SC2094
	exec 3>"${pipe_in}"
	# shellcheck disable=SC2094
	exec 4<"${pipe_out}"
	: >"${responses_file}"
	: >"${stderr_file}"

	TEST_FAILURE_BUNDLE_WORKSPACE="${workspace}"
	TEST_FAILURE_BUNDLE_STATE_DIR=""
	TEST_FAILURE_BUNDLE_EXTRA_FILES="${stderr_file}"

	# Export for helpers.
	MCP_CONFORMANCE_PIPE_IN="${pipe_in}"
	MCP_CONFORMANCE_PIPE_OUT="${pipe_out}"
	MCP_CONFORMANCE_PID_FILE="${workspace}/mcp.session.pid"
	export MCP_CONFORMANCE_PIPE_IN MCP_CONFORMANCE_PIPE_OUT MCP_CONFORMANCE_PID_FILE
}

stop_server_session() {
	local workspace="$1"
	local response_timeout="${2:-5}"

	# Close pipes before waiting; prevents hangs if the server stops reading/writing.
	exec 3>&- || true
	exec 4<&- || true

	if [ -f "${workspace}/mcp.session.pid" ]; then
		local server_pid
		server_pid="$(cat "${workspace}/mcp.session.pid" 2>/dev/null || true)"
		if [ -n "${server_pid}" ]; then
			local attempts=0
			while [ "${attempts}" -lt $((response_timeout * 10)) ] && kill -0 "${server_pid}" 2>/dev/null; do
				sleep 0.1 2>/dev/null || sleep 1
				attempts=$((attempts + 1))
			done
			if ! kill -0 "${server_pid}" 2>/dev/null; then
				wait "${server_pid}" 2>/dev/null || true
			fi
		fi
	fi

	rm -f "${workspace}/mcp.pipe.in" "${workspace}/mcp.pipe.out" "${workspace}/mcp.session.pid"
}

session_send() {
	printf '%s\n' "$1" >&3
}

session_read_line() {
	local timeout="${1:-5}"
	local line=""
	if read -r -t "${timeout}" -u 4 line; then
		printf '%s' "${line}"
		return 0
	fi
	return 1
}

session_wait_for_id() {
	local responses_file="$1"
	local match_id="$2"
	local timeout="${3:-10}"
	local end_time
	end_time=$(($(date +%s) + timeout))

	while [ "$(date +%s)" -lt "${end_time}" ]; do
		local line=""
		line="$(session_read_line 2 2>/dev/null || true)"
		if [ -z "${line}" ]; then
			continue
		fi
		printf '%s\n' "${line}" >>"${responses_file}"

		local id
		id="$(printf '%s' "${line}" | jq -r '.id // empty' 2>/dev/null || true)"
		if [ "${id}" = "${match_id}" ]; then
			printf '%s' "${line}"
			return 0
		fi
	done
	return 1
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

start_server_session "${COMP_ROOT}" "${COMP_ROOT}/responses.ndjson" "${server_json_tool}"
session_send '{"jsonrpc":"2.0","id":"init","method":"initialize","params":{}}'
if ! session_wait_for_id "${COMP_ROOT}/responses.ndjson" "init" 10 >/dev/null; then
	stop_server_session "${COMP_ROOT}"
	test_fail "initialize timeout"
fi
session_send '{"jsonrpc":"2.0","method":"notifications/initialized"}'
session_send '{"jsonrpc":"2.0","id":"c1","method":"completion/complete","params":{"name":"demo.completion","arguments":{"query":"re"},"limit":3}}'
c1_line="$(session_wait_for_id "${COMP_ROOT}/responses.ndjson" "c1" 15 || true)"
if [ -z "${c1_line}" ]; then
	stop_server_session "${COMP_ROOT}"
	test_fail "completion/complete timeout (page 1)"
fi

assert_json_lines "${COMP_ROOT}/responses.ndjson"

cursor="$(printf '%s' "${c1_line}" | jq -r '.result.completion.nextCursor // empty')"
if [ -z "${cursor}" ] || [ "${cursor}" = "null" ]; then
	stop_server_session "${COMP_ROOT}"
	test_fail "expected completion cursor for demo.completion page 1"
fi

if ! printf '%s' "${c1_line}" | jq -e '
	(.result.completion | type) == "object" and
	(.result.completion.values | type) == "array" and
	(.result.completion.values | length) == 3 and
	(.result.completion.hasMore | type) == "boolean" and
	(.result.completion.hasMore == true) and
	(.result.completion.nextCursor | type) == "string"
' >/dev/null; then
	stop_server_session "${COMP_ROOT}"
	test_fail "completion/complete response shape mismatch (page 1)"
fi

session_send "$(jq -n -c --arg cursor "${cursor}" \
	'{"jsonrpc":"2.0","id":"c2","method":"completion/complete","params":{"name":"demo.completion","cursor":$cursor,"limit":3}}')"
c2_line="$(session_wait_for_id "${COMP_ROOT}/responses.ndjson" "c2" 15 || true)"
stop_server_session "${COMP_ROOT}"

assert_json_lines "${COMP_ROOT}/responses.ndjson"

if [ -z "${c2_line}" ]; then
	test_fail "completion/complete timeout (page 2)"
fi

if ! printf '%s' "${c2_line}" | jq -e '
	(.result.completion.values | type) == "array" and
	(.result.completion.values | length) == 3 and
	(.result.completion.hasMore | type) == "boolean"
' >/dev/null; then
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
assert_ndjson_shape "${MANUAL_ROOT}/responses.ndjson" '.id=="rread"' \
	'(.result.contents | type) == "array" and
	 (.result.contents[0].uri == "echo://Hello-from-manual-registry") and
	 (.result.contents[0].text == "Hello-from-manual-registry")' \
	"resources/read shape mismatch for echo:// provider"

# prompts/get message content must be a single object
assert_ndjson_shape "${MANUAL_ROOT}/responses.ndjson" '.id=="pget"' \
	'(.result.messages | type) == "array" and
	 (.result.messages[0].content | type) == "object" and
	 (.result.messages[0].content.type == "text") and
	 (.result.messages[0].content.text | type) == "string"' \
	"prompts/get message content shape mismatch"

# progress notifications present and well-typed
assert_ndjson_min "${MANUAL_ROOT}/responses.ndjson" \
	'.method=="notifications/progress"' 1 \
	"expected at least one notifications/progress event"
