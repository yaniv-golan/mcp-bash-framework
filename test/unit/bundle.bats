#!/usr/bin/env bash
# Unit layer: bundle command creates valid MCPB archives.

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
test_require_command unzip

test_create_tmpdir
PROJECT_ROOT="${TEST_TMPDIR}/proj"
OUTPUT_DIR="${TEST_TMPDIR}/out"
EXTRACT_DIR="${TEST_TMPDIR}/extracted"
mkdir -p "${PROJECT_ROOT}" "${OUTPUT_DIR}" "${EXTRACT_DIR}"
export MCPBASH_PROJECT_ROOT="${PROJECT_ROOT}"

# Create minimal project structure
mkdir -p "${PROJECT_ROOT}/server.d"
cat > "${PROJECT_ROOT}/server.d/server.meta.json" <<'EOF'
{
  "name": "test-server",
  "title": "Test Server",
  "version": "1.2.3",
  "description": "A test MCP server"
}
EOF

mkdir -p "${PROJECT_ROOT}/tools/hello"
cat > "${PROJECT_ROOT}/tools/hello/tool.meta.json" <<'EOF'
{
  "name": "hello",
  "description": "Say hello"
}
EOF
cat > "${PROJECT_ROOT}/tools/hello/tool.sh" <<'EOF'
#!/usr/bin/env bash
echo "Hello"
EOF
chmod +x "${PROJECT_ROOT}/tools/hello/tool.sh"

printf ' -> bundle --help shows usage\n'
help_output="$("${REPO_ROOT}/bin/mcp-bash" bundle --help 2>&1 || true)"
if [[ ! "${help_output}" =~ "mcp-bash bundle" ]]; then
	test_fail "bundle --help does not show usage"
fi

printf ' -> bundle --validate passes on valid project\n'
(cd "${PROJECT_ROOT}" && "${REPO_ROOT}/bin/mcp-bash" bundle --validate >/dev/null)
# Should exit 0

printf ' -> bundle --validate fails without server.meta.json\n'
empty_proj="${TEST_TMPDIR}/empty"
mkdir -p "${empty_proj}"
# Force MCPBASH_PROJECT_ROOT to prevent climbing up to find a valid project
if (cd "${empty_proj}" && MCPBASH_PROJECT_ROOT="${empty_proj}" "${REPO_ROOT}/bin/mcp-bash" bundle --validate 2>/dev/null); then
	test_fail "bundle --validate should fail on empty project"
fi

printf ' -> bundle creates .mcpb archive\n'
(cd "${PROJECT_ROOT}" && "${REPO_ROOT}/bin/mcp-bash" bundle --output "${OUTPUT_DIR}" >/dev/null)
bundle_file="${OUTPUT_DIR}/test-server-1.2.3.mcpb"
assert_file_exists "${bundle_file}"

printf ' -> bundle is valid zip archive\n'
if ! unzip -t "${bundle_file}" >/dev/null 2>&1; then
	test_fail "bundle is not a valid zip archive"
fi

printf ' -> bundle contains manifest.json\n'
unzip -q "${bundle_file}" -d "${EXTRACT_DIR}"
assert_file_exists "${EXTRACT_DIR}/manifest.json"

printf ' -> manifest.json has correct structure\n'
manifest="${EXTRACT_DIR}/manifest.json"
if ! jq -e '.manifest_version == "0.3"' "${manifest}" >/dev/null; then
	test_fail "manifest missing manifest_version 0.3"
fi
if ! jq -e '.name == "test-server"' "${manifest}" >/dev/null; then
	test_fail "manifest has wrong name"
fi
if ! jq -e '.version == "1.2.3"' "${manifest}" >/dev/null; then
	test_fail "manifest has wrong version"
fi
if ! jq -e '.server.type == "binary"' "${manifest}" >/dev/null; then
	test_fail "manifest missing server.type"
fi
if ! jq -e '.server.entry_point' "${manifest}" >/dev/null; then
	test_fail "manifest missing server.entry_point"
fi

printf ' -> bundle contains embedded framework\n'
assert_file_exists "${EXTRACT_DIR}/server/.mcp-bash/bin/mcp-bash"
assert_file_exists "${EXTRACT_DIR}/server/.mcp-bash/lib/core.sh"

printf ' -> bundle contains project tools\n'
assert_file_exists "${EXTRACT_DIR}/server/tools/hello/tool.sh"
assert_file_exists "${EXTRACT_DIR}/server/tools/hello/tool.meta.json"

printf ' -> bundle contains run-server.sh wrapper\n'
assert_file_exists "${EXTRACT_DIR}/server/run-server.sh"
if [[ ! -x "${EXTRACT_DIR}/server/run-server.sh" ]]; then
	test_fail "run-server.sh is not executable"
fi

printf ' -> --platform darwin sets correct platforms in manifest\n'
rm -rf "${OUTPUT_DIR}"/* "${EXTRACT_DIR}"/*
(cd "${PROJECT_ROOT}" && "${REPO_ROOT}/bin/mcp-bash" bundle --output "${OUTPUT_DIR}" --platform darwin >/dev/null)
unzip -q "${OUTPUT_DIR}/test-server-1.2.3.mcpb" -d "${EXTRACT_DIR}"
if ! jq -e '.compatibility.platforms == ["darwin"]' "${EXTRACT_DIR}/manifest.json" >/dev/null; then
	test_fail "manifest does not have darwin-only platforms"
fi

printf ' -> icon.png is included when present\n'
rm -rf "${OUTPUT_DIR}"/* "${EXTRACT_DIR}"/*
# Create a minimal valid PNG (1x1 transparent pixel)
printf '\x89PNG\r\n\x1a\n' > "${PROJECT_ROOT}/icon.png"
(cd "${PROJECT_ROOT}" && "${REPO_ROOT}/bin/mcp-bash" bundle --output "${OUTPUT_DIR}" >/dev/null)
unzip -q "${OUTPUT_DIR}/test-server-1.2.3.mcpb" -d "${EXTRACT_DIR}"
assert_file_exists "${EXTRACT_DIR}/icon.png"
if ! jq -e '.icon == "icon.png"' "${EXTRACT_DIR}/manifest.json" >/dev/null; then
	test_fail "manifest does not reference icon.png"
fi

printf ' -> --name and --version override metadata\n'
rm -rf "${OUTPUT_DIR}"/* "${EXTRACT_DIR}"/*
(cd "${PROJECT_ROOT}" && "${REPO_ROOT}/bin/mcp-bash" bundle --output "${OUTPUT_DIR}" --name custom-name --version 9.9.9 >/dev/null)
bundle_file="${OUTPUT_DIR}/custom-name-9.9.9.mcpb"
assert_file_exists "${bundle_file}"
unzip -q "${bundle_file}" -d "${EXTRACT_DIR}"
if ! jq -e '.name == "custom-name"' "${EXTRACT_DIR}/manifest.json" >/dev/null; then
	test_fail "manifest name not overridden"
fi
if ! jq -e '.version == "9.9.9"' "${EXTRACT_DIR}/manifest.json" >/dev/null; then
	test_fail "manifest version not overridden"
fi

printf 'Bundle tests passed.\n'
