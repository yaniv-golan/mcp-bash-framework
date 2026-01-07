#!/usr/bin/env bash
# shellcheck disable=SC2034  # Used by test runner for reporting.
TEST_DESC="Static registry mode uses pre-generated cache and skips discovery."
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"
BIN="${ROOT_DIR}/bin/mcp-bash"

TMP="$(mktemp -d)"
cleanup() {
	rm -rf "${TMP}"
}
trap cleanup EXIT INT TERM

unset MCPBASH_STATE_DIR MCPBASH_LOCK_ROOT MCPBASH_TMP_ROOT MCPBASH_STATIC_REGISTRY
export TMPDIR="${TMP}"
export MCPBASH_PROJECT_ROOT="${TMP}"
mkdir -p "${TMP}/tools" "${TMP}/resources" "${TMP}/prompts"

# Seed a simple tool with explicit name in meta.json
mkdir -p "${TMP}/tools/hello"
cat <<'SH' >"${TMP}/tools/hello/tool.sh"
#!/usr/bin/env bash
echo '{"message":"hello"}'
SH
chmod +x "${TMP}/tools/hello/tool.sh"
cat <<'JSON' >"${TMP}/tools/hello/tool.meta.json"
{"name": "hello", "description": "Say hello"}
JSON

assert_json_value() {
	local json="$1"
	local jq_expr="$2"
	local expected="$3"
	local actual
	actual="$(printf '%s' "${json}" | jq -r "${jq_expr}")"
	if [ "${actual}" != "${expected}" ]; then
		echo "Assertion failed: ${jq_expr} expected ${expected} got ${actual}" >&2
		exit 1
	fi
}

echo "Test 1: Generate registries normally..."

# First, generate registries normally
output="$("${BIN}" registry refresh --project-root "${TMP}" --no-notify)"
assert_json_value "${output}" '.tools.status' 'ok'

# Verify cache file exists with format_version
if ! jq -e '.format_version == 1' "${TMP}/.registry/tools.json" >/dev/null 2>&1; then
	echo "FAIL: format_version not found or not 1 in tools cache" >&2
	exit 1
fi
echo "  [OK] Cache created with format_version=1"

echo "Test 2: Add new tool (should NOT be detected in static mode)..."

# Add a new tool (should NOT be detected in static mode)
mkdir -p "${TMP}/tools/bye"
cat <<'SH' >"${TMP}/tools/bye/tool.sh"
#!/usr/bin/env bash
echo '{"message":"bye"}'
SH
chmod +x "${TMP}/tools/bye/tool.sh"
cat <<'JSON' >"${TMP}/tools/bye/tool.meta.json"
{"name": "bye", "description": "Say bye"}
JSON

echo "Test 3: Verify tools/list in static mode shows only cached tool..."

# Enable static mode and run tools/list via MCP protocol
cat <<'JSON' >"${TMP}/requests.ndjson"
{"jsonrpc":"2.0","id":"init","method":"initialize","params":{}}
{"jsonrpc":"2.0","method":"notifications/initialized"}
{"jsonrpc":"2.0","id":"tools-list","method":"tools/list","params":{}}
JSON

(
	cd "${ROOT_DIR}"
	MCPBASH_STATIC_REGISTRY=1 \
		MCPBASH_PROJECT_ROOT="${TMP}" \
		MCPBASH_TOOL_ALLOWLIST="*" \
		"${BIN}" <"${TMP}/requests.ndjson" >"${TMP}/responses.ndjson" 2>/dev/null
) || true

# Extract tools/list response
tools_resp="$(grep '"id":"tools-list"' "${TMP}/responses.ndjson" | head -n1)"
if [ -z "${tools_resp}" ]; then
	echo "FAIL: tools/list response missing" >&2
	exit 1
fi

# Check tool count - should be 1 (not 2) because static mode skips discovery
tool_count="$(printf '%s' "${tools_resp}" | jq -r '.result.tools | length')"
if [ "${tool_count}" != "1" ]; then
	echo "FAIL: Expected 1 tool in static mode, got ${tool_count}" >&2
	printf '%s\n' "${tools_resp}" | jq '.result.tools[].name' >&2
	exit 1
fi

# Verify it's the cached tool (hello), not the new one (bye)
tool_name="$(printf '%s' "${tools_resp}" | jq -r '.result.tools[0].name')"
if [ "${tool_name}" != "hello" ]; then
	echo "FAIL: Expected tool 'hello', got '${tool_name}'" >&2
	exit 1
fi
echo "  [OK] Static mode shows only cached tool (1 tool: hello)"

echo "Test 4: Verify CLI registry refresh still works (overrides static mode)..."

# Verify CLI registry refresh still works (LAST_SCAN=0 should override static mode)
output2="$("${BIN}" registry refresh --project-root "${TMP}" --no-notify)"
assert_json_value "${output2}" '.tools.count' '2'
echo "  [OK] CLI refresh finds both tools (2 tools)"

echo "Test 5: Verify tools/list after refresh shows both tools..."

# Run tools/list again without static mode to confirm both tools are now in cache
(
	cd "${ROOT_DIR}"
	MCPBASH_PROJECT_ROOT="${TMP}" \
		MCPBASH_TOOL_ALLOWLIST="*" \
		"${BIN}" <"${TMP}/requests.ndjson" >"${TMP}/responses2.ndjson" 2>/dev/null
) || true

tools_resp2="$(grep '"id":"tools-list"' "${TMP}/responses2.ndjson" | head -n1)"
tool_count2="$(printf '%s' "${tools_resp2}" | jq -r '.result.tools | length')"
if [ "${tool_count2}" != "2" ]; then
	echo "FAIL: Expected 2 tools after refresh, got ${tool_count2}" >&2
	exit 1
fi
echo "  [OK] After refresh, both tools visible (2 tools)"

echo ""
echo "Static registry mode test passed"
