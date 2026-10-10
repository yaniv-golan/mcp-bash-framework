#!/usr/bin/env bats
# Unit: the elicitation example degrades cleanly when the client cannot elicit.
# Under `set -e`, a failing mcp_elicit_* inside "$(...)" used to abort the tool
# before it could read .action, so it returned a protocol error instead of its
# own "Stopped" result.

load '../../node_modules/bats-support/load'
load '../../node_modules/bats-assert/load'
load '../common/fixtures'

@test "example 08: without client elicitation support the tool returns its own result" {
	command -v jq >/dev/null 2>&1 || skip "jq not available"
	run env MCPBASH_TOOL_ALLOWLIST='*' "${MCPBASH_HOME}/bin/mcp-bash" run-tool example-elicitation \
		--project-root "${MCPBASH_HOME}/examples/08-elicitation" --args '{}'
	assert_success
	# exactly one JSON result on stdout
	assert_equal "$(printf '%s' "${output}" | jq -s 'length' 2>/dev/null)" "1"
	assert_equal "$(printf '%s' "${output}" | jq -r '._mcpToolError // false')" "false"
	assert_equal "$(printf '%s' "${output}" | jq -r '.isError')" "false"
	[[ "$(printf '%s' "${output}" | jq -r '.content[0].text')" == *'Stopped: elicitation action=decline'* ]]
}
