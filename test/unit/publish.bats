#!/usr/bin/env bats
# Unit layer: publish command validates bundles and handles errors.

load '../../node_modules/bats-support/load'
load '../../node_modules/bats-assert/load'
load '../../node_modules/bats-file/load'
load '../common/fixtures'

setup() {
	command -v jq >/dev/null 2>&1 || skip "jq required"
	command -v zip >/dev/null 2>&1 || skip "zip required"

	PROJECT_ROOT="${BATS_TEST_TMPDIR}/proj"
	OUTPUT_DIR="${BATS_TEST_TMPDIR}/out"
	mkdir -p "${PROJECT_ROOT}" "${OUTPUT_DIR}"
	export MCPBASH_PROJECT_ROOT="${PROJECT_ROOT}"

	# Create minimal project and bundle
	mkdir -p "${PROJECT_ROOT}/server.d"
	cat >"${PROJECT_ROOT}/server.d/server.meta.json" <<'EOF'
{
  "name": "test-server",
  "title": "Test Server",
  "version": "1.0.0",
  "description": "A test MCP server"
}
EOF

	mkdir -p "${PROJECT_ROOT}/tools/hello"
	cat >"${PROJECT_ROOT}/tools/hello/tool.meta.json" <<'EOF'
{"name": "hello", "description": "Say hello"}
EOF
	cat >"${PROJECT_ROOT}/tools/hello/tool.sh" <<'EOF'
#!/usr/bin/env bash
echo "Hello"
EOF
	chmod +x "${PROJECT_ROOT}/tools/hello/tool.sh"

	# Create a valid bundle
	(cd "${PROJECT_ROOT}" && "${MCPBASH_HOME}/bin/mcp-bash" bundle --output "${OUTPUT_DIR}" >/dev/null)
	BUNDLE_FILE="${OUTPUT_DIR}/test-server-1.0.0.mcpb"
}

@test "publish: --help shows usage" {
	help_output="$("${MCPBASH_HOME}/bin/mcp-bash" publish --help 2>&1 || true)"
	[[ "${help_output}" =~ "mcp-bash publish" ]]
}

@test "publish: fails without token" {
	unset MCPBASH_REGISTRY_TOKEN 2>/dev/null || true
	run "${MCPBASH_HOME}/bin/mcp-bash" publish "${BUNDLE_FILE}"
	assert_failure
}

@test "publish: --dry-run validates bundle without submitting" {
	output="$("${MCPBASH_HOME}/bin/mcp-bash" publish --dry-run "${BUNDLE_FILE}" 2>&1)"
	[[ "${output}" =~ "dry-run" ]] || [[ "${output}" =~ "Dry run" ]]
}

@test "publish: rejects non-existent file" {
	run "${MCPBASH_HOME}/bin/mcp-bash" publish --dry-run "${BATS_TEST_TMPDIR}/nonexistent.mcpb"
	assert_failure
}

@test "publish: rejects non-.mcpb file" {
	touch "${BATS_TEST_TMPDIR}/fake.zip"
	run "${MCPBASH_HOME}/bin/mcp-bash" publish --dry-run "${BATS_TEST_TMPDIR}/fake.zip"
	assert_failure
}

@test "publish: rejects invalid archive" {
	echo "not a zip" >"${BATS_TEST_TMPDIR}/invalid.mcpb"
	run "${MCPBASH_HOME}/bin/mcp-bash" publish --dry-run "${BATS_TEST_TMPDIR}/invalid.mcpb"
	assert_failure
}
