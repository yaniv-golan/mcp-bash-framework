#!/usr/bin/env bash
set -euo pipefail
set -x

MCPBASH_ROOT="$(pwd)"
export MCPBASH_ROOT
MCPBASH_TMP_ROOT="$(mktemp -d)"
export MCPBASH_TMP_ROOT
export MCPBASH_REGISTRY_DIR="${MCPBASH_TMP_ROOT}/registry"

mkdir -p "${MCPBASH_REGISTRY_DIR}"

echo "ROOT: ${MCPBASH_ROOT}"

. lib/runtime.sh
. lib/json.sh
. lib/tools.sh
. lib/logging.sh
. lib/io.sh

# Create a dummy tool
mkdir -p "${MCPBASH_TMP_ROOT}/tools"
cat <<'EOF' >"${MCPBASH_TMP_ROOT}/tools/smoke.sh"
#!/bin/bash
echo "Hello from smoke tool"
EOF
chmod +x "${MCPBASH_TMP_ROOT}/tools/smoke.sh"

# Register it manually to bypass scanning for now
MCP_TOOLS_REGISTRY_JSON='{"version":1,"items":[{"name":"smoke.echo","path":"tools/smoke.sh","inputSchema":{},"timeoutSecs":null}],"total":1}'
MCP_TOOLS_REGISTRY_HASH="dummy"

# Mock mcp_tools_metadata_for_name to return correct path
# We use a relative path here because mcp_tools_call prepends MCPBASH_ROOT
# So we need to make sure MCPBASH_ROOT + path points to our temp file
# BUT MCPBASH_ROOT is the workspace. So we can't easily point to /tmp unless we use absolute path hack.
# If tool_path is absolute, ${MCPBASH_ROOT}/${tool_path} will be appended.
# e.g. /workspace//tmp/tools/smoke.sh -> invalid if /workspace doesn't contain /tmp (it doesn't).

# So we need to trick it.
# Let's make the tool inside the workspace.

mkdir -p tools
cat <<'EOF' >tools/smoke.sh
#!/bin/bash
echo "Hello from smoke tool"
EOF
chmod +x tools/smoke.sh

mcp_tools_metadata_for_name() {
	echo "{\"name\":\"smoke.echo\",\"path\":\"tools/smoke.sh\",\"inputSchema\":{},\"timeoutSecs\":null}"
}

# Call it
result=$(mcp_tools_call "smoke.echo" "{}" "")
echo "Result: $result"

rm -rf "${MCPBASH_TMP_ROOT}"
rm -rf tools/smoke.sh
