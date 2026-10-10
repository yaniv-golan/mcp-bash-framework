#!/usr/bin/env bats
# Unit: mcp_fail --type ends the tool with an error result the model can read,
# including when it runs inside $(...) (e.g. a helper function whose output is
# captured). Checked through a real stdio session, under bash 5 and bash 3.2.

load '../../node_modules/bats-support/load'
load '../../node_modules/bats-assert/load'
load '../common/fixtures'

setup() {
	command -v jq >/dev/null 2>&1 || skip "jq required"
	PROJ="${BATS_TEST_TMPDIR}/proj"
	(cd "${BATS_TEST_TMPDIR}" && mcp-bash new proj </dev/null >/dev/null 2>&1) || skip "mcp-bash new unavailable"
	rm -rf "${PROJ}/tools/hello"
	mkdir -p "${PROJ}/tools/proj-fail"
	cat >"${PROJ}/tools/proj-fail/tool.meta.json" <<'JSON'
{"name":"proj-fail","description":"mcp_fail --type","inputSchema":{"type":"object","properties":{"case":{"type":"string"}}}}
JSON
	SHIM="${BATS_TEST_TMPDIR}/bash32"
	mkdir -p "${SHIM}"
	ln -s /bin/bash "${SHIM}/bash"
}

tool_body() {
	{
		printf '%s\n' '#!/usr/bin/env bash'
		cat
	} >"${PROJ}/tools/proj-fail/tool.sh"
	chmod +x "${PROJ}/tools/proj-fail/tool.sh"
}

call() {
	local path_prefix="${1:-}"
	printf '%s\n' \
		'{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"t","version":"0"}}}' \
		'{"jsonrpc":"2.0","method":"notifications/initialized"}' \
		'{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"proj-fail","arguments":{}}}' \
		| env PATH="${path_prefix}${PATH}" MCPBASH_PROJECT_ROOT="${PROJ}" MCPBASH_TOOL_ALLOWLIST="*" mcp-bash 2>/dev/null \
		| jq -c 'select(.id == 2)'
}

expect_error_result() {
	local resp="$1" type="$2" text="$3"
	[ -n "${resp}" ] || fail "no response"
	assert_equal "$(printf '%s' "${resp}" | jq -r 'has("error")')" "false"
	assert_equal "$(printf '%s' "${resp}" | jq -r '.result.isError')" "true"
	assert_equal "$(printf '%s' "${resp}" | jq -r '.result._meta["mcpbash/error"].type')" "${type}"
	assert_equal "$(printf '%s' "${resp}" | jq -r '.result.content[0].text')" "${text}"
}

HELPER_TOOL='set -euo pipefail
source "${MCP_SDK:?}/tool-sdk.sh"
lookup() {
	mcp_fail --type not_found "No such ticket" --hint "list tickets first"
	printf "never"
}
ticket="$(lookup)"
echo "REACHED ${ticket}" >&2
mcp_result_text "should not get here"'

@test "fail --type: called directly, ends the tool with its error result" {
	tool_body <<'SH'
set -euo pipefail
source "${MCP_SDK:?}/tool-sdk.sh"
mcp_fail --type invalid_args "bad input"
mcp_result_text "should not get here"
SH
	expect_error_result "$(call)" invalid_args "bad input"
}

@test "fail --type: inside a helper captured with \$(...), still ends the tool" {
	printf '%s\n' "${HELPER_TOOL}" | tool_body
	expect_error_result "$(call)" not_found $'No such ticket\n\nHint: list tickets first'
}

@test "fail --type: inside \$(...) without set -e, the error result still wins" {
	tool_body <<'SH'
source "${MCP_SDK:?}/tool-sdk.sh"
lookup() { mcp_fail --type not_found "No such ticket"; }
ticket="$(lookup)"
mcp_result_text "later output"
SH
	expect_error_result "$(call)" not_found "No such ticket"
}

@test "fail --type: same under bash 3.2" {
	/bin/bash -c '[ "${BASH_VERSINFO[0]}" -eq 3 ]' 2>/dev/null || skip "no bash 3.2 at /bin/bash"
	printf '%s\n' "${HELPER_TOOL}" | tool_body
	expect_error_result "$(call "${SHIM}:")" not_found $'No such ticket\n\nHint: list tickets first'
}

@test "fail --type: SDK loaded without tool-error.sh falls back to a JSON-RPC error" {
	d="${BATS_TEST_TMPDIR}/sdk_alone"
	mkdir -p "${d}"
	cp "${MCPBASH_HOME}/sdk/tool-sdk.sh" "${d}/"
	run bash -c '. "$1/tool-sdk.sh" 2>/dev/null; mcp_fail --type invalid_args "bad"; echo AFTER' _ "${d}"
	assert_failure
	refute_output --partial AFTER
	assert_equal "$(printf '%s\n' "${output}" | head -n 1 | jq -r '.code')" "-32602"
	run bash -c '. "$1/tool-sdk.sh" 2>/dev/null; mcp_fail --type not_found "gone"' _ "${d}"
	assert_equal "$(printf '%s\n' "${output}" | head -n 1 | jq -r '.code')" "-32603"
}

@test "fail --type: mcp_tool_error_result still only prints (does not end the tool)" {
	tool_body <<'SH'
set -euo pipefail
source "${MCP_SDK:?}/tool-sdk.sh"
r="$(mcp_tool_error_result internal "built")"
mcp_result_text "kept going: $(printf '%s' "${r}" | head -c 12)"
SH
	resp="$(call)"
	assert_equal "$(printf '%s' "${resp}" | jq -r '.result.isError')" "false"
	[[ "$(printf '%s' "${resp}" | jq -r '.result.content[0].text')" == "kept going: "* ]]
}
