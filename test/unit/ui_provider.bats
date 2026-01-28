#!/usr/bin/env bats
# Unit tests for UI provider and resource resolution

load '../../node_modules/bats-support/load'
load '../../node_modules/bats-assert/load'
load '../common/fixtures'

setup_file() {
	# shellcheck source=lib/runtime.sh
	# shellcheck disable=SC1091
	. "${MCPBASH_HOME}/lib/runtime.sh"
	# shellcheck source=lib/json.sh
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
	# Create temp directory for test fixtures
	TEST_TMPDIR="$(mktemp -d)"
	export TEST_TMPDIR

	# shellcheck source=lib/runtime.sh
	# shellcheck disable=SC1091
	. "${MCPBASH_HOME}/lib/runtime.sh"
	# shellcheck source=lib/json.sh
	# shellcheck disable=SC1091
	. "${MCPBASH_HOME}/lib/json.sh"
	# shellcheck source=lib/ui.sh
	# shellcheck disable=SC1091
	. "${MCPBASH_HOME}/lib/ui.sh"

	# Set up test directories
	MCPBASH_TOOLS_DIR="${TEST_TMPDIR}/tools"
	MCPBASH_UI_DIR="${TEST_TMPDIR}/ui"
	MCPBASH_REGISTRY_DIR="${TEST_TMPDIR}/.registry"
	MCPBASH_STATE_DIR="${TEST_TMPDIR}/.state"
	MCPBASH_SERVER_NAME="test-server"
	mkdir -p "${MCPBASH_TOOLS_DIR}" "${MCPBASH_UI_DIR}" "${MCPBASH_REGISTRY_DIR}" "${MCPBASH_STATE_DIR}"
	export MCPBASH_TOOLS_DIR MCPBASH_UI_DIR MCPBASH_REGISTRY_DIR MCPBASH_STATE_DIR MCPBASH_SERVER_NAME
}

teardown() {
	[ -d "${TEST_TMPDIR}" ] && rm -rf "${TEST_TMPDIR}"
}

@test "ui: resolves tool-specific UI" {
	mkdir -p "${MCPBASH_TOOLS_DIR}/my-tool/ui"
	printf '<html>test</html>' > "${MCPBASH_TOOLS_DIR}/my-tool/ui/index.html"

	# Test discovery via lib/ui.sh
	mcp_ui_generate_registry
	result="$(mcp_ui_get_path_from_registry "my-tool")"
	assert_equal "${result}" "${MCPBASH_TOOLS_DIR}/my-tool/ui/index.html"
}

@test "ui: resolves standalone UI" {
	mkdir -p "${MCPBASH_UI_DIR}/dashboard"
	printf '<html>dashboard</html>' > "${MCPBASH_UI_DIR}/dashboard/index.html"

	mcp_ui_generate_registry
	result="$(mcp_ui_get_path_from_registry "dashboard")"
	assert_equal "${result}" "${MCPBASH_UI_DIR}/dashboard/index.html"
}

@test "ui: returns error for missing resource" {
	mcp_ui_generate_registry
	run mcp_ui_get_path_from_registry "nonexistent"
	assert_failure
}

@test "ui: discovers resources from both tools and ui directories" {
	# Create tool-specific UI
	mkdir -p "${MCPBASH_TOOLS_DIR}/query/ui"
	printf '<html>query</html>' > "${MCPBASH_TOOLS_DIR}/query/ui/index.html"

	# Create standalone UI
	mkdir -p "${MCPBASH_UI_DIR}/settings"
	printf '<html>settings</html>' > "${MCPBASH_UI_DIR}/settings/index.html"

	mcp_ui_generate_registry
	local count
	count="$(mcp_ui_count)"
	assert_equal "${count}" "2"
}

@test "ui: prefers tool-specific UI over standalone with same name" {
	# Create both with same name
	mkdir -p "${MCPBASH_TOOLS_DIR}/dashboard/ui"
	printf '<html>tool-dashboard</html>' > "${MCPBASH_TOOLS_DIR}/dashboard/ui/index.html"

	mkdir -p "${MCPBASH_UI_DIR}/dashboard"
	printf '<html>standalone-dashboard</html>' > "${MCPBASH_UI_DIR}/dashboard/index.html"

	mcp_ui_generate_registry

	# Should resolve to tool version
	result="$(mcp_ui_get_path_from_registry "dashboard")"
	assert_equal "${result}" "${MCPBASH_TOOLS_DIR}/dashboard/ui/index.html"

	# Should only count once (no duplicate)
	local count
	count="$(mcp_ui_count)"
	assert_equal "${count}" "1"
}

@test "ui: parses ui.meta.json correctly" {
	mkdir -p "${MCPBASH_UI_DIR}/configured"
	printf '<html>configured</html>' > "${MCPBASH_UI_DIR}/configured/index.html"
	cat > "${MCPBASH_UI_DIR}/configured/ui.meta.json" << 'EOF'
{
  "description": "A configured UI resource",
  "meta": {
    "csp": {
      "connectDomains": ["api.example.com"]
    },
    "permissions": {
      "clipboardWrite": {}
    },
    "prefersBorder": false
  }
}
EOF

	mcp_ui_generate_registry

	local metadata
	metadata="$(mcp_ui_get_metadata "configured")"

	# Check CSP
	local connect_domains
	connect_domains="$("${MCPBASH_JSON_TOOL_BIN}" -r '.csp.connectDomains[0]' <<< "${metadata}")"
	assert_equal "${connect_domains}" "api.example.com"

	# Check prefersBorder
	local prefers_border
	prefers_border="$("${MCPBASH_JSON_TOOL_BIN}" -r '.prefersBorder' <<< "${metadata}")"
	assert_equal "${prefers_border}" "false"
}

@test "ui: generates correct URI format" {
	mkdir -p "${MCPBASH_UI_DIR}/test-resource"
	printf '<html>test</html>' > "${MCPBASH_UI_DIR}/test-resource/index.html"

	mcp_ui_generate_registry

	local resources
	resources="$(mcp_ui_list)"
	local uri
	uri="$("${MCPBASH_JSON_TOOL_BIN}" -r '.[0].uri' <<< "${resources}")"
	assert_equal "${uri}" "ui://test-server/test-resource"
}

@test "ui: registry includes mimeType" {
	mkdir -p "${MCPBASH_UI_DIR}/typed"
	printf '<html>typed</html>' > "${MCPBASH_UI_DIR}/typed/index.html"

	mcp_ui_generate_registry

	local resources
	resources="$(mcp_ui_list)"
	local mime_type
	mime_type="$("${MCPBASH_JSON_TOOL_BIN}" -r '.[0].mimeType' <<< "${resources}")"
	assert_equal "${mime_type}" "text/html;profile=mcp-app"
}
