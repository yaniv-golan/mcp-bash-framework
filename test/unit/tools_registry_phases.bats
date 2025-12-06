#!/usr/bin/env bash
# Unit tests for tool registry helper phases.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

# shellcheck source=test/common/env.sh
# shellcheck disable=SC1091
. "${REPO_ROOT}/test/common/env.sh"
# shellcheck source=test/common/assert.sh
# shellcheck disable=SC1091
. "${REPO_ROOT}/test/common/assert.sh"
# shellcheck source=lib/hash.sh disable=SC1090
. "${REPO_ROOT}/lib/hash.sh"
# shellcheck source=lib/lock.sh disable=SC1090
. "${REPO_ROOT}/lib/lock.sh"
# shellcheck source=lib/registry.sh disable=SC1090
. "${REPO_ROOT}/lib/registry.sh"
# shellcheck source=lib/tools.sh disable=SC1090
. "${REPO_ROOT}/lib/tools.sh"

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

test_create_tmpdir
MCPBASH_TMP_ROOT="${TEST_TMPDIR}"
MCPBASH_STATE_DIR="${TEST_TMPDIR}/state"
MCPBASH_LOCK_ROOT="${TEST_TMPDIR}/locks"
mkdir -p "${MCPBASH_STATE_DIR}" "${MCPBASH_LOCK_ROOT}"

printf ' -> cache freshness gating respects TTL\n'
MCP_TOOLS_REGISTRY_JSON="{}"
now="$(date +%s)"
MCP_TOOLS_LAST_SCAN="${now}"
MCP_TOOLS_TTL=5
if ! mcp_tools_cache_fresh "${now}"; then
	test_fail "expected cache to be fresh when TTL not expired"
fi
MCP_TOOLS_LAST_SCAN=$((now - 10))
if mcp_tools_cache_fresh "${now}"; then
	test_fail "expected cache to be stale after TTL"
fi

printf ' -> cache load hydrates registry state from disk\n'
MCP_TOOLS_REGISTRY_JSON=""
MCP_TOOLS_REGISTRY_PATH="${TEST_TMPDIR}/tools.json"
printf '{"hash":"h1","total":2}' >"${MCP_TOOLS_REGISTRY_PATH}"
if ! mcp_tools_load_cache_if_empty; then
	test_fail "load_cache_if_empty failed"
fi
assert_eq "h1" "${MCP_TOOLS_REGISTRY_HASH}" "hash should be loaded from cache"
assert_eq "2" "${MCP_TOOLS_TOTAL}" "total should be loaded from cache"

printf ' -> fastpath hit reuses snapshot and syncs last scan\n'
MCPBASH_TOOLS_DIR="${TEST_TMPDIR}/toolsdir"
mkdir -p "${MCPBASH_TOOLS_DIR}"
touch "${MCPBASH_TOOLS_DIR}/a.sh"
snapshot="$(mcp_registry_fastpath_snapshot "${MCPBASH_TOOLS_DIR}")"
mcp_registry_fastpath_store "tools" "${snapshot}" || test_fail "fastpath store failed"
MCP_TOOLS_REGISTRY_HASH="h0"
MCP_TOOLS_REGISTRY_JSON="{}"
MCP_TOOLS_TOTAL=0
MCP_TOOLS_LAST_SCAN=0
MCP_TOOLS_REGISTRY_PATH="${TEST_TMPDIR}/tools-cache.json"
now_fast="$(date +%s)"
if ! mcp_tools_fastpath_hit "${MCPBASH_TOOLS_DIR}" "${now_fast}"; then
	test_fail "expected fastpath_hit to return success for unchanged tree"
fi
assert_eq "${now_fast}" "${MCP_TOOLS_LAST_SCAN}" "fastpath should update last scan timestamp"

printf ' -> full scan writes registry and updates hash\n'
MCPBASH_TOOLS_DIR="${TEST_TMPDIR}/toolsdir-full"
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
MCP_TOOLS_REGISTRY_PATH="${TEST_TMPDIR}/tools-registry.json"
MCP_TOOLS_REGISTRY_HASH=""
MCP_TOOLS_REGISTRY_JSON=""
MCP_TOOLS_TOTAL=0
mcp_lock_init
scan_time="$(date +%s)"
if ! mcp_tools_perform_full_scan "${MCPBASH_TOOLS_DIR}" "${scan_time}"; then
	test_fail "full scan failed"
fi
assert_file_exists "${MCP_TOOLS_REGISTRY_PATH}"
if [ -z "${MCP_TOOLS_REGISTRY_HASH}" ]; then
	test_fail "registry hash was not set after scan"
fi
total_recorded="$("${MCPBASH_JSON_TOOL_BIN}" -r '.total' "${MCP_TOOLS_REGISTRY_PATH}")"
assert_eq "1" "${total_recorded}" "registry should record one tool"

printf ' -> refresh falls back when manual registration reports status 1\n'
(
	mcp_registry_register_apply() {
		return 1
	}
	mcp_registry_register_error_for_kind() {
		printf ''
	}

	MCPBASH_TOOLS_DIR="${TEST_TMPDIR}/toolsdir-manual-status"
	mkdir -p "${MCPBASH_TOOLS_DIR}/bar"
	cat >"${MCPBASH_TOOLS_DIR}/bar/tool.sh" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
	chmod +x "${MCPBASH_TOOLS_DIR}/bar/tool.sh"
	MCP_TOOLS_REGISTRY_PATH="${TEST_TMPDIR}/tools-registry-manual.json"
	MCP_TOOLS_REGISTRY_HASH=""
	MCP_TOOLS_REGISTRY_JSON=""
	MCP_TOOLS_TOTAL=0
	MCP_TOOLS_LAST_SCAN=0
	MCP_TOOLS_TTL=0
	MCPBASH_REGISTRY_DIR="${TEST_TMPDIR}/registry"
	mcp_lock_init
	if ! mcp_tools_refresh_registry; then
		test_fail "refresh should fall back to scan when manual registration returns 1"
	fi
	assert_file_exists "${MCP_TOOLS_REGISTRY_PATH}"
	fallback_total="$("${MCPBASH_JSON_TOOL_BIN}" -r '.total' "${MCP_TOOLS_REGISTRY_PATH}")"
	assert_eq "1" "${fallback_total}" "fallback scan should register tool despite manual status 1"
)

printf ' -> manual registration status 2 surfaces as fatal\n'
(
	mcp_registry_register_apply() {
		return 2
	}
	mcp_registry_register_error_for_kind() {
		printf 'manual failure'
	}

	MCP_TOOLS_REGISTRY_PATH="${TEST_TMPDIR}/tools-registry-manual-fatal.json"
	MCP_TOOLS_REGISTRY_HASH=""
	MCP_TOOLS_REGISTRY_JSON=""
	MCP_TOOLS_TOTAL=0
	MCP_TOOLS_LAST_SCAN=0
	MCP_TOOLS_TTL=0
	MCPBASH_REGISTRY_DIR="${TEST_TMPDIR}/registry-fatal"
	mcp_lock_init
	if mcp_tools_refresh_registry; then
		test_fail "refresh should fail when manual registration returns 2"
	fi
)
