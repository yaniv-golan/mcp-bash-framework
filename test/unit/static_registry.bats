#!/usr/bin/env bats
# Unit tests for static registry mode (MCPBASH_STATIC_REGISTRY=1).

load '../../node_modules/bats-support/load'
load '../../node_modules/bats-assert/load'
load '../../node_modules/bats-file/load'
load '../common/fixtures'

setup() {
	command -v jq >/dev/null 2>&1 || skip "jq required"

	# shellcheck source=lib/hash.sh
	# shellcheck disable=SC1091
	. "${MCPBASH_HOME}/lib/hash.sh"
	# shellcheck source=lib/lock.sh
	# shellcheck disable=SC1091
	. "${MCPBASH_HOME}/lib/lock.sh"
	# shellcheck source=lib/registry.sh
	# shellcheck disable=SC1091
	. "${MCPBASH_HOME}/lib/registry.sh"
	# shellcheck source=lib/tools.sh
	# shellcheck disable=SC1091
	. "${MCPBASH_HOME}/lib/tools.sh"
	# shellcheck source=lib/resources.sh
	# shellcheck disable=SC1091
	. "${MCPBASH_HOME}/lib/resources.sh"
	# shellcheck source=lib/prompts.sh
	# shellcheck disable=SC1091
	. "${MCPBASH_HOME}/lib/prompts.sh"

	MCPBASH_JSON_TOOL_BIN="$(command -v jq)"
	MCPBASH_JSON_TOOL="jq"
	if ! command -v mcp_logging_is_enabled >/dev/null 2>&1; then
		mcp_logging_is_enabled() { return 1; }
	fi
	if ! command -v mcp_logging_warning >/dev/null 2>&1; then
		mcp_logging_warning() { return 0; }
	fi
	if ! command -v mcp_logging_debug >/dev/null 2>&1; then
		mcp_logging_debug() { return 0; }
	fi
	if ! command -v mcp_logging_info >/dev/null 2>&1; then
		mcp_logging_info() { return 0; }
	fi

	# Stub manual registration to return "skipped" status (return 0 with LAST_APPLIED=false)
	# This simulates no register.json/register.sh defined, allowing tests to focus on static mode
	mcp_registry_register_apply() {
		MCP_REGISTRY_REGISTER_LAST_APPLIED=false
		return 0
	}
	mcp_registry_register_error_for_kind() {
		printf ''
	}

	MCPBASH_TMP_ROOT="${BATS_TEST_TMPDIR}"
	MCPBASH_STATE_DIR="${BATS_TEST_TMPDIR}/state"
	MCPBASH_LOCK_ROOT="${BATS_TEST_TMPDIR}/locks"
	MCPBASH_REGISTRY_DIR="${BATS_TEST_TMPDIR}/.registry"
	MCPBASH_PROJECT_ROOT="${BATS_TEST_TMPDIR}"
	MCPBASH_SERVER_DIR="${BATS_TEST_TMPDIR}/server.d"
	MCPBASH_TOOLS_DIR="${BATS_TEST_TMPDIR}/tools"
	MCPBASH_RESOURCES_DIR="${BATS_TEST_TMPDIR}/resources"
	MCPBASH_PROMPTS_DIR="${BATS_TEST_TMPDIR}/prompts"
	mkdir -p "${MCPBASH_STATE_DIR}" "${MCPBASH_LOCK_ROOT}" "${MCPBASH_REGISTRY_DIR}"
	mkdir -p "${MCPBASH_SERVER_DIR}" "${MCPBASH_TOOLS_DIR}" "${MCPBASH_RESOURCES_DIR}" "${MCPBASH_PROMPTS_DIR}"
	mcp_lock_init
}

teardown() {
	unset MCPBASH_STATIC_REGISTRY MCPBASH_STATIC_REGISTRY_LOGGED
}

# Helper to create valid cache file
create_tools_cache() {
	local total="${1:-1}"
	local format_version="${2:-1}"
	cat >"${MCPBASH_REGISTRY_DIR}/tools.json" <<EOF
{
  "format_version": ${format_version},
  "version": 1,
  "generatedAt": "2025-01-01T00:00:00Z",
  "items": [{"name": "cached-tool", "path": "cached/tool.sh", "inputSchema": {"type": "object"}}],
  "hash": "abc123",
  "total": ${total}
}
EOF
}

