#!/usr/bin/env bash
# shellcheck disable=SC2034  # Used by test runner for reporting.
TEST_DESC="Every way a tool can fail gives an isError result, never a JSON-RPC error."

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
WS="${TEST_TMPDIR}/ws"
test_stage_workspace "${WS}"
mkdir -p "${WS}/server.d"
printf '%s\n' '{"name": "error-model"}' >"${WS}/server.d/server.meta.json"

# add_tool NAME BODY [OUTPUT_SCHEMA_JSON]: a tool whose script is BODY, run
# under set -euo pipefail with the SDK loaded.
add_tool() {
	local name="$1" body="$2" schema="${3:-}"
	mkdir -p "${WS}/tools/${name}"
	if [ -n "${schema}" ]; then
		printf '{"name":"%s","description":"t","inputSchema":{"type":"object"},"outputSchema":%s}\n' "${name}" "${schema}" >"${WS}/tools/${name}/tool.meta.json"
	else
		printf '{"name":"%s","description":"t","inputSchema":{"type":"object"}}\n' "${name}" >"${WS}/tools/${name}/tool.meta.json"
	fi
	{
		printf '#!/usr/bin/env bash\nset -euo pipefail\n'
		# shellcheck disable=SC2016  # Literal for the generated tool script
		printf 'source "${MCP_SDK}/tool-sdk.sh"\n'
		printf '%s\n' "${body}"
	} >"${WS}/tools/${name}/tool.sh"
	chmod +x "${WS}/tools/${name}/tool.sh"
}

# A plain non-zero exit, with the text on stdout or on stderr.
add_tool plainexit 'echo plain; exit 3'
add_tool stderrexit 'echo to-stderr >&2; exit 3'
# A 1.x-style error object on stdout: its message is used, its code never.
add_tool stdoutcode 'echo "{\"code\":-32001,\"message\":\"custom\"}"; exit 1'
# The same object with exit 0 is ordinary output.
add_tool stdoutcodeok 'echo "{\"code\":-32001,\"message\":\"custom\"}"'
# A data object that happens to have a message field is not an error message.
add_tool payloadexit 'echo "{\"message\":\"a commit message\"}"; echo real-error >&2; exit 1'
# A tool that prints its own error result and exits non-zero.
add_tool ownresult 'printf "%s\n" "{\"content\":[{\"type\":\"text\",\"text\":\"own\"}],\"isError\":true}"; exit 2'
# mcp_fail forms.
add_tool failtyped 'mcp_fail --type not_found "nope"'
add_tool failone 'mcp_fail "one arg"'
add_tool failnumeric 'n=42; mcp_fail "${n}"'
add_tool failinvalid 'mcp_fail -32602 "bad arg"'
add_tool fail404 'mcp_fail 404 "gone"'
add_tool faildash 'mcp_fail -- "--type"'
# Output limits and outputSchema.
add_tool bigout 'head -c 4000 /dev/zero | tr "\0" "x"; echo'
add_tool schemamismatch 'mcp_result_json "$(mcp_json_obj other hi)"' '{"type":"object","required":["greeting"],"properties":{"greeting":{"type":"string"}}}'
add_tool schemanotjson 'echo "not json"' '{"type":"object","required":["greeting"],"properties":{"greeting":{"type":"string"}}}'

ids="plainexit stderrexit stdoutcode stdoutcodeok payloadexit ownresult failtyped failone failnumeric failinvalid fail404 faildash bigout schemamismatch schemanotjson"
REQ="${TEST_TMPDIR}/requests.ndjson"
{
	printf '%s\n' '{"jsonrpc":"2.0","id":"init","method":"initialize","params":{}}'
	printf '%s\n' '{"jsonrpc":"2.0","method":"notifications/initialized"}'
	for id in ${ids}; do
		printf '{"jsonrpc":"2.0","id":"%s","method":"tools/call","params":{"name":"%s","arguments":{}}}\n' "${id}" "${id}"
	done
} >"${REQ}"

OUT="${TEST_TMPDIR}/responses.ndjson"
MCPBASH_TOOL_ALLOWLIST='*' MCPBASH_MAX_TOOL_OUTPUT_SIZE=1000 test_run_mcp "${WS}" "${REQ}" "${OUT}"
assert_json_lines "${OUT}"

resp() { jq -c --arg id "$1" 'select(.id == $id)' "${OUT}"; }

# check_error ID TYPE TEXT: an isError result (no JSON-RPC error) whose
# _meta["mcpbash/error"].type is TYPE and whose first text block contains TEXT.
check_error() {
	local id="$1" type="$2" text="$3" r
	r="$(resp "${id}")"
	[ -n "${r}" ] || test_fail "${id}: no response"
	if printf '%s' "${r}" | jq -e 'has("error")' >/dev/null; then
		test_fail "${id}: JSON-RPC error instead of an isError result: ${r}"
	fi
	printf '%s' "${r}" | jq -e '.result.isError == true' >/dev/null || test_fail "${id}: isError is not true: ${r}"
	printf '%s' "${r}" | jq -e '.result | has("structuredContent") | not' >/dev/null || test_fail "${id}: error result carries structuredContent: ${r}"
	assert_eq "${type}" "$(printf '%s' "${r}" | jq -r '.result._meta["mcpbash/error"].type // empty')" "${id}: error type"
	case "$(printf '%s' "${r}" | jq -r '.result.content[0].text // empty')" in
	*"${text}"*) ;;
	*) test_fail "${id}: text does not contain '${text}': ${r}" ;;
	esac
}

check_error plainexit tool_failed "plain"
check_error stderrexit tool_failed "to-stderr"
check_error stdoutcode tool_failed "custom"
check_error payloadexit tool_failed "real-error"
check_error failtyped not_found "nope"
check_error failone tool_failed "one arg"
check_error failnumeric tool_failed "42"
check_error failinvalid invalid_args "bad arg"
check_error fail404 tool_failed "gone"
check_error faildash tool_failed "--type"
check_error bigout output_too_large "1000"
check_error schemamismatch output_schema "outputSchema"
check_error schemanotjson output_schema "outputSchema"

# Exit codes are the tool's real ones.
assert_eq "3" "$(resp plainexit | jq -r '.result._meta.exitCode')" "plainexit: _meta.exitCode"
assert_eq "1" "$(resp failtyped | jq -r '.result._meta.exitCode')" "failtyped: _meta.exitCode (mcp_fail exits 1)"

# The tool's own error result is passed through.
r="$(resp ownresult)"
printf '%s' "${r}" | jq -e '(has("error") | not) and .result.isError == true and .result.content[0].text == "own"' >/dev/null \
	|| test_fail "ownresult: the tool's own error result was not used: ${r}"

# A 1.x error object with exit 0 is plain output, unchanged.
r="$(resp stdoutcodeok)"
printf '%s' "${r}" | jq -e '.result.isError == false and .result.structuredContent.code == -32001' >/dev/null \
	|| test_fail "stdoutcodeok: ordinary output changed: ${r}"

# The removed numeric form says so on the tool's stderr, for the developer.
case "$(resp failinvalid | jq -r '.result._meta.stderr // empty')" in
*"removed in mcp-bash 2.0"*) ;;
*) test_fail "numeric mcp_fail: no removal note in the tool's stderr: $(resp failinvalid)" ;;
esac

printf 'Tool error model checks passed.\n'
