#!/usr/bin/env bash
set -euo pipefail

# Source libraries FIRST
. lib/runtime.sh
. lib/json.sh
. lib/tools.sh
. handlers/tools.sh # Source handler

# Setup minimal environment
MCPBASH_ROOT="$(pwd)"
export MCPBASH_ROOT
MCPBASH_TMP_ROOT="$(mktemp -d)"
export MCPBASH_TMP_ROOT
export MCPBASH_REGISTRY_DIR="${MCPBASH_TMP_ROOT}/registry"
export MCPBASH_TOOLS_DIR="${MCPBASH_TMP_ROOT}/tools"
mkdir -p "${MCPBASH_REGISTRY_DIR}"
mkdir -p "${MCPBASH_TOOLS_DIR}"

# Mock logging/io
mcp_logging_error() { echo "ERROR: $*" >&2; }
mcp_logging_warning() { echo "WARN: $*" >&2; }
mcp_logging_debug() { echo "DEBUG: $*" >&2; }
mcp_json_quote_text() { printf '"%s"' "$1"; }
mcp_lock_acquire() { :; }
mcp_lock_release() { :; }

# Create dummy tool
TOOL_PATH="${MCPBASH_TOOLS_DIR}/smoke.sh"
cat <<'EOF' >"${TOOL_PATH}"
#!/bin/bash
echo "Hello from smoke tool"
EOF
chmod +x "${TOOL_PATH}"

mkdir -p tools
ln -sf "${TOOL_PATH}" tools/smoke.sh

MCP_TOOLS_REGISTRY_JSON=$(jq -n --arg path "tools/smoke.sh" '{
    version: 1,
    items: [{
        name: "smoke.echo",
        path: $path,
        inputSchema: {},
        timeoutSecs: null
    }],
    total: 1,
    hash: "dummy"
}')
MCP_TOOLS_REGISTRY_HASH="dummy"

mcp_tools_refresh_registry() { return 0; }

# Construct request payload as smoke.sh sends it
PAYLOAD='{"jsonrpc":"2.0","id":"call","method":"tools/call","params":{"name":"smoke.echo","arguments":{}}}'

echo "Running mcp_handle_tools..."
# mcp_handle_tools takes method and full payload
mcp_handle_tools "tools/call" "${PAYLOAD}"

# Cleanup
rm -rf "${MCPBASH_TMP_ROOT}"
rm -f tools/smoke.sh
