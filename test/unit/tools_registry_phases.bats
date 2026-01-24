#!/usr/bin/env bats
# Unit tests for tool registry helper phases.

load '../../node_modules/bats-support/load'
load '../../node_modules/bats-assert/load'
load '../../node_modules/bats-file/load'
load '../common/fixtures'

setup() {
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

	MCPBASH_JSON_TOOL_BIN="$(command -v jq)"
	MCPBASH_JSON_TOOL="jq"
	if ! command -v mcp_logging_is_enabled >/dev/null 2>&1; then
		mcp_logging_is_enabled() {
			return 1
		}
	fi
	if ! command -v mcp_logging_warning >/dev/null 2>&1; then
		mcp_logging_warning() {
			return 0
		}
	fi
	if ! command -v mcp_logging_debug >/dev/null 2>&1; then
		mcp_logging_debug() {
			return 0
		}
	fi

	MCPBASH_TMP_ROOT="${BATS_TEST_TMPDIR}"
	MCPBASH_STATE_DIR="${BATS_TEST_TMPDIR}/state"
	MCPBASH_LOCK_ROOT="${BATS_TEST_TMPDIR}/locks"
	mkdir -p "${MCPBASH_STATE_DIR}" "${MCPBASH_LOCK_ROOT}"
}

@test "tools_registry_phases: cache freshness gating respects TTL" {
	MCP_TOOLS_REGISTRY_JSON="{}"
	now="$(date +%s)"
	MCP_TOOLS_LAST_SCAN="${now}"
	MCP_TOOLS_TTL=5
	mcp_tools_cache_fresh "${now}"

	MCP_TOOLS_LAST_SCAN=$((now - 10))
	run mcp_tools_cache_fresh "${now}"
	assert_failure
}

@test "tools_registry_phases: cache load hydrates registry state from disk" {
	MCP_TOOLS_REGISTRY_JSON=""
	MCP_TOOLS_REGISTRY_PATH="${BATS_TEST_TMPDIR}/tools.json"
	printf '{"hash":"h1","total":2}' >"${MCP_TOOLS_REGISTRY_PATH}"
	mcp_tools_load_cache_if_empty
	assert_equal "h1" "${MCP_TOOLS_REGISTRY_HASH}"
	assert_equal "2" "${MCP_TOOLS_TOTAL}"
}

@test "tools_registry_phases: fastpath hit reuses snapshot and syncs last scan" {
	MCPBASH_TOOLS_DIR="${BATS_TEST_TMPDIR}/toolsdir"
	mkdir -p "${MCPBASH_TOOLS_DIR}"
	touch "${MCPBASH_TOOLS_DIR}/a.sh"
	snapshot="$(mcp_registry_fastpath_snapshot "${MCPBASH_TOOLS_DIR}")"
	mcp_registry_fastpath_store "tools" "${snapshot}"
	MCP_TOOLS_REGISTRY_HASH="h0"
	MCP_TOOLS_REGISTRY_JSON="{}"
	MCP_TOOLS_TOTAL=0
	MCP_TOOLS_LAST_SCAN=0
	MCP_TOOLS_REGISTRY_PATH="${BATS_TEST_TMPDIR}/tools-cache.json"
	now_fast="$(date +%s)"
	mcp_tools_fastpath_hit "${MCPBASH_TOOLS_DIR}" "${now_fast}"
	assert_equal "${now_fast}" "${MCP_TOOLS_LAST_SCAN}"
}

