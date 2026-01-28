#!/usr/bin/env bats
# Unit tests for tool-UI auto-inference

load '../../node_modules/bats-support/load'
load '../../node_modules/bats-assert/load'
load '../common/fixtures'

setup() {
	# Source required dependencies (following tools_registry_phases.bats pattern)
	# shellcheck disable=SC1091
	. "${MCPBASH_HOME}/lib/hash.sh"
	# shellcheck disable=SC1091
	. "${MCPBASH_HOME}/lib/lock.sh"
	# shellcheck disable=SC1091
	. "${MCPBASH_HOME}/lib/registry.sh"
	# shellcheck disable=SC1091
	. "${MCPBASH_HOME}/lib/tools.sh"

	MCPBASH_JSON_TOOL_BIN="$(command -v jq)"
	MCPBASH_JSON_TOOL="jq"

	# Mock logging functions
	mcp_logging_is_enabled() { return 1; }
	mcp_logging_warning() { return 0; }
	mcp_logging_debug() { return 0; }

	# Set up workspace
	MCPBASH_TMP_ROOT="${BATS_TEST_TMPDIR}"
	MCPBASH_STATE_DIR="${BATS_TEST_TMPDIR}/state"
	MCPBASH_LOCK_ROOT="${BATS_TEST_TMPDIR}/locks"
	MCPBASH_TOOLS_DIR="${BATS_TEST_TMPDIR}/tools"
	MCPBASH_PROJECT_ROOT="${BATS_TEST_TMPDIR}"
	MCP_TOOLS_REGISTRY_PATH="${BATS_TEST_TMPDIR}/tools.json"
	MCP_TOOLS_REGISTRY_JSON=""
	MCP_TOOLS_REGISTRY_HASH=""
	MCP_TOOLS_TOTAL=0

	mkdir -p "${MCPBASH_STATE_DIR}" "${MCPBASH_LOCK_ROOT}" "${MCPBASH_TOOLS_DIR}"
	mcp_lock_init
}

@test "auto-infers _meta.ui when ui/ has index.html" {
	mkdir -p "${MCPBASH_TOOLS_DIR}/my-tool/ui"
	echo '<html></html>' >"${MCPBASH_TOOLS_DIR}/my-tool/ui/index.html"
	echo '{"name":"my-tool","description":"test"}' >"${MCPBASH_TOOLS_DIR}/my-tool/tool.meta.json"
	printf '#!/bin/bash\necho ok' >"${MCPBASH_TOOLS_DIR}/my-tool/tool.sh"
	chmod +x "${MCPBASH_TOOLS_DIR}/my-tool/tool.sh"

	MCPBASH_SERVER_NAME="test-server"
	mcp_tools_scan "${MCPBASH_TOOLS_DIR}"

	local uri
	uri="$(echo "${MCP_TOOLS_REGISTRY_JSON}" | jq -r '.items[0]._meta.ui.resourceUri')"
	assert_equal "ui://test-server/my-tool" "${uri}"

	local vis
	vis="$(echo "${MCP_TOOLS_REGISTRY_JSON}" | jq -c '.items[0]._meta.ui.visibility')"
	assert_equal '["model","app"]' "${vis}"
}

@test "auto-infers _meta.ui when ui/ has ui.meta.json only" {
	mkdir -p "${MCPBASH_TOOLS_DIR}/my-tool/ui"
	echo '{"template":"form"}' >"${MCPBASH_TOOLS_DIR}/my-tool/ui/ui.meta.json"
	echo '{"name":"my-tool"}' >"${MCPBASH_TOOLS_DIR}/my-tool/tool.meta.json"
	printf '#!/bin/bash\necho ok' >"${MCPBASH_TOOLS_DIR}/my-tool/tool.sh"
	chmod +x "${MCPBASH_TOOLS_DIR}/my-tool/tool.sh"

	MCPBASH_SERVER_NAME="test-server"
	mcp_tools_scan "${MCPBASH_TOOLS_DIR}"

	local uri
	uri="$(echo "${MCP_TOOLS_REGISTRY_JSON}" | jq -r '.items[0]._meta.ui.resourceUri')"
	assert_equal "ui://test-server/my-tool" "${uri}"
}