create_resources_cache() {
	local total="${1:-1}"
	local format_version="${2:-1}"
	cat >"${MCPBASH_REGISTRY_DIR}/resources.json" <<EOF
{
  "format_version": ${format_version},
  "version": 1,
  "generatedAt": "2025-01-01T00:00:00Z",
  "items": [{"name": "cached-resource", "uri": "file:///test.txt", "mimeType": "text/plain"}],
  "hash": "def456",
  "total": ${total}
}
EOF
}

create_prompts_cache() {
	local total="${1:-1}"
	local format_version="${2:-1}"
	cat >"${MCPBASH_REGISTRY_DIR}/prompts.json" <<EOF
{
  "format_version": ${format_version},
  "version": 1,
  "generatedAt": "2025-01-01T00:00:00Z",
  "items": [{"name": "cached-prompt", "path": "cached/prompt.txt"}],
  "hash": "ghi789",
  "total": ${total}
}
EOF
}

# Create a real tool on disk for scanning
create_tool_on_disk() {
	local name="${1:-disk-tool}"
	mkdir -p "${MCPBASH_TOOLS_DIR}/${name}"
	cat >"${MCPBASH_TOOLS_DIR}/${name}/tool.sh" <<'EOF'
#!/usr/bin/env bash
echo '{"status":"ok"}'
EOF
	chmod +x "${MCPBASH_TOOLS_DIR}/${name}/tool.sh"
}

@test "static_registry: with STATIC=1 and valid cache, returns immediately" {
	create_tools_cache 1
	export MCPBASH_STATIC_REGISTRY=1
	MCP_TOOLS_REGISTRY_JSON=""
	MCP_TOOLS_REGISTRY_PATH="${MCPBASH_REGISTRY_DIR}/tools.json"
	MCP_TOOLS_LAST_SCAN=""
	MCP_TOOLS_TOTAL=0

	mcp_tools_refresh_registry

	# Should have loaded from cache
	assert_equal "1" "${MCP_TOOLS_TOTAL}"
	[[ "${MCP_TOOLS_REGISTRY_JSON}" =~ "cached-tool" ]]
}

@test "static_registry: with STATIC=1 and missing cache, falls back to scan" {
	# No cache file - should discover from disk
	create_tool_on_disk "fallback-tool"
	export MCPBASH_STATIC_REGISTRY=1
	MCP_TOOLS_REGISTRY_JSON=""
	MCP_TOOLS_REGISTRY_PATH="${MCPBASH_REGISTRY_DIR}/tools.json"
	MCP_TOOLS_LAST_SCAN=""
	MCP_TOOLS_TOTAL=0
	MCP_TOOLS_TTL=0

	mcp_tools_refresh_registry || true

	# Should have discovered from disk
	assert_equal "1" "${MCP_TOOLS_TOTAL}"
	[[ "${MCP_TOOLS_REGISTRY_JSON}" =~ "fallback-tool" ]]
}

@test "static_registry: with STATIC=1 and invalid JSON cache, falls back to scan" {
	# Create invalid JSON cache
	echo "not valid json {{{" >"${MCPBASH_REGISTRY_DIR}/tools.json"
	create_tool_on_disk "recovered-tool"
	export MCPBASH_STATIC_REGISTRY=1
	MCP_TOOLS_REGISTRY_JSON=""
	MCP_TOOLS_REGISTRY_PATH="${MCPBASH_REGISTRY_DIR}/tools.json"
	MCP_TOOLS_LAST_SCAN=""
	MCP_TOOLS_TOTAL=0
	MCP_TOOLS_TTL=0

	mcp_tools_refresh_registry || true

	# Should have discovered from disk after invalid cache
	assert_equal "1" "${MCP_TOOLS_TOTAL}"
	[[ "${MCP_TOOLS_REGISTRY_JSON}" =~ "recovered-tool" ]]
}

@test "static_registry: with STATIC=1 but CLI LAST_SCAN=0, still scans" {
	create_tools_cache 1
	create_tool_on_disk "fresh-tool"
	export MCPBASH_STATIC_REGISTRY=1
	MCP_TOOLS_REGISTRY_JSON=""
	MCP_TOOLS_REGISTRY_PATH="${MCPBASH_REGISTRY_DIR}/tools.json"
	# Simulate CLI forced refresh by pre-setting LAST_SCAN=0
	MCP_TOOLS_LAST_SCAN="0"
	MCP_TOOLS_TOTAL=0
	MCP_TOOLS_TTL=0

	mcp_tools_refresh_registry || true

	# Should have scanned despite static mode (CLI override)
	[[ "${MCP_TOOLS_REGISTRY_JSON}" =~ "fresh-tool" ]]
}

