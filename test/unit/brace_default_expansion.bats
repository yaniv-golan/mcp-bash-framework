#!/usr/bin/env bats
# Unit: "${x:-{}}" appends a stray "}" when x is set; JSON defaults must not.

load '../../node_modules/bats-support/load'
load '../../node_modules/bats-assert/load'
load '../common/fixtures'

@test "brace_default: elicitation init detects URL mode from client capabilities" {
	export MCPBASH_JSON_TOOL="${MCPBASH_JSON_TOOL:-jq}"
	export MCPBASH_JSON_TOOL_BIN="${MCPBASH_JSON_TOOL_BIN:-$(command -v jq)}"
	export MCPBASH_STATE_DIR="${BATS_TEST_TMPDIR}"
	# shellcheck disable=SC1091
	. "${MCPBASH_HOME}/lib/json.sh"
	# shellcheck disable=SC1091
	. "${MCPBASH_HOME}/lib/elicitation.sh"
	mcp_elicitation_init '{"elicitation":{"form":{},"url":{}}}'
	assert_equal "${MCPBASH_CLIENT_ELICIT_FORM}" "1"
	assert_equal "${MCPBASH_CLIENT_ELICIT_URL}" "1"
	mcp_elicitation_init '{"elicitation":{"form":{}}}'
	assert_equal "${MCPBASH_CLIENT_ELICIT_URL}" "0"
	mcp_elicitation_init
	assert_equal "${MCPBASH_CLIENT_SUPPORTS_ELICITATION}" "0"
}

@test "brace_default: SDK config helper reads MCP_CONFIG_JSON intact" {
	export MCPBASH_JSON_TOOL_BIN="${MCPBASH_JSON_TOOL_BIN:-$(command -v jq)}"
	# shellcheck disable=SC1091
	. "${MCPBASH_HOME}/sdk/tool-sdk.sh"
	MCP_CONFIG_JSON='{"api":{"url":"https://example.test"}}' run mcp_config_get '.api.url'
	assert_success
	assert_output "https://example.test"
}

@test "brace_default: no JSON default uses the \${x:-{}} form" {
	run grep -rn ':-{}}' "${MCPBASH_HOME}/lib" "${MCPBASH_HOME}/sdk" "${MCPBASH_HOME}/handlers" "${MCPBASH_HOME}/providers" "${MCPBASH_HOME}/bin" "${MCPBASH_HOME}/scaffold" "${MCPBASH_HOME}/examples" "${MCPBASH_HOME}/test/common"
	assert_failure
}
