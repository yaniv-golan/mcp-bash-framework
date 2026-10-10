#!/usr/bin/env bats
# Contract: the frozen API (shipped in 1.8, binding on 2.0).
# Each case compares the helper's output, canonicalised (keys sorted), to a
# golden file under test/fixtures/contract/. The 2.0 branch must keep these
# passing unchanged; only additive optional flags may be added.
# Regenerate a golden file only with a recorded design decision and a
# migrate rule.

load '../../node_modules/bats-support/load'
load '../../node_modules/bats-assert/load'
load '../common/fixtures'

bats_require_minimum_version 1.5.0

setup() {
	command -v jq >/dev/null 2>&1 || skip "jq required"
	JQ="$(command -v jq)"
	GOLDEN="${MCPBASH_HOME}/test/fixtures/contract"
	# A PATH with the usual system tools but no jq/gojq, for "no JSON tool" runs.
	NOJQ="${BATS_TEST_TMPDIR}/nojq-bin"
	mkdir -p "${NOJQ}"
	local d f
	for d in /usr/bin /bin; do
		[ -d "${d}" ] || continue
		for f in "${d}"/*; do
			case "${f##*/}" in jq | gojq) continue ;; esac
			[ -e "${NOJQ}/${f##*/}" ] || ln -s "${f}" "${NOJQ}/${f##*/}" 2>/dev/null || true
		done
	done
}

# Run a frozen helper in a fresh shell with the SDK loaded.
# mode=full uses jq; mode=minimal runs with no JSON tool on PATH.
sdk_run() {
	local mode="$1"
	shift
	if [ "${mode}" = "minimal" ]; then
		MCPBASH_MODE=minimal MCPBASH_JSON_TOOL_BIN="" PATH="${NOJQ}" "${BASH}" -c \
			'. "$1/sdk/tool-sdk.sh" >/dev/null 2>&1; shift; "$@"' _ "${MCPBASH_HOME}" "$@"
	else
		MCPBASH_MODE=full MCPBASH_JSON_TOOL_BIN="${JQ}" "${BASH}" -c \
			'. "$1/sdk/tool-sdk.sh" >/dev/null 2>&1; shift; "$@"' _ "${MCPBASH_HOME}" "$@"
	fi
}

assert_golden() {
	local name="$1" out="$2"
	local got want
	# Sort keys with a filter (works in jq and gojq; gojq has no -S).
	local canon='def k: if type == "object" then to_entries | sort_by(.key) | map(.value |= k) | from_entries elif type == "array" then map(k) else . end; k'
	got="$(printf '%s' "${out}" | "${JQ}" -c "${canon}")" || fail "output is not one JSON value: ${out}"
	want="$("${JQ}" -c "${canon}" "${GOLDEN}/${name}.json")"
	assert_equal "${got}" "${want}"
}

@test "contract: mcp_result_text" {
	out="$(sdk_run full mcp_result_text $'two\nlines "quoted"')"
	assert_golden result_text "${out}"
	out="$(sdk_run minimal mcp_result_text $'two\nlines "quoted"')"
	assert_golden result_text "${out}"
}

@test "contract: mcp_result_json object: no envelope, text is the serialized JSON" {
	out="$(sdk_run full mcp_result_json '{"items":[1,2],"name":"x"}')"
	assert_golden result_json_object "${out}"
}

@test "contract: mcp_result_json non-object on a legacy-era request is text only" {
	out="$(sdk_run full mcp_result_json '[1,2,3]')"
	assert_golden result_json_array_legacy "${out}"
	out="$(sdk_run full mcp_result_json '42')"
	assert_golden result_json_scalar_legacy "${out}"
}

@test "contract: mcp_result_json --max-text-bytes replaces the text with a summary, keeps the data" {
	out="$(sdk_run full mcp_result_json '{"a":1,"b":"xxxxxxxxxxxxxxxxxxxxxxxx"}' --max-text-bytes 10)"
	assert_golden result_json_summary "${out}"
}

@test "contract: mcp_result_json never summarises a value it can't put in structuredContent" {
	out="$(sdk_run full mcp_result_json '[1,2,3]' --max-text-bytes 2)"
	assert_golden result_json_array_legacy "${out}"
}

@test "contract: mcp_result_json invalid JSON is an internal error result" {
	out="$(sdk_run full mcp_result_json '{not json')"
	assert_golden result_json_invalid "${out}"
}

@test "contract: mcp_result_json without a JSON tool passes an object through" {
	out="$(sdk_run minimal mcp_result_json '{"items":[1,2],"name":"x"}')"
	assert_golden result_json_object "${out}"
}

