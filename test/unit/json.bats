#!/usr/bin/env bats
# Spec §18.2 (Unit layer): validate JSON helpers.

load '../../node_modules/bats-support/load'
load '../../node_modules/bats-assert/load'
load '../common/fixtures'

setup_file() {
	# shellcheck source=lib/runtime.sh
	# shellcheck disable=SC1091
	. "${MCPBASH_HOME}/lib/runtime.sh"
	# shellcheck source=lib/json.sh
	# shellcheck disable=SC1091
	. "${MCPBASH_HOME}/lib/json.sh"

	MCPBASH_FORCE_MINIMAL=false
	mcp_runtime_detect_json_tool
	if [ "${MCPBASH_MODE}" = "minimal" ]; then
		skip "JSON tooling unavailable for normalization test"
	fi
	export MCPBASH_MODE MCPBASH_JSON_TOOL MCPBASH_JSON_TOOL_BIN
}

setup() {
	# Re-source for each test since bats runs tests in subshells
	# shellcheck source=lib/runtime.sh
	# shellcheck disable=SC1091
	. "${MCPBASH_HOME}/lib/runtime.sh"
	# shellcheck source=lib/json.sh
	# shellcheck disable=SC1091
	. "${MCPBASH_HOME}/lib/json.sh"
}

@test "json: normalize with jq/gojq" {
	MCPBASH_FORCE_MINIMAL=false
	mcp_runtime_detect_json_tool
	if [ "${MCPBASH_MODE}" = "minimal" ]; then
		skip "JSON tooling unavailable"
	fi

	normalized="$(mcp_json_normalize_line $' {"foo":1,\n"bar":2 }\n')"
	assert_equal '{"bar":2,"foo":1}' "${normalized}"
}

@test "json: detect arrays" {
	MCPBASH_FORCE_MINIMAL=false
	mcp_runtime_detect_json_tool
	if [ "${MCPBASH_MODE}" = "minimal" ]; then
		skip "JSON tooling unavailable"
	fi

	run mcp_json_is_array '[]'
	assert_success

	run mcp_json_is_array '{"a":1}'
	assert_failure
}

@test "json: minimal mode passthrough and validation" {
	MCPBASH_MODE="minimal"
	minimal="$(mcp_json_normalize_line '{"jsonrpc":"2.0","method":"ping"}')"
	assert_equal '{"jsonrpc":"2.0","method":"ping"}' "${minimal}"

	run mcp_json_normalize_line '{"jsonrpc":2}'
	assert_failure
}

@test "json: BOM and whitespace trimming" {
	MCPBASH_FORCE_MINIMAL=false
	mcp_runtime_detect_json_tool
	if [ "${MCPBASH_MODE}" = "minimal" ]; then
		skip "JSON tooling unavailable"
	fi

	bom_line=$'\xEF\xBB\xBF  {"jsonrpc":"2.0","method":"ping"}  \n'
	trimmed="$(MCPBASH_MODE="full" MCPBASH_JSON_TOOL="gojq" MCPBASH_JSON_TOOL_BIN="${MCPBASH_JSON_TOOL_BIN}" mcp_json_normalize_line "${bom_line}")"
	assert_equal '{"jsonrpc":"2.0","method":"ping"}' "${trimmed}"
}

@test "json: mcp_json_quote_text keeps non-ASCII text intact under /bin/bash (3.2 on macOS)" {
	[ -x /bin/bash ] || skip "/bin/bash not available"
	run /bin/bash -c '. "$1/lib/json.sh"; mcp_json_quote_text "café – 日本"' _ "${MCPBASH_HOME}"
	assert_success
	assert_output '"café – 日本"'
	run /bin/bash -c '. "$1/lib/json.sh"; mcp_json_quote_text "$(printf "a\tb\001c")"' _ "${MCPBASH_HOME}"
	assert_output '"a\tb\u0001c"'
}

@test "json: mcp_json_quote_text round-trips control characters, backslashes and quotes" {
	local shell_bin original out decoded
	original="$(printf 'tab\there\nnew "quoted" back\\slash \001 bell\b ff\f cr\r end')"
	for shell_bin in bash /bin/bash; do
		[ -x "$(command -v "${shell_bin}")" ] || continue
		out="$("${shell_bin}" -c '. "$1/lib/json.sh"; mcp_json_quote_text "$2"' _ "${MCPBASH_HOME}" "${original}")"
		decoded="$(printf '%s' "${out}" | "${TEST_JSON_TOOL_BIN:-jq}" -j .)" || fail "${shell_bin}: invalid JSON: ${out}"
		assert_equal "${decoded}" "${original}"
	done
}

@test "json: mcp_json_quote_text quotes the empty string under set -u in bash and /bin/bash" {
	# bash 3.2 treats "${arr[@]}" of an empty array as unbound under set -u.
	local shell_bin
	for shell_bin in bash /bin/bash; do
		[ -x "$(command -v "${shell_bin}")" ] || continue
		run "${shell_bin}" -c 'set -euo pipefail; . "$1/lib/json.sh"; mcp_json_quote_text ""; printf "|after"' _ "${MCPBASH_HOME}"
		assert_success
		assert_output '""|after'
	done
}

@test "json: cancel id matches the request id form for string and number ids" {
	MCPBASH_FORCE_MINIMAL=false
	mcp_runtime_detect_json_tool
	if [ "${MCPBASH_MODE}" = "minimal" ]; then
		skip "JSON tooling unavailable"
	fi

	# Worker keys come from mcp_json_extract_id; the cancel id must use the
	# same JSON form or a string id never finds its worker.
	request_id="$(mcp_json_extract_id '{"jsonrpc":"2.0","id":"slow","method":"tools/call"}')"
	cancel_id="$(mcp_json_extract_cancel_id '{"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":"slow"}}')"
	assert_equal '"slow"' "${request_id}"
	assert_equal "${request_id}" "${cancel_id}"

	request_id="$(mcp_json_extract_id '{"jsonrpc":"2.0","id":7,"method":"tools/call"}')"
	cancel_id="$(mcp_json_extract_cancel_id '{"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":7}}')"
	assert_equal '7' "${cancel_id}"
	assert_equal "${request_id}" "${cancel_id}"

	cancel_id="$(mcp_json_extract_cancel_id '{"jsonrpc":"2.0","method":"notifications/cancelled","params":{"id":"legacy"}}')"
	assert_equal '"legacy"' "${cancel_id}"

	run mcp_json_extract_cancel_id '{"jsonrpc":"2.0","method":"notifications/cancelled","params":{}}'
	assert_failure
}
