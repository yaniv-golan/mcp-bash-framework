#!/usr/bin/env bats
# Unit layer: notification consume behavior tests.

load '../../node_modules/bats-support/load'
load '../../node_modules/bats-assert/load'
load '../common/fixtures'

setup() {
	MCPBASH_JSON_TOOL_BIN="jq"

	# shellcheck source=lib/tools.sh
	# shellcheck disable=SC1091
	. "${MCPBASH_HOME}/lib/tools.sh"
	# shellcheck source=lib/resources.sh
	# shellcheck disable=SC1091
	. "${MCPBASH_HOME}/lib/resources.sh"
}

@test "notification: consume_notification with emit=false does not update state" {
	MCP_TOOLS_REGISTRY_HASH="abc123"
	MCP_TOOLS_LAST_NOTIFIED_HASH=""
	MCP_TOOLS_CHANGED=true
	_MCP_NOTIFICATION_PAYLOAD=""

	mcp_tools_consume_notification false

	assert_equal "" "${_MCP_NOTIFICATION_PAYLOAD}"
	assert_equal "" "${MCP_TOOLS_LAST_NOTIFIED_HASH}"
}

@test "notification: consume_notification with emit=true updates state" {
	MCP_TOOLS_REGISTRY_HASH="abc123"
	MCP_TOOLS_LAST_NOTIFIED_HASH=""
	MCP_TOOLS_CHANGED=true
	_MCP_NOTIFICATION_PAYLOAD=""

	mcp_tools_consume_notification true

	[[ "${_MCP_NOTIFICATION_PAYLOAD}" == *"list_changed"* ]]
	assert_equal "abc123" "${MCP_TOOLS_LAST_NOTIFIED_HASH}"
}

@test "notification: does not notify again for same hash" {
	MCP_TOOLS_REGISTRY_HASH="abc123"
	MCP_TOOLS_LAST_NOTIFIED_HASH=""
	MCP_TOOLS_CHANGED=true
	_MCP_NOTIFICATION_PAYLOAD=""

	mcp_tools_consume_notification true
	mcp_tools_consume_notification true

	assert_equal "" "${_MCP_NOTIFICATION_PAYLOAD}"
}

@test "notification: resources consume_notification updates state" {
	MCP_RESOURCES_REGISTRY_HASH="hash1"
	MCP_RESOURCES_LAST_NOTIFIED_HASH=""
	MCP_RESOURCES_CHANGED=true
	_MCP_NOTIFICATION_PAYLOAD=""

	mcp_resources_consume_notification true

	[[ "${_MCP_NOTIFICATION_PAYLOAD}" == *"list_changed"* ]]
	assert_equal "hash1" "${MCP_RESOURCES_LAST_NOTIFIED_HASH}"
}

@test "notification: resources notifies on hash change" {
	MCP_RESOURCES_REGISTRY_HASH="hash1"
	MCP_RESOURCES_LAST_NOTIFIED_HASH=""
	MCP_RESOURCES_CHANGED=true
	_MCP_NOTIFICATION_PAYLOAD=""

	mcp_resources_consume_notification true

	MCP_RESOURCES_REGISTRY_HASH="hash2"
	MCP_RESOURCES_CHANGED=true
	mcp_resources_consume_notification true

	[[ "${_MCP_NOTIFICATION_PAYLOAD}" == *"list_changed"* ]]
	assert_equal "hash2" "${MCP_RESOURCES_LAST_NOTIFIED_HASH}"
}