@test "tools_registry_phases: full scan writes registry and updates hash" {
	MCPBASH_TOOLS_DIR="${BATS_TEST_TMPDIR}/toolsdir-full"
	mkdir -p "${MCPBASH_TOOLS_DIR}/foo"
	cat >"${MCPBASH_TOOLS_DIR}/foo/tool.meta.json" <<'EOF'
{
  "name": "foo",
  "inputSchema": {"type": "object", "properties": {}}
}
EOF
	cat >"${MCPBASH_TOOLS_DIR}/foo/tool.sh" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
	chmod +x "${MCPBASH_TOOLS_DIR}/foo/tool.sh"
	MCP_TOOLS_REGISTRY_PATH="${BATS_TEST_TMPDIR}/tools-registry.json"
	MCP_TOOLS_REGISTRY_HASH=""
	MCP_TOOLS_REGISTRY_JSON=""
	MCP_TOOLS_TOTAL=0
	mcp_lock_init
	scan_time="$(date +%s)"
	mcp_tools_perform_full_scan "${MCPBASH_TOOLS_DIR}" "${scan_time}"
	assert_file_exist "${MCP_TOOLS_REGISTRY_PATH}"
	[ -n "${MCP_TOOLS_REGISTRY_HASH}" ]
	total_recorded="$("${MCPBASH_JSON_TOOL_BIN}" -r '.total' "${MCP_TOOLS_REGISTRY_PATH}")"
	assert_equal "1" "${total_recorded}"
}

@test "tools_registry_phases: refresh falls back when manual registration returns status 1" {
	# Override functions to simulate manual registration returning status 1
	mcp_registry_register_apply() {
		return 1
	}
	mcp_registry_register_error_for_kind() {
		printf ''
	}

	MCPBASH_TOOLS_DIR="${BATS_TEST_TMPDIR}/toolsdir-manual-status"
	mkdir -p "${MCPBASH_TOOLS_DIR}/bar"
	cat >"${MCPBASH_TOOLS_DIR}/bar/tool.sh" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
	chmod +x "${MCPBASH_TOOLS_DIR}/bar/tool.sh"
	MCP_TOOLS_REGISTRY_PATH="${BATS_TEST_TMPDIR}/tools-registry-manual.json"
	MCP_TOOLS_REGISTRY_HASH=""
	MCP_TOOLS_REGISTRY_JSON=""
	MCP_TOOLS_TOTAL=0
	MCP_TOOLS_LAST_SCAN=0
	MCP_TOOLS_TTL=0
	MCPBASH_REGISTRY_DIR="${BATS_TEST_TMPDIR}/registry"
	mcp_lock_init
	# mcp_tools_refresh_registry should fallback to scan when manual registration returns 1
	mcp_tools_refresh_registry || true
	[ -f "${MCP_TOOLS_REGISTRY_PATH}" ]
	fallback_total="$("${MCPBASH_JSON_TOOL_BIN}" -r '.total' "${MCP_TOOLS_REGISTRY_PATH}")"
	[ "${fallback_total}" = "1" ]
}

@test "tools_registry_phases: manual registration status 2 surfaces as fatal" {
	# Override functions to simulate manual registration returning status 2
	mcp_registry_register_apply() {
		return 2
	}
	mcp_registry_register_error_for_kind() {
		printf 'manual failure'
	}

	MCP_TOOLS_REGISTRY_PATH="${BATS_TEST_TMPDIR}/tools-registry-manual-fatal.json"
	MCP_TOOLS_REGISTRY_HASH=""
	MCP_TOOLS_REGISTRY_JSON=""
	MCP_TOOLS_TOTAL=0
	MCP_TOOLS_LAST_SCAN=0
	MCP_TOOLS_TTL=0
	MCPBASH_REGISTRY_DIR="${BATS_TEST_TMPDIR}/registry-fatal"
	mcp_lock_init
	run mcp_tools_refresh_registry
	assert_failure
}