@test "auto-infers _meta.ui when ui/ has both index.html and ui.meta.json" {
	mkdir -p "${MCPBASH_TOOLS_DIR}/my-tool/ui"
	echo '<html></html>' >"${MCPBASH_TOOLS_DIR}/my-tool/ui/index.html"
	echo '{"description":"My UI"}' >"${MCPBASH_TOOLS_DIR}/my-tool/ui/ui.meta.json"
	echo '{"name":"my-tool"}' >"${MCPBASH_TOOLS_DIR}/my-tool/tool.meta.json"
	printf '#!/bin/bash\necho ok' >"${MCPBASH_TOOLS_DIR}/my-tool/tool.sh"
	chmod +x "${MCPBASH_TOOLS_DIR}/my-tool/tool.sh"

	MCPBASH_SERVER_NAME="test-server"
	mcp_tools_scan "${MCPBASH_TOOLS_DIR}"

	local uri
	uri="$(echo "${MCP_TOOLS_REGISTRY_JSON}" | jq -r '.items[0]._meta.ui.resourceUri')"
	assert_equal "ui://test-server/my-tool" "${uri}"
}

@test "auto-infers _meta.ui when no tool.meta.json" {
	mkdir -p "${MCPBASH_TOOLS_DIR}/my-tool/ui"
	echo '<html></html>' >"${MCPBASH_TOOLS_DIR}/my-tool/ui/index.html"
	# Tool with mcp: header comment but no tool.meta.json
	cat >"${MCPBASH_TOOLS_DIR}/my-tool/tool.sh" <<'EOF'
#!/bin/bash
# mcp:{"name":"my-tool","description":"A tool"}
echo ok
EOF
	chmod +x "${MCPBASH_TOOLS_DIR}/my-tool/tool.sh"

	MCPBASH_SERVER_NAME="test-server"
	mcp_tools_scan "${MCPBASH_TOOLS_DIR}"

	local uri
	uri="$(echo "${MCP_TOOLS_REGISTRY_JSON}" | jq -r '.items[0]._meta.ui.resourceUri')"
	assert_equal "ui://test-server/my-tool" "${uri}"
}

@test "preserves explicit resourceUri" {
	mkdir -p "${MCPBASH_TOOLS_DIR}/my-tool/ui"
	echo '<html></html>' >"${MCPBASH_TOOLS_DIR}/my-tool/ui/index.html"
	cat >"${MCPBASH_TOOLS_DIR}/my-tool/tool.meta.json" <<'EOF'
{"name":"my-tool","_meta":{"ui":{"resourceUri":"ui://custom/path"}}}
EOF
	printf '#!/bin/bash\necho ok' >"${MCPBASH_TOOLS_DIR}/my-tool/tool.sh"
	chmod +x "${MCPBASH_TOOLS_DIR}/my-tool/tool.sh"

	mcp_tools_scan "${MCPBASH_TOOLS_DIR}"

	local uri
	uri="$(echo "${MCP_TOOLS_REGISTRY_JSON}" | jq -r '.items[0]._meta.ui.resourceUri')"
	assert_equal "ui://custom/path" "${uri}"
}

@test "preserves custom visibility when auto-generating resourceUri" {
	mkdir -p "${MCPBASH_TOOLS_DIR}/my-tool/ui"
	echo '<html></html>' >"${MCPBASH_TOOLS_DIR}/my-tool/ui/index.html"
	cat >"${MCPBASH_TOOLS_DIR}/my-tool/tool.meta.json" <<'EOF'
{"name":"my-tool","_meta":{"ui":{"visibility":["app"]}}}
EOF
	printf '#!/bin/bash\necho ok' >"${MCPBASH_TOOLS_DIR}/my-tool/tool.sh"
	chmod +x "${MCPBASH_TOOLS_DIR}/my-tool/tool.sh"

	MCPBASH_SERVER_NAME="test-server"
	mcp_tools_scan "${MCPBASH_TOOLS_DIR}"

	local vis
	vis="$(echo "${MCP_TOOLS_REGISTRY_JSON}" | jq -c '.items[0]._meta.ui.visibility')"
	assert_equal '["app"]' "${vis}"

	# resourceUri should still be auto-generated
	local uri
	uri="$(echo "${MCP_TOOLS_REGISTRY_JSON}" | jq -r '.items[0]._meta.ui.resourceUri')"
	assert_equal "ui://test-server/my-tool" "${uri}"
}

