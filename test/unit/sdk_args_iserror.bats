#!/usr/bin/env bats
# Unit: the SDK's argument helpers (mcp_args_require, mcp_args_int,
# mcp_args_bool, mcp_require_path) and mcp_download_safe_or_fail report a bad
# or missing argument as a tool error result the model can read
# (isError: true, type invalid_args), not a JSON-RPC -32602 error, and end the
# tool even when called inside $(...). Checked through a real stdio session,
# under bash 5 and bash 3.2.

load '../../node_modules/bats-support/load'
load '../../node_modules/bats-assert/load'
load '../common/fixtures'

setup() {
	command -v jq >/dev/null 2>&1 || skip "jq required"
	PROJ="${BATS_TEST_TMPDIR}/proj"
	(cd "${BATS_TEST_TMPDIR}" && mcp-bash new proj </dev/null >/dev/null 2>&1) || skip "mcp-bash new unavailable"
	rm -rf "${PROJ}/tools/hello"
	mkdir -p "${PROJ}/tools/proj-args"
	cat >"${PROJ}/tools/proj-args/tool.meta.json" <<'JSON'
{"name":"proj-args","description":"arg helpers","inputSchema":{"type":"object","properties":{"case":{"type":"string"}}}}
JSON
	cat >"${PROJ}/tools/proj-args/tool.sh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
source "${MCP_SDK:?}/tool-sdk.sh"
case "$(mcp_args_get '.case')" in
require) v="$(mcp_args_require '.missing')" ;;
int) v="$(mcp_args_int '.missing')" ;;
int_range) v="$(mcp_args_int '.case' --default 5 --min 10 --max 1)" ;;
bool) v="$(mcp_args_bool '.missing')" ;;
path) v="$(mcp_require_path '.missing')" ;;
download) v="$(mcp_download_safe_or_fail --url "http://example.invalid/" --out "${MCPBASH_TMP_ROOT:-/tmp}/dl.out")" ;;
esac
# Must never run: the helper ends the tool.
echo "REACHED ${v:-}" >&2
mcp_result_text "should not get here"
SH
	chmod +x "${PROJ}/tools/proj-args/tool.sh"
	SHIM="${BATS_TEST_TMPDIR}/bash32"
	mkdir -p "${SHIM}"
	ln -s /bin/bash "${SHIM}/bash"
}

# One stdio session: initialize, then tools/call with {"case": CASE}.
call_case() {
	local case_name="$1" path_prefix="${2:-}"
	printf '%s\n' \
		'{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"t","version":"0"}}}' \
		'{"jsonrpc":"2.0","method":"notifications/initialized"}' \
		"{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/call\",\"params\":{\"name\":\"proj-args\",\"arguments\":{\"case\":\"${case_name}\"}}}" \
		| env PATH="${path_prefix}${PATH}" MCPBASH_PROJECT_ROOT="${PROJ}" MCPBASH_TOOL_ALLOWLIST="*" mcp-bash 2>/dev/null \
		| jq -c 'select(.id == 2)'
}

check_case() {
	local case_name="$1" want_text="$2" path_prefix="${3:-}"
	local resp
	resp="$(call_case "${case_name}" "${path_prefix}")"
	[ -n "${resp}" ] || fail "no response for ${case_name}"
	assert_equal "$(printf '%s' "${resp}" | jq -r 'has("error")')" "false"
	assert_equal "$(printf '%s' "${resp}" | jq -r '.result.isError')" "true"
	assert_equal "$(printf '%s' "${resp}" | jq -r '.result._meta["mcpbash/error"].type')" "invalid_args"
	[[ "$(printf '%s' "${resp}" | jq -r '.result.content[0].text')" == *"${want_text}"* ]] ||
		fail "${case_name}: text was $(printf '%s' "${resp}" | jq -r '.result.content[0].text')"
	[[ "$(printf '%s' "${resp}" | jq -r '.result.content[0].text')" != *"should not get here"* ]] ||
		fail "${case_name}: tool kept running"
}

@test "args iserror: mcp_args_require" { check_case require ".missing is required"; }
@test "args iserror: mcp_args_int (missing)" { check_case int ".missing is required"; }
@test "args iserror: mcp_args_int (bad bounds)" { check_case int_range "--min cannot exceed --max"; }
@test "args iserror: mcp_args_bool" { check_case bool ".missing"; }
@test "args iserror: mcp_require_path" { check_case path ".missing"; }
@test "args iserror: mcp_download_safe_or_fail" { check_case download "Download failed"; }

@test "args iserror: same under bash 3.2" {
	/bin/bash -c '[ "${BASH_VERSINFO[0]}" -eq 3 ]' 2>/dev/null || skip "no bash 3.2 at /bin/bash"
	local c
	for c in require int bool path; do
		check_case "${c}" ".missing" "${SHIM}:"
	done
}

@test "args iserror: mcp_fail_invalid_args gives an invalid_args error result in 2.0" {
	cat >"${PROJ}/tools/proj-args/tool.sh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
source "${MCP_SDK:?}/tool-sdk.sh"
mcp_fail_invalid_args "explicit legacy call"
SH
	resp="$(call_case any)"
	assert_equal "$(printf '%s' "${resp}" | jq -c '[has("error"), .result.isError, .result._meta["mcpbash/error"].type, .result.content[0].text]')" '[false,true,"invalid_args","explicit legacy call"]'
}

@test "args iserror: SDK loaded without tool-error.sh falls back to a bare error result" {
	d="${BATS_TEST_TMPDIR}/sdk_alone"
	mkdir -p "${d}"
	cp "${MCPBASH_HOME}/sdk/tool-sdk.sh" "${d}/"
	run bash -c '. "$1/tool-sdk.sh" 2>/dev/null; mcp_args_require ".missing"' _ "${d}"
	assert_failure
	assert_equal "$(printf '%s\n' "${output}" | head -n 1 | jq -c '[.isError, (.code // null)]')" '[true,null]'
}
