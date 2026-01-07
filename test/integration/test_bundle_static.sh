#!/usr/bin/env bash
# shellcheck disable=SC2034  # Used by test runner for reporting.
TEST_DESC="Bundle with MCPB_STATIC=true pre-generates registry and sets env."
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"
BIN="${ROOT_DIR}/bin/mcp-bash"

# Check dependencies
command -v jq >/dev/null 2>&1 || {
	echo "SKIP: jq required"
	exit 0
}
command -v zip >/dev/null 2>&1 || {
	echo "SKIP: zip required"
	exit 0
}
command -v unzip >/dev/null 2>&1 || {
	echo "SKIP: unzip required"
	exit 0
}

TMP="$(mktemp -d)"
cleanup() {
	rm -rf "${TMP}"
}
trap cleanup EXIT INT TERM

PROJECT="${TMP}/project"
OUTPUT="${TMP}/output"
EXTRACT="${TMP}/extracted"
mkdir -p "${PROJECT}" "${OUTPUT}" "${EXTRACT}"

# Create minimal project structure
mkdir -p "${PROJECT}/server.d" "${PROJECT}/tools/hello"
cat >"${PROJECT}/server.d/server.meta.json" <<'EOF'
{
  "name": "static-test",
  "title": "Static Test Server",
  "version": "1.0.0",
  "description": "Test server for static registry mode"
}
EOF

cat >"${PROJECT}/tools/hello/tool.sh" <<'SH'
#!/usr/bin/env bash
echo '{"message": "hello"}'
SH
chmod +x "${PROJECT}/tools/hello/tool.sh"
cat >"${PROJECT}/tools/hello/tool.meta.json" <<'JSON'
{"name": "hello", "description": "Say hello"}
JSON

# Enable static mode in mcpb.conf
cat >"${PROJECT}/mcpb.conf" <<'CONF'
MCPB_STATIC=true
CONF

echo "Creating bundle with MCPB_STATIC=true..."

# Build the bundle
(cd "${PROJECT}" && MCPBASH_HOME="${ROOT_DIR}" "${BIN}" bundle --output "${OUTPUT}" >/dev/null 2>&1)

bundle_file="${OUTPUT}/static-test-1.0.0.mcpb"

# Test 1: Bundle file exists
if [ ! -f "${bundle_file}" ]; then
	echo "FAIL: Bundle file not created: ${bundle_file}"
	exit 1
fi
echo "  [OK] Bundle file created"

# Extract bundle
unzip -q "${bundle_file}" -d "${EXTRACT}"

# Test 2: .registry directory is included
if [ ! -d "${EXTRACT}/server/.registry" ]; then
	echo "FAIL: .registry directory not included in bundle"
	exit 1
fi
echo "  [OK] .registry directory included"

# Test 3: tools.json cache exists with format_version
if [ ! -f "${EXTRACT}/server/.registry/tools.json" ]; then
	echo "FAIL: tools.json cache not found"
	exit 1
fi
if ! jq -e '.format_version == 1' "${EXTRACT}/server/.registry/tools.json" >/dev/null 2>&1; then
	echo "FAIL: format_version not 1 in tools.json"
	exit 1
fi
echo "  [OK] tools.json has format_version=1"

# Test 4: manifest.json has MCPBASH_STATIC_REGISTRY=1 in env
manifest="${EXTRACT}/manifest.json"
if [ ! -f "${manifest}" ]; then
	echo "FAIL: manifest.json not found"
	exit 1
fi
static_env="$(jq -r '.server.mcp_config.env.MCPBASH_STATIC_REGISTRY // empty' "${manifest}")"
if [ "${static_env}" != "1" ]; then
	echo "FAIL: MCPBASH_STATIC_REGISTRY not set to 1 in manifest (got: '${static_env}')"
	exit 1
fi
echo "  [OK] manifest.json has MCPBASH_STATIC_REGISTRY=1"

# Test 5: tools.json contains the hello tool
tool_count="$(jq -r '.total' "${EXTRACT}/server/.registry/tools.json")"
if [ "${tool_count}" != "1" ]; then
	echo "FAIL: Expected 1 tool in cache, got ${tool_count}"
	exit 1
fi
tool_name="$(jq -r '.items[0].name' "${EXTRACT}/server/.registry/tools.json")"
if [ "${tool_name}" != "hello" ]; then
	echo "FAIL: Expected tool name 'hello', got '${tool_name}'"
	exit 1
fi
echo "  [OK] tools.json contains hello tool"

# Test 6: Bundle with explicit MCPB_STATIC=false opts out of static registry
rm -rf "${OUTPUT:?}"/* "${EXTRACT:?}"/*
cat >"${PROJECT}/mcpb.conf" <<'CONF'
MCPB_STATIC=false
CONF
(cd "${PROJECT}" && MCPBASH_HOME="${ROOT_DIR}" "${BIN}" bundle --output "${OUTPUT}" >/dev/null 2>&1)
unzip -q "${OUTPUT}/static-test-1.0.0.mcpb" -d "${EXTRACT}"
non_static_env="$(jq -r '.server.mcp_config.env.MCPBASH_STATIC_REGISTRY // "unset"' "${EXTRACT}/manifest.json")"
if [ "${non_static_env}" != "unset" ]; then
	echo "FAIL: Opt-out bundle should not have MCPBASH_STATIC_REGISTRY in env (got: '${non_static_env}')"
	exit 1
fi
echo "  [OK] MCPB_STATIC=false opts out of static registry"

# Test 7: Bundle without mcpb.conf uses static registry by default
rm -rf "${OUTPUT:?}"/* "${EXTRACT:?}"/*
rm -f "${PROJECT}/mcpb.conf"
(cd "${PROJECT}" && MCPBASH_HOME="${ROOT_DIR}" "${BIN}" bundle --output "${OUTPUT}" >/dev/null 2>&1)
unzip -q "${OUTPUT}/static-test-1.0.0.mcpb" -d "${EXTRACT}"
default_static_env="$(jq -r '.server.mcp_config.env.MCPBASH_STATIC_REGISTRY // empty' "${EXTRACT}/manifest.json")"
if [ "${default_static_env}" != "1" ]; then
	echo "FAIL: Default bundle should have MCPBASH_STATIC_REGISTRY=1 (got: '${default_static_env}')"
	exit 1
fi
if [ ! -d "${EXTRACT}/server/.registry" ]; then
	echo "FAIL: Default bundle should include .registry directory"
	exit 1
fi
echo "  [OK] Default bundle has static registry (zero-config)"

echo ""
echo "Bundle static registry test passed"
