#!/usr/bin/env bats
# Unit tests for UI resource metadata emission (serving path).
# Characterization: the wire carries the author-declared csp object verbatim;
# the server does NOT compile CSP. This is independent of any CSP-string helper.

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
	# Prevent refresh from clobbering the injected registry.
	MCP_UI_LAST_SCAN="$(date +%s 2>/dev/null || printf '0')"
}

teardown() {
	[ -d "${TEST_TMPDIR}" ] && rm -rf "${TEST_TMPDIR}"
}

@test "ui metadata: csp object passes through verbatim (server does not compile it)" {
	MCP_UI_REGISTRY_JSON='{"uiResources":[{"name":"test-ui","csp":{"connectDomains":["api.example.com"],"resourceDomains":["cdn.example.com"]},"permissions":{},"prefersBorder":true}]}'

	run mcp_ui_get_metadata "test-ui"
	assert_success

	local connect resource
	connect="$(printf '%s' "${output}" | "${MCPBASH_JSON_TOOL_BIN}" -c '.csp.connectDomains')"
	resource="$(printf '%s' "${output}" | "${MCPBASH_JSON_TOOL_BIN}" -c '.csp.resourceDomains')"
	assert_equal '["api.example.com"]' "${connect}"
	assert_equal '["cdn.example.com"]' "${resource}"
}
