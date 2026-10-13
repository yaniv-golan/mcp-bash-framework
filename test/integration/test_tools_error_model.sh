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
ids=""
add_tool() {
	local name="$1" body="$2" schema="${3:-}"
	ids="${ids} ${name}"
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
# The same with structuredContent that doesn't match the tool's outputSchema:
# it is an error result anyway, so its own text is kept.
add_tool ownresultschema 'printf "%s\n" "{\"content\":[{\"type\":\"text\",\"text\":\"own schema\"}],\"isError\":false,\"structuredContent\":{\"x\":1}}"; exit 2' '{"type":"object","required":["greeting"],"properties":{"greeting":{"type":"string"}}}'
# The side channel as a 1.x SDK wrote it ({code, message}), or plain text.
# shellcheck disable=SC2016  # Literals for the generated tool scripts
add_tool sidevendored 'printf "%s" "{\"code\":-32602,\"message\":\"vendored\"}" >"${MCP_TOOL_ERROR_FILE}"; echo warn-line >&2; exit 1'
# shellcheck disable=SC2016
add_tool sideraw 'printf "raw side text" >"${MCP_TOOL_ERROR_FILE}"; exit 1'
# shellcheck disable=SC2016
add_tool sidebig 'm="$(head -c 9000 /dev/zero | tr "\\0" m)"; d="$(head -c 100000 /dev/zero | tr "\\0" d)"; printf "{\"code\":1,\"message\":\"%s\",\"data\":\"%s\"}" "${m}" "${d}" >"${MCP_TOOL_ERROR_FILE}"; exit 1'
# mcp_fail forms.
add_tool failtyped 'mcp_fail --type not_found "nope"'
add_tool failone 'mcp_fail "one arg"'
add_tool failnumeric 'n=42; mcp_fail "${n}"'
add_tool failinvalid 'mcp_fail -32602 "bad arg"'
add_tool fail404 'mcp_fail 404 "gone"'
add_tool faildash 'mcp_fail -- "--type"'
# Bytes that aren't valid UTF-8 don't cut the text short (BSD tr stops at
# the first one in a UTF-8 locale).
add_tool badutf8err 'printf "bad \\377\\376 utf ok\\n" >&2; exit 4'
add_tool badutf8out 'printf "out \\377\\376 bytes ok\\n"; exit 4'
# Output limits and outputSchema.
add_tool bigout 'head -c 4000 /dev/zero | tr "\0" "x"; echo'
add_tool schemamismatch 'mcp_result_json "$(mcp_json_obj other hi)"' '{"type":"object","required":["greeting"],"properties":{"greeting":{"type":"string"}}}'
add_tool schemanotjson 'echo "not json"' '{"type":"object","required":["greeting"],"properties":{"greeting":{"type":"string"}}}'
# Valid JSON that isn't an object, for an object schema, is a mismatch too.
add_tool schemaarray "echo '[1,2]'" '{"type":"object","required":["greeting"],"properties":{"greeting":{"type":"string"}}}'
add_tool schemastring "echo '\"hi\"'" '{"type":"object","required":["greeting"],"properties":{"greeting":{"type":"string"}}}'
add_tool schemanumber 'echo 42' '{"type":"object","properties":{"greeting":{"type":"string"}}}'
add_tool schemactrarray 'echo "{\"content\":[],\"isError\":false,\"structuredContent\":[1]}"' '{"type":"object","required":["greeting"],"properties":{"greeting":{"type":"string"}}}'
# A schema the check can't evaluate is the framework's fault: -32603.
add_tool schemabroken 'mcp_result_json "$(mcp_json_obj greeting hi)"' '{"type":"object","required":"greeting"}'

REQ="${TEST_TMPDIR}/requests.ndjson"
{
	printf '%s\n' '{"jsonrpc":"2.0","id":"init","method":"initialize","params":{}}'
	printf '%s\n' '{"jsonrpc":"2.0","method":"notifications/initialized"}'
	for id in ${ids}; do
		printf '{"jsonrpc":"2.0","id":"%s","method":"tools/call","params":{"name":"%s","arguments":{}}}\n' "${id}" "${id}"
	done
} >"${REQ}"

OUT="${TEST_TMPDIR}/responses.ndjson"
# A UTF-8 locale where one exists (the badutf8 rows need it to mean anything).
utf8_locale=""
for l in C.UTF-8 en_US.UTF-8; do
	if LC_ALL="${l}" locale 2>/dev/null | grep -qi 'utf-\?8'; then
		utf8_locale="${l}"
		break
	fi
done
# Small output and error-text limits keep the oversized rows cheap; responses
# must stay under the output limit too.
LC_ALL="${utf8_locale:-${LC_ALL:-}}" MCPBASH_TOOL_ALLOWLIST='*' MCPBASH_MAX_TOOL_OUTPUT_SIZE=1000 MCPBASH_TOOL_STDERR_TAIL_LIMIT=200 test_run_mcp "${WS}" "${REQ}" "${OUT}"
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
check_error badutf8err tool_failed "utf ok"
check_error badutf8out tool_failed "bytes ok"
check_error bigout output_too_large "1000"
check_error sidevendored invalid_args "vendored"
case "$(resp sidevendored | jq -r '.result._meta.stderr // empty')" in
*warn-line*) ;;
*) test_fail "sidevendored: _meta.stderr lost: $(resp sidevendored)" ;;
esac
check_error sideraw tool_failed "raw side text"
check_error sidebig tool_failed "mmmm"
r="$(resp sidebig)"
[ "$(printf '%s' "${r}" | jq -r '.result.content[0].text | length')" -le 200 ] || test_fail "sidebig: text not capped"
printf '%s' "${r}" | jq -e '.result._meta["mcpbash/error"] | has("data") | not' >/dev/null || test_fail "sidebig: oversized data kept"
check_error schemamismatch output_schema "outputSchema"
check_error schemanotjson output_schema "outputSchema"
check_error schemaarray output_schema "outputSchema"
check_error schemastring output_schema "outputSchema"
check_error schemanumber output_schema "outputSchema"
check_error schemactrarray output_schema "outputSchema"
assert_eq "-32603" "$(resp schemabroken | jq -r '.error.code // empty')" "schemabroken: a check that can't run stays a JSON-RPC error"

# Exit codes are the tool's real ones.
assert_eq "3" "$(resp plainexit | jq -r '.result._meta.exitCode')" "plainexit: _meta.exitCode"
assert_eq "1" "$(resp failtyped | jq -r '.result._meta.exitCode')" "failtyped: _meta.exitCode (mcp_fail exits 1)"

# The tool's own error result is passed through.
r="$(resp ownresult)"
printf '%s' "${r}" | jq -e '(has("error") | not) and .result.isError == true and .result.content[0].text == "own"' >/dev/null \
	|| test_fail "ownresult: the tool's own error result was not used: ${r}"

r="$(resp ownresultschema)"
printf '%s' "${r}" | jq -e '(has("error") | not) and .result.isError == true and .result.content[0].text == "own schema"' >/dev/null \
	|| test_fail "ownresultschema: the tool's own result was replaced: ${r}"

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