# mcp_fail --type exits NON-ZERO: it must end the tool even inside $(...),
# where exit 0 would only end the subshell and the tool would carry on. The
# result is identical either way: inside the framework it travels through the
# tool-error side channel; here (no framework) it is printed to stdout. The
# message also goes to stderr, so stdout is checked on its own.
@test "contract: mcp_fail --type prints an isError result and exits non-zero" {
	run --separate-stderr sdk_run full mcp_fail --type not_found "No such ticket" --hint "list tickets first" --data '{"id":7}'
	assert_failure
	assert_golden fail_type "${output}"
	run --separate-stderr sdk_run minimal mcp_fail --type not_found "No such ticket" --hint "list tickets first" --data '{"id":7}'
	assert_failure
	assert_golden fail_type "${output}"
}

@test "contract: mcp_fail --type stops the tool" {
	run env MCPBASH_JSON_TOOL_BIN="${JQ}" "${BASH}" -c '. "$1/sdk/tool-sdk.sh" >/dev/null 2>&1; mcp_fail --type internal "stop"; echo AFTER' _ "${MCPBASH_HOME}"
	assert_failure
	refute_output --partial AFTER
}

@test "contract: mcp_tool_error_result" {
	out="$(sdk_run full mcp_tool_error_result invalid_args "limit must be positive" --hint "pass 1-100" --data '{"field":"limit"}')"
	assert_golden tool_error_result "${out}"
}

@test "contract: legacy mcp_fail numeric form is unchanged in 1.x" {
	run sdk_run full mcp_fail -32602 "bad args"
	assert_failure
	assert_equal "$(printf '%s\n' "${output}" | head -n 1 | "${JQ}" -c '{code,message}')" '{"code":-32602,"message":"bad args"}'
}

@test "contract: frozen helpers give the same output under bash 3.2" {
	[ -x /bin/bash ] && /bin/bash -c '[ "${BASH_VERSINFO[0]}" -eq 3 ]' || skip "no bash 3.2 at /bin/bash"
	BASH=/bin/bash
	assert_golden result_text "$(sdk_run full mcp_result_text $'two\nlines "quoted"')"
	assert_golden result_json_object "$(sdk_run full mcp_result_json '{"items":[1,2],"name":"x"}')"
	assert_golden result_json_summary "$(sdk_run full mcp_result_json '{"a":1,"b":"xxxxxxxxxxxxxxxxxxxxxxxx"}' --max-text-bytes 10)"
	run --separate-stderr sdk_run minimal mcp_fail --type not_found "No such ticket" --hint "list tickets first" --data '{"id":7}'
	assert_failure
	assert_golden fail_type "${output}"
}

@test "contract: the server passes frozen results through to the client unchanged" {
	proj="${BATS_TEST_TMPDIR}/proj"
	(cd "${BATS_TEST_TMPDIR}" && mcp-bash new proj >/dev/null 2>&1) || skip "mcp-bash new unavailable"
	mkdir -p "${proj}/tools/frozen"
	cat >"${proj}/tools/frozen/tool.meta.json" <<'JSON'
{"name":"frozen","description":"contract","inputSchema":{"type":"object","properties":{"mode":{"type":"string"}}}}
JSON
	cat >"${proj}/tools/frozen/tool.sh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
source "${MCP_SDK:?}/tool-sdk.sh"
case "$(mcp_args_get '.mode')" in
fail) mcp_fail --type not_found "No such ticket" --hint "list tickets first" --data '{"id":7}' ;;
json) mcp_result_json '{"items":[1,2],"name":"x"}' ;;
text) mcp_result_text $'two\nlines "quoted"' ;;
esac
SH
	chmod +x "${proj}/tools/frozen/tool.sh"
	local mode golden
	for mode in fail json text; do
		case "${mode}" in fail) golden=fail_type ;; json) golden=result_json_object ;; text) golden=result_text ;; esac
		# A real stdio session: initialize, then tools/call.
		run bash -c 'printf "%s\n" \
			"{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"protocolVersion\":\"2025-11-25\",\"capabilities\":{},\"clientInfo\":{\"name\":\"t\",\"version\":\"0\"}}}" \
			"{\"jsonrpc\":\"2.0\",\"method\":\"notifications/initialized\"}" \
			"{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/call\",\"params\":{\"name\":\"frozen\",\"arguments\":{\"mode\":\"$1\"}}}" \
			| MCPBASH_PROJECT_ROOT="$2" MCPBASH_TOOL_ALLOWLIST="*" mcp-bash 2>/dev/null' _ "${mode}" "${proj}"
		local result
		result="$(printf '%s\n' "${output}" | "${JQ}" -c 'select(.id == 2) | .result')"
		[ -n "${result}" ] || fail "no tools/call result for mode=${mode}: ${output}"
		# The server adds its own fields (name, _meta.exitCode, _meta.stderr);
		# the part the helper produced must be intact.
		assert_golden "${golden}" "$(printf '%s' "${result}" | "${JQ}" -c '
			del(.name)
			| if ._meta then ._meta |= del(.exitCode, .stderr) else . end
			| if ._meta == {} then del(._meta) else . end')"
	done
}

