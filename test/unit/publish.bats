#!/usr/bin/env bash
# Unit layer: publish command validates bundles and handles errors.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

# shellcheck source=test/common/env.sh
# shellcheck disable=SC1091
. "${REPO_ROOT}/test/common/env.sh"
# shellcheck source=test/common/assert.sh
# shellcheck disable=SC1091
. "${REPO_ROOT}/test/common/assert.sh"

test_require_command jq
test_require_command zip

test_create_tmpdir
PROJECT_ROOT="${TEST_TMPDIR}/proj"
OUTPUT_DIR="${TEST_TMPDIR}/out"
mkdir -p "${PROJECT_ROOT}" "${OUTPUT_DIR}"
export MCPBASH_PROJECT_ROOT="${PROJECT_ROOT}"

# Create minimal project and bundle
mkdir -p "${PROJECT_ROOT}/server.d"
cat > "${PROJECT_ROOT}/server.d/server.meta.json" <<'EOF'
{
  "name": "test-server",
  "title": "Test Server",
  "version": "1.0.0",
  "description": "A test MCP server"
}
EOF

mkdir -p "${PROJECT_ROOT}/tools/hello"
cat > "${PROJECT_ROOT}/tools/hello/tool.meta.json" <<'EOF'
{"name": "hello", "description": "Say hello"}
EOF
cat > "${PROJECT_ROOT}/tools/hello/tool.sh" <<'EOF'
#!/usr/bin/env bash
echo "Hello"
EOF
chmod +x "${PROJECT_ROOT}/tools/hello/tool.sh"

# Create a valid bundle
(cd "${PROJECT_ROOT}" && "${REPO_ROOT}/bin/mcp-bash" bundle --output "${OUTPUT_DIR}" >/dev/null)
BUNDLE_FILE="${OUTPUT_DIR}/test-server-1.0.0.mcpb"

printf ' -> publish --help shows usage\n'
help_output="$("${REPO_ROOT}/bin/mcp-bash" publish --help 2>&1 || true)"
if [[ ! "${help_output}" =~ "mcp-bash publish" ]]; then
	test_fail "publish --help does not show usage"
fi

printf ' -> publish fails without token\n'
unset MCPBASH_REGISTRY_TOKEN 2>/dev/null || true
if "${REPO_ROOT}/bin/mcp-bash" publish "${BUNDLE_FILE}" 2>/dev/null; then
	test_fail "publish should fail without token"
fi

printf ' -> publish --dry-run validates bundle without submitting\n'
output="$("${REPO_ROOT}/bin/mcp-bash" publish --dry-run "${BUNDLE_FILE}" 2>&1)"
if [[ ! "${output}" =~ "dry-run" ]] && [[ ! "${output}" =~ "Dry run" ]]; then
	test_fail "publish --dry-run should indicate dry run mode"
fi

printf ' -> publish rejects non-existent file\n'
if "${REPO_ROOT}/bin/mcp-bash" publish --dry-run "${TEST_TMPDIR}/nonexistent.mcpb" 2>/dev/null; then
	test_fail "publish should reject non-existent file"
fi

printf ' -> publish rejects non-.mcpb file\n'
touch "${TEST_TMPDIR}/fake.zip"
if "${REPO_ROOT}/bin/mcp-bash" publish --dry-run "${TEST_TMPDIR}/fake.zip" 2>/dev/null; then
	test_fail "publish should reject non-.mcpb file"
fi

printf ' -> publish rejects invalid archive\n'
echo "not a zip" > "${TEST_TMPDIR}/invalid.mcpb"
if "${REPO_ROOT}/bin/mcp-bash" publish --dry-run "${TEST_TMPDIR}/invalid.mcpb" 2>/dev/null; then
	test_fail "publish should reject invalid archive"
fi

printf 'Publish tests passed.\n'