@test "tools_registry_phases: full scan extracts tool annotations from meta.json" {
	MCPBASH_TOOLS_DIR="${BATS_TEST_TMPDIR}/toolsdir-annotations"
	mkdir -p "${MCPBASH_TOOLS_DIR}/annotated"
	cat >"${MCPBASH_TOOLS_DIR}/annotated/tool.meta.json" <<'EOF'
{
  "name": "annotated",
  "description": "Tool with annotations",
  "inputSchema": {"type": "object", "properties": {}},
  "annotations": {
    "readOnlyHint": true,
    "destructiveHint": false,
    "idempotentHint": true,
    "openWorldHint": false
  }
}
EOF
	cat >"${MCPBASH_TOOLS_DIR}/annotated/tool.sh" <<'EOF'
#!/usr/bin/env bash
echo '{"status":"ok"}'
EOF
	chmod +x "${MCPBASH_TOOLS_DIR}/annotated/tool.sh"
	MCP_TOOLS_REGISTRY_PATH="${BATS_TEST_TMPDIR}/tools-registry-annotations.json"
	MCP_TOOLS_REGISTRY_HASH=""
	MCP_TOOLS_REGISTRY_JSON=""
	MCP_TOOLS_TOTAL=0
	mcp_lock_init
	scan_time="$(date +%s)"
	mcp_tools_perform_full_scan "${MCPBASH_TOOLS_DIR}" "${scan_time}"
	assert_file_exist "${MCP_TOOLS_REGISTRY_PATH}"
	# Check annotations were captured
	annotations_json="$("${MCPBASH_JSON_TOOL_BIN}" -c '.items[0].annotations' "${MCP_TOOLS_REGISTRY_PATH}")"
	[ -n "${annotations_json}" ] && [ "${annotations_json}" != "null" ]
	read_only="$("${MCPBASH_JSON_TOOL_BIN}" -r '.items[0].annotations.readOnlyHint' "${MCP_TOOLS_REGISTRY_PATH}")"
	assert_equal "true" "${read_only}"
	destructive="$("${MCPBASH_JSON_TOOL_BIN}" -r '.items[0].annotations.destructiveHint' "${MCP_TOOLS_REGISTRY_PATH}")"
	assert_equal "false" "${destructive}"
}

@test "tools_registry_phases: tool without annotations omits annotations field" {
	MCPBASH_TOOLS_DIR="${BATS_TEST_TMPDIR}/toolsdir-no-annotations"
	mkdir -p "${MCPBASH_TOOLS_DIR}/plain"
	cat >"${MCPBASH_TOOLS_DIR}/plain/tool.meta.json" <<'EOF'
{
  "name": "plain",
  "inputSchema": {"type": "object", "properties": {}}
}
EOF
	cat >"${MCPBASH_TOOLS_DIR}/plain/tool.sh" <<'EOF'
#!/usr/bin/env bash
echo '{"status":"ok"}'
EOF
	chmod +x "${MCPBASH_TOOLS_DIR}/plain/tool.sh"
	MCP_TOOLS_REGISTRY_PATH="${BATS_TEST_TMPDIR}/tools-registry-no-annotations.json"
	MCP_TOOLS_REGISTRY_HASH=""
	MCP_TOOLS_REGISTRY_JSON=""
	MCP_TOOLS_TOTAL=0
	mcp_lock_init
	scan_time="$(date +%s)"
	mcp_tools_perform_full_scan "${MCPBASH_TOOLS_DIR}" "${scan_time}"
	# Check annotations field is absent (not null)
	has_annotations="$("${MCPBASH_JSON_TOOL_BIN}" -r '.items[0] | has("annotations")' "${MCP_TOOLS_REGISTRY_PATH}")"
	assert_equal "false" "${has_annotations}"
}