@test "no _meta.ui when no ui/ directory" {
	mkdir -p "${MCPBASH_TOOLS_DIR}/my-tool"
	echo '{"name":"my-tool"}' >"${MCPBASH_TOOLS_DIR}/my-tool/tool.meta.json"
	printf '#!/bin/bash\necho ok' >"${MCPBASH_TOOLS_DIR}/my-tool/tool.sh"
	chmod +x "${MCPBASH_TOOLS_DIR}/my-tool/tool.sh"

	mcp_tools_scan "${MCPBASH_TOOLS_DIR}"

	local meta
	meta="$(echo "${MCP_TOOLS_REGISTRY_JSON}" | jq '.items[0]._meta')"
	assert_equal "null" "${meta}"
}

@test "no _meta.ui when ui/ directory is empty" {
	mkdir -p "${MCPBASH_TOOLS_DIR}/my-tool/ui"
	# Empty ui/ directory - no index.html or ui.meta.json
	echo '{"name":"my-tool"}' >"${MCPBASH_TOOLS_DIR}/my-tool/tool.meta.json"
	printf '#!/bin/bash\necho ok' >"${MCPBASH_TOOLS_DIR}/my-tool/tool.sh"
	chmod +x "${MCPBASH_TOOLS_DIR}/my-tool/tool.sh"

	mcp_tools_scan "${MCPBASH_TOOLS_DIR}"

	local meta
	meta="$(echo "${MCP_TOOLS_REGISTRY_JSON}" | jq '.items[0]._meta')"
	assert_equal "null" "${meta}"
}

@test "uses default server name when MCPBASH_SERVER_NAME not set" {
	mkdir -p "${MCPBASH_TOOLS_DIR}/my-tool/ui"
	echo '<html></html>' >"${MCPBASH_TOOLS_DIR}/my-tool/ui/index.html"
	echo '{"name":"my-tool"}' >"${MCPBASH_TOOLS_DIR}/my-tool/tool.meta.json"
	printf '#!/bin/bash\necho ok' >"${MCPBASH_TOOLS_DIR}/my-tool/tool.sh"
	chmod +x "${MCPBASH_TOOLS_DIR}/my-tool/tool.sh"

	unset MCPBASH_SERVER_NAME
	mcp_tools_scan "${MCPBASH_TOOLS_DIR}"

	local uri
	uri="$(echo "${MCP_TOOLS_REGISTRY_JSON}" | jq -r '.items[0]._meta.ui.resourceUri')"
	assert_equal "ui://mcp-server/my-tool" "${uri}"
}

@test "uses directory name not tool name for URI" {
	mkdir -p "${MCPBASH_TOOLS_DIR}/weather-tool/ui"
	echo '<html></html>' >"${MCPBASH_TOOLS_DIR}/weather-tool/ui/index.html"
	# Tool name differs from directory name
	echo '{"name":"get-weather"}' >"${MCPBASH_TOOLS_DIR}/weather-tool/tool.meta.json"
	printf '#!/bin/bash\necho ok' >"${MCPBASH_TOOLS_DIR}/weather-tool/tool.sh"
	chmod +x "${MCPBASH_TOOLS_DIR}/weather-tool/tool.sh"

	MCPBASH_SERVER_NAME="my-server"
	mcp_tools_scan "${MCPBASH_TOOLS_DIR}"

	# URI should use directory name (weather-tool), not tool name (get-weather)
	local uri
	uri="$(echo "${MCP_TOOLS_REGISTRY_JSON}" | jq -r '.items[0]._meta.ui.resourceUri')"
	assert_equal "ui://my-server/weather-tool" "${uri}"
}
