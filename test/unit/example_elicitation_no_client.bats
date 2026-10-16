#!/usr/bin/env bats
# Unit: the elicitation example degrades cleanly when the client cannot elicit.
# The question helpers exit 1 with MCP_ELICIT_ACTION=unavailable; the example
# calls them in an if, so under `set -e` it still returns its own "Stopped"
# result instead of a protocol error.

load '../../node_modules/bats-support/load'
load '../../node_modules/bats-assert/load'
load '../common/fixtures'

@test "example 08: without client elicitation support the tool returns its own result" {
	command -v jq >/dev/null 2>&1 || skip "jq not available"
	run env MCPBASH_TOOL_ALLOWLIST='*' "${MCPBASH_HOME}/bin/mcp-bash" run-tool example-elicitation \
		--project-root "${MCPBASH_HOME}/examples/08-elicitation" --args '{}' --no-elicitation
	assert_success
	# exactly one JSON result on stdout
	assert_equal "$(printf '%s' "${output}" | jq -s 'length' 2>/dev/null)" "1"
	assert_equal "$(printf '%s' "${output}" | jq -r '._mcpToolError // false')" "false"
	assert_equal "$(printf '%s' "${output}" | jq -r '.isError')" "false"
	[[ "$(printf '%s' "${output}" | jq -r '.content[0].text')" == *'Stopped: elicitation action=unavailable'* ]]
}