@test "static_registry: format_version mismatch falls back to scan" {
	# Create cache with wrong format version
	create_tools_cache 1 99
	create_tool_on_disk "versioned-tool"
	export MCPBASH_STATIC_REGISTRY=1
	MCP_TOOLS_REGISTRY_JSON=""
	MCP_TOOLS_REGISTRY_PATH="${MCPBASH_REGISTRY_DIR}/tools.json"
	MCP_TOOLS_LAST_SCAN=""
	MCP_TOOLS_TOTAL=0
	MCP_TOOLS_TTL=0

	mcp_tools_refresh_registry || true

	# Should have discovered from disk due to version mismatch
	[[ "${MCP_TOOLS_REGISTRY_JSON}" =~ "versioned-tool" ]]
}

@test "static_registry: resource templates respect LAST_SCAN empty vs 0" {
	# Create resource templates cache
	cat >"${MCPBASH_REGISTRY_DIR}/resource-templates.json" <<EOF
{
  "format_version": 1,
  "version": 1,
  "generatedAt": "2025-01-01T00:00:00Z",
  "items": [{"name": "cached-template", "uriTemplate": "file:///{path}"}],
  "hash": "tmpl123",
  "total": 1
}
EOF
	export MCPBASH_STATIC_REGISTRY=1
	MCP_RESOURCES_TEMPLATES_REGISTRY_JSON=""
	MCP_RESOURCES_TEMPLATES_REGISTRY_PATH="${MCPBASH_REGISTRY_DIR}/resource-templates.json"
	MCP_RESOURCES_TEMPLATES_LAST_SCAN=""
	MCP_RESOURCES_TEMPLATES_TOTAL=0

	mcp_resources_templates_refresh_registry

	# Should have loaded from cache
	assert_equal "1" "${MCP_RESOURCES_TEMPLATES_TOTAL}"
	[[ "${MCP_RESOURCES_TEMPLATES_REGISTRY_JSON}" =~ "cached-template" ]]
}

@test "static_registry: multiple registry types load from their own caches" {
	# Create caches for all registry types
	create_tools_cache 1
	create_resources_cache 1
	create_prompts_cache 1
	export MCPBASH_STATIC_REGISTRY=1

	# Tools should load from cache
	MCP_TOOLS_REGISTRY_JSON=""
	MCP_TOOLS_REGISTRY_PATH="${MCPBASH_REGISTRY_DIR}/tools.json"
	MCP_TOOLS_LAST_SCAN=""
	MCP_TOOLS_TOTAL=0
	mcp_tools_refresh_registry
	[[ "${MCP_TOOLS_REGISTRY_JSON}" =~ "cached-tool" ]]
	assert_equal "1" "${MCP_TOOLS_TOTAL}"

	# Resources should load from cache
	MCP_RESOURCES_REGISTRY_JSON=""
	MCP_RESOURCES_REGISTRY_PATH="${MCPBASH_REGISTRY_DIR}/resources.json"
	MCP_RESOURCES_LAST_SCAN=""
	MCP_RESOURCES_TOTAL=0
	mcp_resources_refresh_registry
	[[ "${MCP_RESOURCES_REGISTRY_JSON}" =~ "cached-resource" ]]
	assert_equal "1" "${MCP_RESOURCES_TOTAL}"

	# Prompts should load from cache
	MCP_PROMPTS_REGISTRY_JSON=""
	MCP_PROMPTS_REGISTRY_PATH="${MCPBASH_REGISTRY_DIR}/prompts.json"
	MCP_PROMPTS_LAST_SCAN=""
	MCP_PROMPTS_TOTAL=0
	mcp_prompts_refresh_registry
	[[ "${MCP_PROMPTS_REGISTRY_JSON}" =~ "cached-prompt" ]]
	assert_equal "1" "${MCP_PROMPTS_TOTAL}"
}

@test "static_registry: without STATIC=1, normal TTL/fastpath logic runs" {
	create_tools_cache 1
	create_tool_on_disk "disk-tool"
	# Static mode NOT enabled
	unset MCPBASH_STATIC_REGISTRY
	MCP_TOOLS_REGISTRY_JSON=""
	MCP_TOOLS_REGISTRY_PATH="${MCPBASH_REGISTRY_DIR}/tools.json"
	MCP_TOOLS_LAST_SCAN=""
	MCP_TOOLS_TOTAL=0
	MCP_TOOLS_TTL=0  # Force TTL expired

	mcp_tools_refresh_registry || true

	# Should have scanned (TTL=0 forces scan in normal mode)
	[[ "${MCP_TOOLS_REGISTRY_JSON}" =~ "disk-tool" ]]
}
