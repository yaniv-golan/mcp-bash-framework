#!/usr/bin/env bats
# Unit tests for _meta.ui.domain passthrough (MCP Apps draft field).

load '../../node_modules/bats-support/load'
load '../../node_modules/bats-assert/load'
load '../common/fixtures'

setup_file() {
	# shellcheck disable=SC1091
	. "${MCPBASH_HOME}/lib/runtime.sh"
	# shellcheck disable=SC1091
	. "${MCPBASH_HOME}/lib/json.sh"
	MCPBASH_FORCE_MINIMAL=false
	mcp_runtime_detect_json_tool
	if [ "${MCPBASH_MODE}" = "minimal" ]; then
		skip "JSON tooling unavailable"
	fi
	export MCPBASH_MODE MCPBASH_JSON_TOOL MCPBASH_JSON_TOOL_BIN
}

setup() {
	TEST_TMPDIR="$(mktemp -d)"
	MCPBASH_STATE_DIR="${TEST_TMPDIR}"
	MCPBASH_REGISTRY_DIR="${TEST_TMPDIR}"
	export TEST_TMPDIR MCPBASH_STATE_DIR MCPBASH_REGISTRY_DIR

	# shellcheck disable=SC1091
	. "${MCPBASH_HOME}/lib/runtime.sh"
	# shellcheck disable=SC1091
	. "${MCPBASH_HOME}/lib/json.sh"
	# shellcheck disable=SC1091
	. "${MCPBASH_HOME}/lib/ui.sh"

	MCP_UI_REGISTRY_JSON=""
	MCP_UI_REGISTRY_HASH=""
	MCP_UI_TOTAL=0
	MCP_UI_LAST_SCAN="$(date +%s 2>/dev/null || printf '0')"
}

teardown() {
	[ -d "${TEST_TMPDIR}" ] && rm -rf "${TEST_TMPDIR}"
}

@test "ui domain: parse_resource includes domain when meta.domain set" {
	mkdir -p "${TEST_TMPDIR}/ui/dash"
	printf '%s' '{"meta":{"domain":"https://widgets.example.com"}}' \
		>"${TEST_TMPDIR}/ui/dash/ui.meta.json"

	run mcp_ui_parse_resource "dash" "${TEST_TMPDIR}/ui/dash" "srv"
	assert_success
	local domain
	domain="$(printf '%s' "${output}" | "${MCPBASH_JSON_TOOL_BIN}" -r '.domain // "ABSENT"')"
	assert_equal "https://widgets.example.com" "${domain}"
}

@test "ui domain: parse_resource omits domain when absent (not null)" {
	mkdir -p "${TEST_TMPDIR}/ui/dash"
	printf '%s' '{"meta":{}}' >"${TEST_TMPDIR}/ui/dash/ui.meta.json"

	run mcp_ui_parse_resource "dash" "${TEST_TMPDIR}/ui/dash" "srv"
	assert_success
	local has
	has="$(printf '%s' "${output}" | "${MCPBASH_JSON_TOOL_BIN}" -r 'has("domain")')"
	assert_equal "false" "${has}"
}

@test "ui domain: get_metadata projects domain (read path)" {
	MCP_UI_REGISTRY_JSON='{"uiResources":[{"name":"dash","csp":{},"permissions":{},"prefersBorder":true,"domain":"https://w.example.com"}]}'

	run mcp_ui_get_metadata "dash"
	assert_success
	local domain
	domain="$(printf '%s' "${output}" | "${MCPBASH_JSON_TOOL_BIN}" -r '.domain // "ABSENT"')"
	assert_equal "https://w.example.com" "${domain}"
}

@test "ui domain: get_metadata omits domain when registry entry has none" {
	MCP_UI_REGISTRY_JSON='{"uiResources":[{"name":"dash","csp":{},"permissions":{},"prefersBorder":true}]}'

	run mcp_ui_get_metadata "dash"
	assert_success
	local has
	has="$(printf '%s' "${output}" | "${MCPBASH_JSON_TOOL_BIN}" -r 'has("domain")')"
	assert_equal "false" "${has}"
}

@test "ui sizing: parse_resource carries preferredFrameSize when set" {
	mkdir -p "${TEST_TMPDIR}/ui/dash"
	printf '%s' '{"meta":{"preferredFrameSize":["600px","400px"]}}' \
		>"${TEST_TMPDIR}/ui/dash/ui.meta.json"

	run mcp_ui_parse_resource "dash" "${TEST_TMPDIR}/ui/dash" "srv"
	assert_success
	local pfs
	pfs="$(printf '%s' "${output}" | "${MCPBASH_JSON_TOOL_BIN}" -c '.preferredFrameSize')"
	assert_equal '["600px","400px"]' "${pfs}"
}

@test "ui sizing: parse_resource omits preferredFrameSize when absent" {
	mkdir -p "${TEST_TMPDIR}/ui/dash"
	printf '%s' '{"meta":{}}' >"${TEST_TMPDIR}/ui/dash/ui.meta.json"

	run mcp_ui_parse_resource "dash" "${TEST_TMPDIR}/ui/dash" "srv"
	assert_success
	local has
	has="$(printf '%s' "${output}" | "${MCPBASH_JSON_TOOL_BIN}" -r 'has("preferredFrameSize")')"
	assert_equal "false" "${has}"
}
