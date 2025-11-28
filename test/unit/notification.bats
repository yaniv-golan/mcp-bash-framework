#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

# shellcheck source=test/common/env.sh
. "${REPO_ROOT}/test/common/env.sh"
# shellcheck source=test/common/assert.sh
. "${REPO_ROOT}/test/common/assert.sh"

# Mock dependencies
MCPBASH_JSON_TOOL_BIN="jq"
MCPBASH_HOME="${REPO_ROOT}"

printf ' -> consume_notification with actually_emit=false does not update state\n'

# Source library to test
# shellcheck source=lib/tools.sh
source "${REPO_ROOT}/lib/tools.sh"

# Simulate a registry with a hash
MCP_TOOLS_REGISTRY_HASH="abc123"
MCP_TOOLS_LAST_NOTIFIED_HASH=""
_MCP_NOTIFICATION_PAYLOAD=""

# Consume with emit=false (protocol suppression)
# This should NOT update state
mcp_tools_consume_notification false

# Should return empty (no notification)
assert_eq "" "${_MCP_NOTIFICATION_PAYLOAD}" "Expected empty payload when emit=false"

# State should NOT be updated
assert_eq "" "${MCP_TOOLS_LAST_NOTIFIED_HASH}" "State should not change when emit=false"

# Now consume with emit=true
mcp_tools_consume_notification true

# Should return notification JSON
if [[ "${_MCP_NOTIFICATION_PAYLOAD}" != *"list_changed"* ]]; then
    test_fail "Expected list_changed notification, got: ${_MCP_NOTIFICATION_PAYLOAD}"
fi

# State SHOULD be updated
assert_eq "abc123" "${MCP_TOOLS_LAST_NOTIFIED_HASH}" "State should update when emit=true"

# Consume again with same hash
mcp_tools_consume_notification true
assert_eq "" "${_MCP_NOTIFICATION_PAYLOAD}" "Should not notify again for same hash"


printf ' -> consume_notification updates state correctly (resources)\n'
# Source resources lib
# shellcheck source=lib/resources.sh
source "${REPO_ROOT}/lib/resources.sh"

MCP_RESOURCES_REGISTRY_HASH="hash1"
MCP_RESOURCES_LAST_NOTIFIED_HASH=""

# First notification
mcp_resources_consume_notification true
if [[ "${_MCP_NOTIFICATION_PAYLOAD}" != *"list_changed"* ]]; then
    test_fail "Expected list_changed notification for resources"
fi
assert_eq "hash1" "${MCP_RESOURCES_LAST_NOTIFIED_HASH}" "Resources state should update"

# Hash changes
MCP_RESOURCES_REGISTRY_HASH="hash2"
mcp_resources_consume_notification true
if [[ "${_MCP_NOTIFICATION_PAYLOAD}" != *"list_changed"* ]]; then
    test_fail "Expected list_changed notification after hash change"
fi
assert_eq "hash2" "${MCP_RESOURCES_LAST_NOTIFIED_HASH}" "Resources state should update after change"

printf 'Notification unit tests passed.\n'
