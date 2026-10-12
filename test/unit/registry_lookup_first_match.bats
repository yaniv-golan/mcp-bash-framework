#!/usr/bin/env bats
# Unit layer: registry lookups by name or URI return the first match.
#
# They used to pipe every match from jq into `head -n 1`. Under pipefail, when
# head exits before jq has written everything, jq gets SIGPIPE and the lookup
# took its "not found" branch although a match had been printed. A resource
# read by URI could hit this, since URIs need not be unique.

load '../../node_modules/bats-support/load'
load '../../node_modules/bats-assert/load'
load '../common/fixtures'

setup() {
	set -o pipefail
	# shellcheck source=lib/tools.sh
	# shellcheck disable=SC1091
	. "${MCPBASH_HOME}/lib/tools.sh"
	# shellcheck source=lib/prompts.sh
	# shellcheck disable=SC1091
	. "${MCPBASH_HOME}/lib/prompts.sh"
	# shellcheck source=lib/resources.sh
	# shellcheck disable=SC1091
	. "${MCPBASH_HOME}/lib/resources.sh"
	# shellcheck source=lib/completion.sh
	# shellcheck disable=SC1091
	. "${MCPBASH_HOME}/lib/completion.sh"

	MCPBASH_JSON_TOOL_BIN="${TEST_JSON_TOOL_BIN:-$(command -v jq)}"
	MCPBASH_JSON_TOOL="jq"

	mcp_tools_refresh_registry() { return 0; }
	mcp_prompts_refresh_registry() { return 0; }
	mcp_resources_refresh_registry() { return 0; }
	mcp_completion_refresh_manual() { return 0; }

	local items='[{"name":"a","uri":"file:///dup","n":1},{"name":"a","uri":"file:///dup","n":2}]'
	MCP_TOOLS_REGISTRY_JSON="{\"items\":${items}}"
	MCP_PROMPTS_REGISTRY_JSON="{\"items\":${items}}"
	MCP_RESOURCES_REGISTRY_JSON="{\"items\":${items}}"
	MCP_COMPLETION_MANUAL_REGISTRY_JSON="{\"items\":${items}}"
}

# A head that prints what head prints, then fails as if its writer had been
# cut off; any lookup that still pipes into head reports "not found".
stub_head_sigpipe() {
	head() {
		command head "$@"
		return 141
	}
}

# Runs a lookup and checks it returned the first of the two entries.
assert_first_entry() {
	run "$@"
	assert_success
	run "${MCPBASH_JSON_TOOL_BIN}" -r '.n' <<<"${output}"
	assert_output "1"
}

@test "lookups return the first match without head" {
	stub_head_sigpipe

	assert_first_entry mcp_tools_metadata_for_name a
	assert_first_entry mcp_prompts_metadata_for_name a
	assert_first_entry mcp_resources_metadata_for_name a
	assert_first_entry mcp_resources_metadata_for_uri file:///dup
	assert_first_entry mcp_completion_lookup_manual a
}

@test "lookups still report a missing entry" {
	run mcp_tools_metadata_for_name missing
	assert_failure
	run mcp_resources_metadata_for_uri file:///missing
	assert_failure
	run mcp_completion_lookup_manual missing
	assert_failure
}

@test "resource read by URI finds a duplicated URI with large entries" {
	# Two entries share a URI, each larger than a pipe buffer, so jq is still
	# writing the second when head has read the first.
	# The padding goes in on stdin: Linux caps one argument at 128 KiB.
	MCP_RESOURCES_REGISTRY_JSON="$(
		printf '%*s' 200000 '' | tr ' ' x | "${MCPBASH_JSON_TOOL_BIN}" -cRs \
			'{items: [{name: "one", uri: "file:///dup", pad: .}, {name: "two", uri: "file:///dup", pad: .}]}'
	)"

	run mcp_resources_metadata_for_uri file:///dup
	assert_success
	run "${MCPBASH_JSON_TOOL_BIN}" -r '.name' <<<"${output}"
	assert_output "one"
}
