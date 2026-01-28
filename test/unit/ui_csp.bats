#!/usr/bin/env bats
# Unit tests for UI CSP header generation

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
		skip "JSON tooling unavailable"
	fi
	export MCPBASH_MODE MCPBASH_JSON_TOOL MCPBASH_JSON_TOOL_BIN
}

setup() {
	TEST_TMPDIR="$(mktemp -d)"
	MCPBASH_STATE_DIR="${TEST_TMPDIR}"
	MCPBASH_REGISTRY_DIR="${TEST_TMPDIR}"
	export TEST_TMPDIR MCPBASH_STATE_DIR MCPBASH_REGISTRY_DIR

	# shellcheck source=lib/runtime.sh
	# shellcheck disable=SC1091
	. "${MCPBASH_HOME}/lib/runtime.sh"
	# shellcheck source=lib/json.sh
	# shellcheck disable=SC1091
	. "${MCPBASH_HOME}/lib/json.sh"
	# shellcheck source=lib/ui.sh
	# shellcheck disable=SC1091
	. "${MCPBASH_HOME}/lib/ui.sh"

	# Reset registry state
	MCP_UI_REGISTRY_JSON=""
	MCP_UI_REGISTRY_HASH=""
	MCP_UI_TOTAL=0

	# Prevent refresh by setting recent scan time
	MCP_UI_LAST_SCAN="$(date +%s 2>/dev/null || printf '0')"
}

teardown() {
	[ -d "${TEST_TMPDIR}" ] && rm -rf "${TEST_TMPDIR}"
}

@test "csp: mcp_ui_get_csp_header returns default when no registry" {
	output="$(mcp_ui_get_csp_header "nonexistent")"

	# Should contain default restrictive CSP directives
	[[ "${output}" == *"default-src 'self'"* ]]
	[[ "${output}" == *"script-src 'self'"* ]]
	[[ "${output}" == *"frame-ancestors 'none'"* ]]
}

@test "csp: mcp_ui_get_csp_header returns default for unknown resource" {
	# Set up empty registry
	MCP_UI_REGISTRY_JSON='{"uiResources":[]}'

	output="$(mcp_ui_get_csp_header "nonexistent")"

	[[ "${output}" == *"default-src 'self'"* ]]
}

@test "csp: mcp_ui_get_csp_header includes connectDomains" {
	# Set up registry with CSP
	MCP_UI_REGISTRY_JSON='{"uiResources":[{"name":"test-ui","csp":{"connectDomains":["api.example.com","ws.example.com"]}}]}'

	output="$(mcp_ui_get_csp_header "test-ui")"

	[[ "${output}" == *"connect-src 'self' api.example.com ws.example.com"* ]]
}

@test "csp: mcp_ui_get_csp_header includes resourceDomains" {
	MCP_UI_REGISTRY_JSON='{"uiResources":[{"name":"test-ui","csp":{"resourceDomains":["cdn.example.com"]}}]}'

	output="$(mcp_ui_get_csp_header "test-ui")"

	[[ "${output}" == *"font-src 'self' cdn.example.com"* ]]
	[[ "${output}" == *"media-src 'self' cdn.example.com"* ]]
}

@test "csp: mcp_ui_get_csp_header includes frameDomains" {
	MCP_UI_REGISTRY_JSON='{"uiResources":[{"name":"test-ui","csp":{"frameDomains":["embed.example.com"]}}]}'

	output="$(mcp_ui_get_csp_header "test-ui")"

	[[ "${output}" == *"frame-src embed.example.com"* ]]
}

@test "csp: mcp_ui_get_csp_header includes baseUriDomains" {
	MCP_UI_REGISTRY_JSON='{"uiResources":[{"name":"test-ui","csp":{"baseUriDomains":["base.example.com"]}}]}'

	output="$(mcp_ui_get_csp_header "test-ui")"

	[[ "${output}" == *"base-uri 'self' base.example.com"* ]]
}

@test "csp: mcp_ui_get_csp_header with empty csp object returns default" {
	MCP_UI_REGISTRY_JSON='{"uiResources":[{"name":"test-ui","csp":{}}]}'

	output="$(mcp_ui_get_csp_header "test-ui")"

	# Should fall back to default
	[[ "${output}" == *"default-src 'self'"* ]]
	[[ "${output}" == *"frame-ancestors 'none'"* ]]
}

@test "csp: mcp_ui_get_csp_header always includes frame-ancestors none" {
	MCP_UI_REGISTRY_JSON='{"uiResources":[{"name":"test-ui","csp":{"connectDomains":["api.example.com"]}}]}'

	output="$(mcp_ui_get_csp_header "test-ui")"

	# frame-ancestors should always be 'none' for security
	[[ "${output}" == *"frame-ancestors 'none'"* ]]
}

@test "csp: mcp_ui_get_csp_header allows jsdelivr for scripts" {
	MCP_UI_REGISTRY_JSON='{"uiResources":[{"name":"test-ui","csp":{"connectDomains":["api.example.com"]}}]}'

	output="$(mcp_ui_get_csp_header "test-ui")"

	# Must allow jsdelivr for MCP Apps SDK
	[[ "${output}" == *"script-src 'self' https://cdn.jsdelivr.net"* ]]
}

@test "csp: mcp_ui_get_csp_meta returns valid JSON" {
	MCP_UI_REGISTRY_JSON='{"uiResources":[{"name":"test-ui","csp":{"connectDomains":["api.example.com"]}}]}'

	output="$(mcp_ui_get_csp_meta "test-ui")"

	# Should be valid JSON
	run "${MCPBASH_JSON_TOOL_BIN}" -e '.' <<< "${output}"
	assert_success

	# Should have required fields
	has_connect="$("${MCPBASH_JSON_TOOL_BIN}" -r '.connectDomains | length' <<< "${output}")"
	[ "${has_connect}" -ge 0 ]
}

@test "csp: mcp_ui_get_csp_meta returns defaults for unknown resource" {
	MCP_UI_REGISTRY_JSON='{"uiResources":[]}'

	output="$(mcp_ui_get_csp_meta "nonexistent")"

	# Should have all required fields as empty arrays
	connect="$("${MCPBASH_JSON_TOOL_BIN}" -r '.connectDomains | length' <<< "${output}")"
	assert_equal "${connect}" "0"

	resource="$("${MCPBASH_JSON_TOOL_BIN}" -r '.resourceDomains | length' <<< "${output}")"
	assert_equal "${resource}" "0"

	frame="$("${MCPBASH_JSON_TOOL_BIN}" -r '.frameDomains | length' <<< "${output}")"
	assert_equal "${frame}" "0"

	base="$("${MCPBASH_JSON_TOOL_BIN}" -r '.baseUriDomains | length' <<< "${output}")"
	assert_equal "${base}" "0"
}

@test "csp: multiple domains are space-separated" {
	MCP_UI_REGISTRY_JSON='{"uiResources":[{"name":"test-ui","csp":{"connectDomains":["a.com","b.com","c.com"]}}]}'

	output="$(mcp_ui_get_csp_header "test-ui")"

	[[ "${output}" == *"connect-src 'self' a.com b.com c.com"* ]]
}
