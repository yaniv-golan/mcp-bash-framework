#!/usr/bin/env bats
# Unit layer: bundle command creates valid MCPB archives.

load '../../node_modules/bats-support/load'
load '../../node_modules/bats-assert/load'
load '../../node_modules/bats-file/load'
load '../common/fixtures'

setup() {
	command -v jq >/dev/null 2>&1 || skip "jq required"
	command -v zip >/dev/null 2>&1 || skip "zip required"
	command -v unzip >/dev/null 2>&1 || skip "unzip required"

	PROJECT_ROOT="${BATS_TEST_TMPDIR}/proj"
	OUTPUT_DIR="${BATS_TEST_TMPDIR}/out"
	EXTRACT_DIR="${BATS_TEST_TMPDIR}/extracted"
	mkdir -p "${PROJECT_ROOT}" "${OUTPUT_DIR}" "${EXTRACT_DIR}"
	export MCPBASH_PROJECT_ROOT="${PROJECT_ROOT}"

	# Create minimal project structure
	mkdir -p "${PROJECT_ROOT}/server.d"
	cat >"${PROJECT_ROOT}/server.d/server.meta.json" <<'EOF'
{
  "name": "test-server",
  "title": "Test Server",
  "version": "1.2.3",
  "description": "A test MCP server"
}
EOF

	mkdir -p "${PROJECT_ROOT}/tools/hello"
	cat >"${PROJECT_ROOT}/tools/hello/tool.meta.json" <<'EOF'
{
  "name": "hello",
  "description": "Say hello"
}
EOF
	cat >"${PROJECT_ROOT}/tools/hello/tool.sh" <<'EOF'
#!/usr/bin/env bash
echo "Hello"
EOF
	chmod +x "${PROJECT_ROOT}/tools/hello/tool.sh"
}

@test "bundle: --help shows usage" {
	help_output="$("${MCPBASH_HOME}/bin/mcp-bash" bundle --help 2>&1 || true)"
	[[ "${help_output}" =~ "mcp-bash bundle" ]]
}

@test "bundle: --validate passes on valid project" {
	(cd "${PROJECT_ROOT}" && "${MCPBASH_HOME}/bin/mcp-bash" bundle --validate >/dev/null)
}

@test "bundle: --validate fails without server.meta.json" {
	empty_proj="${BATS_TEST_TMPDIR}/empty"
	mkdir -p "${empty_proj}"
	# Force MCPBASH_PROJECT_ROOT to prevent climbing up to find a valid project
	run bash -c "cd '${empty_proj}' && MCPBASH_PROJECT_ROOT='${empty_proj}' '${MCPBASH_HOME}/bin/mcp-bash' bundle --validate"
	assert_failure
}

@test "bundle: creates .mcpb archive" {
	(cd "${PROJECT_ROOT}" && "${MCPBASH_HOME}/bin/mcp-bash" bundle --output "${OUTPUT_DIR}" >/dev/null)
	bundle_file="${OUTPUT_DIR}/test-server-1.2.3.mcpb"
	assert_file_exist "${bundle_file}"
}

@test "bundle: is valid zip archive" {
	(cd "${PROJECT_ROOT}" && "${MCPBASH_HOME}/bin/mcp-bash" bundle --output "${OUTPUT_DIR}" >/dev/null)
	bundle_file="${OUTPUT_DIR}/test-server-1.2.3.mcpb"
	unzip -t "${bundle_file}" >/dev/null 2>&1
}

@test "bundle: contains manifest.json" {
	(cd "${PROJECT_ROOT}" && "${MCPBASH_HOME}/bin/mcp-bash" bundle --output "${OUTPUT_DIR}" >/dev/null)
	bundle_file="${OUTPUT_DIR}/test-server-1.2.3.mcpb"
	unzip -q "${bundle_file}" -d "${EXTRACT_DIR}"
	assert_file_exist "${EXTRACT_DIR}/manifest.json"
}

@test "bundle: manifest.json has correct structure" {
	(cd "${PROJECT_ROOT}" && "${MCPBASH_HOME}/bin/mcp-bash" bundle --output "${OUTPUT_DIR}" >/dev/null)
	bundle_file="${OUTPUT_DIR}/test-server-1.2.3.mcpb"
	unzip -q "${bundle_file}" -d "${EXTRACT_DIR}"
	manifest="${EXTRACT_DIR}/manifest.json"
	jq -e '.manifest_version == "0.3"' "${manifest}" >/dev/null
	jq -e '.name == "test-server"' "${manifest}" >/dev/null
	jq -e '.version == "1.2.3"' "${manifest}" >/dev/null
	jq -e '.server.type == "binary"' "${manifest}" >/dev/null
	jq -e '.server.entry_point' "${manifest}" >/dev/null
}