@test "tools_registry_phases: full scan extracts timeout fields from meta.json" {
	MCPBASH_TOOLS_DIR="${BATS_TEST_TMPDIR}/toolsdir-timeout-fields"
	mkdir -p "${MCPBASH_TOOLS_DIR}/slow-tool"
	cat >"${MCPBASH_TOOLS_DIR}/slow-tool/tool.meta.json" <<'EOF'
{
  "name": "slow-tool",
  "description": "Tool with timeout configuration",
  "inputSchema": {"type": "object", "properties": {}},
  "timeoutSecs": 30,
  "timeoutHint": "Use smaller inputs or enable dryRun mode.",
  "progressExtendsTimeout": true,
  "maxTimeoutSecs": 300
}
EOF
	cat >"${MCPBASH_TOOLS_DIR}/slow-tool/tool.sh" <<'EOF'
#!/usr/bin/env bash
echo '{"status":"ok"}'
EOF
	chmod +x "${MCPBASH_TOOLS_DIR}/slow-tool/tool.sh"
	MCP_TOOLS_REGISTRY_PATH="${BATS_TEST_TMPDIR}/tools-registry-timeout.json"
	MCP_TOOLS_REGISTRY_HASH=""
	MCP_TOOLS_REGISTRY_JSON=""
	MCP_TOOLS_TOTAL=0
	mcp_lock_init
	scan_time="$(date +%s)"
	mcp_tools_perform_full_scan "${MCPBASH_TOOLS_DIR}" "${scan_time}"
	assert_file_exist "${MCP_TOOLS_REGISTRY_PATH}"
	# Check timeoutSecs is captured as number
	timeout_secs="$("${MCPBASH_JSON_TOOL_BIN}" -r '.items[0].timeoutSecs' "${MCP_TOOLS_REGISTRY_PATH}")"
	assert_equal "30" "${timeout_secs}"
	# Check progressExtendsTimeout is captured as boolean true
	progress_extends="$("${MCPBASH_JSON_TOOL_BIN}" -r '.items[0].progressExtendsTimeout' "${MCP_TOOLS_REGISTRY_PATH}")"
	assert_equal "true" "${progress_extends}"
	# Check maxTimeoutSecs is captured as number
	max_timeout="$("${MCPBASH_JSON_TOOL_BIN}" -r '.items[0].maxTimeoutSecs' "${MCP_TOOLS_REGISTRY_PATH}")"
	assert_equal "300" "${max_timeout}"
	# Check timeoutHint is captured as string
	timeout_hint="$("${MCPBASH_JSON_TOOL_BIN}" -r '.items[0].timeoutHint' "${MCP_TOOLS_REGISTRY_PATH}")"
	assert_equal "Use smaller inputs or enable dryRun mode." "${timeout_hint}"
}

@test "tools_registry_phases: tool without timeout fields omits them from registry" {
	MCPBASH_TOOLS_DIR="${BATS_TEST_TMPDIR}/toolsdir-no-timeout"
	mkdir -p "${MCPBASH_TOOLS_DIR}/quick-tool"
	cat >"${MCPBASH_TOOLS_DIR}/quick-tool/tool.meta.json" <<'EOF'
{
  "name": "quick-tool",
  "inputSchema": {"type": "object", "properties": {}}
}
EOF
	cat >"${MCPBASH_TOOLS_DIR}/quick-tool/tool.sh" <<'EOF'
#!/usr/bin/env bash
echo '{"status":"ok"}'
EOF
	chmod +x "${MCPBASH_TOOLS_DIR}/quick-tool/tool.sh"
	MCP_TOOLS_REGISTRY_PATH="${BATS_TEST_TMPDIR}/tools-registry-no-timeout.json"
	MCP_TOOLS_REGISTRY_HASH=""
	MCP_TOOLS_REGISTRY_JSON=""
	MCP_TOOLS_TOTAL=0
	mcp_lock_init
	scan_time="$(date +%s)"
	mcp_tools_perform_full_scan "${MCPBASH_TOOLS_DIR}" "${scan_time}"
	# Check timeout fields are absent (not null)
	has_progress_extends="$("${MCPBASH_JSON_TOOL_BIN}" -r '.items[0] | has("progressExtendsTimeout")' "${MCP_TOOLS_REGISTRY_PATH}")"
	assert_equal "false" "${has_progress_extends}"
	has_max_timeout="$("${MCPBASH_JSON_TOOL_BIN}" -r '.items[0] | has("maxTimeoutSecs")' "${MCP_TOOLS_REGISTRY_PATH}")"
	assert_equal "false" "${has_max_timeout}"
	has_timeout_hint="$("${MCPBASH_JSON_TOOL_BIN}" -r '.items[0] | has("timeoutHint")' "${MCP_TOOLS_REGISTRY_PATH}")"
	assert_equal "false" "${has_timeout_hint}"
}