@test "bundle: contains embedded framework" {
	(cd "${PROJECT_ROOT}" && "${MCPBASH_HOME}/bin/mcp-bash" bundle --output "${OUTPUT_DIR}" >/dev/null)
	bundle_file="${OUTPUT_DIR}/test-server-1.2.3.mcpb"
	unzip -q "${bundle_file}" -d "${EXTRACT_DIR}"
	assert_file_exist "${EXTRACT_DIR}/server/.mcp-bash/bin/mcp-bash"
	assert_file_exist "${EXTRACT_DIR}/server/.mcp-bash/lib/core.sh"
}

@test "bundle: contains project tools" {
	(cd "${PROJECT_ROOT}" && "${MCPBASH_HOME}/bin/mcp-bash" bundle --output "${OUTPUT_DIR}" >/dev/null)
	bundle_file="${OUTPUT_DIR}/test-server-1.2.3.mcpb"
	unzip -q "${bundle_file}" -d "${EXTRACT_DIR}"
	assert_file_exist "${EXTRACT_DIR}/server/tools/hello/tool.sh"
	assert_file_exist "${EXTRACT_DIR}/server/tools/hello/tool.meta.json"
}

@test "bundle: contains run-server.sh wrapper" {
	(cd "${PROJECT_ROOT}" && "${MCPBASH_HOME}/bin/mcp-bash" bundle --output "${OUTPUT_DIR}" >/dev/null)
	bundle_file="${OUTPUT_DIR}/test-server-1.2.3.mcpb"
	unzip -q "${bundle_file}" -d "${EXTRACT_DIR}"
	assert_file_exist "${EXTRACT_DIR}/server/run-server.sh"
	[ -x "${EXTRACT_DIR}/server/run-server.sh" ]
}

@test "bundle: --platform darwin sets correct platforms in manifest" {
	rm -rf "${OUTPUT_DIR}"/* "${EXTRACT_DIR}"/*
	(cd "${PROJECT_ROOT}" && "${MCPBASH_HOME}/bin/mcp-bash" bundle --output "${OUTPUT_DIR}" --platform darwin >/dev/null)
	unzip -q "${OUTPUT_DIR}/test-server-1.2.3.mcpb" -d "${EXTRACT_DIR}"
	jq -e '.compatibility.platforms == ["darwin"]' "${EXTRACT_DIR}/manifest.json" >/dev/null
}

@test "bundle: icon.png is included when present" {
	rm -rf "${OUTPUT_DIR}"/* "${EXTRACT_DIR}"/*
	# Create a minimal valid PNG (1x1 transparent pixel)
	printf '\x89PNG\r\n\x1a\n' >"${PROJECT_ROOT}/icon.png"
	(cd "${PROJECT_ROOT}" && "${MCPBASH_HOME}/bin/mcp-bash" bundle --output "${OUTPUT_DIR}" >/dev/null)
	unzip -q "${OUTPUT_DIR}/test-server-1.2.3.mcpb" -d "${EXTRACT_DIR}"
	assert_file_exist "${EXTRACT_DIR}/icon.png"
	jq -e '.icon == "icon.png"' "${EXTRACT_DIR}/manifest.json" >/dev/null
}

@test "bundle: --name and --version override metadata" {
	rm -rf "${OUTPUT_DIR}"/* "${EXTRACT_DIR}"/*
	(cd "${PROJECT_ROOT}" && "${MCPBASH_HOME}/bin/mcp-bash" bundle --output "${OUTPUT_DIR}" --name custom-name --version 9.9.9 >/dev/null)
	bundle_file="${OUTPUT_DIR}/custom-name-9.9.9.mcpb"
	assert_file_exist "${bundle_file}"
	unzip -q "${bundle_file}" -d "${EXTRACT_DIR}"
	jq -e '.name == "custom-name"' "${EXTRACT_DIR}/manifest.json" >/dev/null
	jq -e '.version == "9.9.9"' "${EXTRACT_DIR}/manifest.json" >/dev/null
}

@test "bundle: lib/ and providers/ directories are bundled when present" {
	rm -rf "${OUTPUT_DIR}"/* "${EXTRACT_DIR}"/*
	mkdir -p "${PROJECT_ROOT}/lib"
	mkdir -p "${PROJECT_ROOT}/providers/custom"
	echo '# shared library code' >"${PROJECT_ROOT}/lib/utils.sh"
	echo '# custom provider' >"${PROJECT_ROOT}/providers/custom/provider.sh"
	(cd "${PROJECT_ROOT}" && "${MCPBASH_HOME}/bin/mcp-bash" bundle --output "${OUTPUT_DIR}" >/dev/null)
	unzip -q "${OUTPUT_DIR}/test-server-1.2.3.mcpb" -d "${EXTRACT_DIR}"
	assert_file_exist "${EXTRACT_DIR}/server/lib/utils.sh"
	assert_file_exist "${EXTRACT_DIR}/server/providers/custom/provider.sh"
}
