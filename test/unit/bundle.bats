#!/usr/bin/env bats
# Unit layer: bundle command creates valid MCPB archives.

load '../../node_modules/bats-support/load'
load '../../node_modules/bats-assert/load'
load '../../node_modules/bats-file/load'
load '../common/fixtures'

setup() {
	[ -n "${TEST_JSON_TOOL_BIN:-}" ] || skip "jq/gojq required"
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

@test "bundle: long_description_file from server.meta.json is included" {
	rm -rf "${OUTPUT_DIR}"/* "${EXTRACT_DIR}"/*
	mkdir -p "${PROJECT_ROOT}/docs"
	cat >"${PROJECT_ROOT}/docs/DESCRIPTION.md" <<'EOF'
# Test Server

This is a **detailed** description with markdown.

- Feature 1
- Feature 2
EOF
	# Add long_description_file to server.meta.json
	local meta_file="${PROJECT_ROOT}/server.d/server.meta.json"
	local original_meta
	original_meta="$(cat "${meta_file}")"
	jq '. + {long_description_file: "docs/DESCRIPTION.md"}' "${meta_file}" >"${meta_file}.tmp"
	mv "${meta_file}.tmp" "${meta_file}"

	(cd "${PROJECT_ROOT}" && "${MCPBASH_HOME}/bin/mcp-bash" bundle --output "${OUTPUT_DIR}" >/dev/null)

	# Restore original meta
	echo "${original_meta}" >"${meta_file}"

	unzip -q "${OUTPUT_DIR}/test-server-1.2.3.mcpb" -d "${EXTRACT_DIR}"
	# Verify long_description is in manifest and contains expected content
	jq -e '.long_description' "${EXTRACT_DIR}/manifest.json" >/dev/null
	jq -e '.long_description | contains("detailed")' "${EXTRACT_DIR}/manifest.json" >/dev/null
	jq -e '.long_description | contains("Feature 1")' "${EXTRACT_DIR}/manifest.json" >/dev/null
}

@test "bundle: tools_generated is true when tools exist" {
	rm -rf "${OUTPUT_DIR}"/* "${EXTRACT_DIR}"/*
	(cd "${PROJECT_ROOT}" && "${MCPBASH_HOME}/bin/mcp-bash" bundle --output "${OUTPUT_DIR}" >/dev/null)
	unzip -q "${OUTPUT_DIR}/test-server-1.2.3.mcpb" -d "${EXTRACT_DIR}"
	# Project has tools, so tools_generated should be true
	jq -e '.tools_generated == true' "${EXTRACT_DIR}/manifest.json" >/dev/null
}

@test "bundle: prompts_generated is true when prompts exist" {
	rm -rf "${OUTPUT_DIR}"/* "${EXTRACT_DIR}"/*
	mkdir -p "${PROJECT_ROOT}/prompts"
	echo "Hello {{name}}" >"${PROJECT_ROOT}/prompts/greeting.txt"
	cat >"${PROJECT_ROOT}/prompts/greeting.meta.json" <<'EOF'
{"name": "greeting", "description": "A greeting prompt"}
EOF
	(cd "${PROJECT_ROOT}" && "${MCPBASH_HOME}/bin/mcp-bash" bundle --output "${OUTPUT_DIR}" >/dev/null)
	unzip -q "${OUTPUT_DIR}/test-server-1.2.3.mcpb" -d "${EXTRACT_DIR}"
	jq -e '.prompts_generated == true' "${EXTRACT_DIR}/manifest.json" >/dev/null
}

# MCPB_INCLUDE tests

@test "bundle: MCPB_INCLUDE copies custom directory" {
	rm -rf "${OUTPUT_DIR}"/* "${EXTRACT_DIR}"/*
	mkdir -p "${PROJECT_ROOT}/.registry"
	echo '{"commands": []}' >"${PROJECT_ROOT}/.registry/commands.json"
	echo 'MCPB_INCLUDE=".registry"' >"${PROJECT_ROOT}/mcpb.conf"
	(cd "${PROJECT_ROOT}" && "${MCPBASH_HOME}/bin/mcp-bash" bundle --output "${OUTPUT_DIR}" >/dev/null)
	unzip -q "${OUTPUT_DIR}/test-server-1.2.3.mcpb" -d "${EXTRACT_DIR}"
	assert_file_exist "${EXTRACT_DIR}/server/.registry/commands.json"
}

@test "bundle: MCPB_INCLUDE copies multiple directories" {
	rm -rf "${OUTPUT_DIR}"/* "${EXTRACT_DIR}"/*
	mkdir -p "${PROJECT_ROOT}/.registry" "${PROJECT_ROOT}/config" "${PROJECT_ROOT}/data"
	echo '{}' >"${PROJECT_ROOT}/.registry/index.json"
	echo 'key=value' >"${PROJECT_ROOT}/config/settings.conf"
	echo 'test data' >"${PROJECT_ROOT}/data/test.txt"
	echo 'MCPB_INCLUDE=".registry config data"' >"${PROJECT_ROOT}/mcpb.conf"
	(cd "${PROJECT_ROOT}" && "${MCPBASH_HOME}/bin/mcp-bash" bundle --output "${OUTPUT_DIR}" >/dev/null)
	unzip -q "${OUTPUT_DIR}/test-server-1.2.3.mcpb" -d "${EXTRACT_DIR}"
	assert_file_exist "${EXTRACT_DIR}/server/.registry/index.json"
	assert_file_exist "${EXTRACT_DIR}/server/config/settings.conf"
	assert_file_exist "${EXTRACT_DIR}/server/data/test.txt"
}

@test "bundle: MCPB_INCLUDE warns on missing directory" {
	rm -rf "${OUTPUT_DIR}"/* "${EXTRACT_DIR}"/*
	echo 'MCPB_INCLUDE="nonexistent"' >"${PROJECT_ROOT}/mcpb.conf"
	run bash -c "cd '${PROJECT_ROOT}' && '${MCPBASH_HOME}/bin/mcp-bash' bundle --output '${OUTPUT_DIR}' 2>&1"
	assert_success
	[[ "${output}" =~ "MCPB_INCLUDE directory not found: nonexistent" ]]
}

@test "bundle: MCPB_INCLUDE rejects path traversal" {
	rm -rf "${OUTPUT_DIR}"/* "${EXTRACT_DIR}"/*
	echo 'MCPB_INCLUDE="../etc"' >"${PROJECT_ROOT}/mcpb.conf"
	run bash -c "cd '${PROJECT_ROOT}' && '${MCPBASH_HOME}/bin/mcp-bash' bundle --output '${OUTPUT_DIR}' 2>&1"
	assert_success
	[[ "${output}" =~ "rejects path traversal" ]]
}

@test "bundle: MCPB_INCLUDE rejects absolute path" {
	rm -rf "${OUTPUT_DIR}"/* "${EXTRACT_DIR}"/*
	echo 'MCPB_INCLUDE="/etc/passwd"' >"${PROJECT_ROOT}/mcpb.conf"
	run bash -c "cd '${PROJECT_ROOT}' && '${MCPBASH_HOME}/bin/mcp-bash' bundle --output '${OUTPUT_DIR}' 2>&1"
	assert_success
	[[ "${output}" =~ "rejects absolute/relative path" ]]
}

@test "bundle: MCPB_INCLUDE rejects ./ prefix" {
	rm -rf "${OUTPUT_DIR}"/* "${EXTRACT_DIR}"/*
	mkdir -p "${PROJECT_ROOT}/config"
	echo 'test' >"${PROJECT_ROOT}/config/test.txt"
	echo 'MCPB_INCLUDE="./config"' >"${PROJECT_ROOT}/mcpb.conf"
	run bash -c "cd '${PROJECT_ROOT}' && '${MCPBASH_HOME}/bin/mcp-bash' bundle --output '${OUTPUT_DIR}' 2>&1"
	assert_success
	[[ "${output}" =~ "rejects absolute/relative path" ]]
}

@test "bundle: empty MCPB_INCLUDE has no effect" {
	rm -rf "${OUTPUT_DIR}"/* "${EXTRACT_DIR}"/*
	echo 'MCPB_INCLUDE=""' >"${PROJECT_ROOT}/mcpb.conf"
	(cd "${PROJECT_ROOT}" && "${MCPBASH_HOME}/bin/mcp-bash" bundle --output "${OUTPUT_DIR}" >/dev/null)
	assert_file_exist "${OUTPUT_DIR}/test-server-1.2.3.mcpb"
}

@test "bundle: MCPB_INCLUDE handles nested paths" {
	rm -rf "${OUTPUT_DIR}"/* "${EXTRACT_DIR}"/*
	mkdir -p "${PROJECT_ROOT}/config/schemas"
	echo '{"type": "object"}' >"${PROJECT_ROOT}/config/schemas/user.json"
	echo 'MCPB_INCLUDE="config/schemas"' >"${PROJECT_ROOT}/mcpb.conf"
	(cd "${PROJECT_ROOT}" && "${MCPBASH_HOME}/bin/mcp-bash" bundle --output "${OUTPUT_DIR}" >/dev/null)
	unzip -q "${OUTPUT_DIR}/test-server-1.2.3.mcpb" -d "${EXTRACT_DIR}"
	assert_file_exist "${EXTRACT_DIR}/server/config/schemas/user.json"
}

@test "bundle: MCPB_INCLUDE skips default directory overlap" {
	rm -rf "${OUTPUT_DIR}"/* "${EXTRACT_DIR}"/*
	# tools/ already exists from setup and is a default directory
	echo 'MCPB_INCLUDE="tools"' >"${PROJECT_ROOT}/mcpb.conf"
	run bash -c "cd '${PROJECT_ROOT}' && '${MCPBASH_HOME}/bin/mcp-bash' bundle --output '${OUTPUT_DIR}' --verbose 2>&1"
	assert_success
	[[ "${output}" =~ "overlaps with default" ]] || [[ "${output}" =~ "Skipped tools/" ]]
}

@test "bundle: MCPB_INCLUDE skips subdirectory of default" {
	rm -rf "${OUTPUT_DIR}"/* "${EXTRACT_DIR}"/*
	echo 'MCPB_INCLUDE="tools/hello"' >"${PROJECT_ROOT}/mcpb.conf"
	run bash -c "cd '${PROJECT_ROOT}' && '${MCPBASH_HOME}/bin/mcp-bash' bundle --output '${OUTPUT_DIR}' --verbose 2>&1"
	assert_success
	[[ "${output}" =~ "overlaps with default" ]] || [[ "${output}" =~ "Skipped tools/hello" ]]
}

@test "bundle: MCPB_INCLUDE normalizes trailing slash" {
	rm -rf "${OUTPUT_DIR}"/* "${EXTRACT_DIR}"/*
	mkdir -p "${PROJECT_ROOT}/data"
	echo 'test' >"${PROJECT_ROOT}/data/file.txt"
	echo 'MCPB_INCLUDE="data/"' >"${PROJECT_ROOT}/mcpb.conf"
	(cd "${PROJECT_ROOT}" && "${MCPBASH_HOME}/bin/mcp-bash" bundle --output "${OUTPUT_DIR}" >/dev/null)
	unzip -q "${OUTPUT_DIR}/test-server-1.2.3.mcpb" -d "${EXTRACT_DIR}"
	# Should create data/ directory (not copy contents into server/)
	assert_file_exist "${EXTRACT_DIR}/server/data/file.txt"
}

@test "bundle: MCPB_INCLUDE allows literal dots in name" {
	rm -rf "${OUTPUT_DIR}"/* "${EXTRACT_DIR}"/*
	mkdir -p "${PROJECT_ROOT}/v1..beta"
	echo 'test' >"${PROJECT_ROOT}/v1..beta/notes.txt"
	echo 'MCPB_INCLUDE="v1..beta"' >"${PROJECT_ROOT}/mcpb.conf"
	(cd "${PROJECT_ROOT}" && "${MCPBASH_HOME}/bin/mcp-bash" bundle --output "${OUTPUT_DIR}" >/dev/null)
	unzip -q "${OUTPUT_DIR}/test-server-1.2.3.mcpb" -d "${EXTRACT_DIR}"
	assert_file_exist "${EXTRACT_DIR}/server/v1..beta/notes.txt"
}

@test "bundle: whitespace-only MCPB_INCLUDE has no effect" {
	rm -rf "${OUTPUT_DIR}"/* "${EXTRACT_DIR}"/*
	echo 'MCPB_INCLUDE="   "' >"${PROJECT_ROOT}/mcpb.conf"
	(cd "${PROJECT_ROOT}" && "${MCPBASH_HOME}/bin/mcp-bash" bundle --output "${OUTPUT_DIR}" >/dev/null)
	assert_file_exist "${OUTPUT_DIR}/test-server-1.2.3.mcpb"
}

@test "bundle: MCPB_INCLUDE handles symlink directories" {
	rm -rf "${OUTPUT_DIR}"/* "${EXTRACT_DIR}"/*
	mkdir -p "${PROJECT_ROOT}/real-data"
	echo 'original content' >"${PROJECT_ROOT}/real-data/file.txt"
	ln -s real-data "${PROJECT_ROOT}/linked-data"
	# Include both real dir and symlink - symlinks become regular files after zip/unzip
	echo 'MCPB_INCLUDE="real-data linked-data"' >"${PROJECT_ROOT}/mcpb.conf"
	(cd "${PROJECT_ROOT}" && "${MCPBASH_HOME}/bin/mcp-bash" bundle --output "${OUTPUT_DIR}" >/dev/null)
	unzip -q "${OUTPUT_DIR}/test-server-1.2.3.mcpb" -d "${EXTRACT_DIR}"
	# Both directories should exist with content (symlink resolved through zip)
	assert_file_exist "${EXTRACT_DIR}/server/real-data/file.txt"
	[[ -e "${EXTRACT_DIR}/server/linked-data" ]]
}

@test "bundle: MCPB_INCLUDE treats glob characters literally" {
	rm -rf "${OUTPUT_DIR}"/* "${EXTRACT_DIR}"/*
	# Create directory with literal asterisk in name
	mkdir -p "${PROJECT_ROOT}/data*test"
	echo 'test' >"${PROJECT_ROOT}/data*test/file.txt"
	echo 'MCPB_INCLUDE="data*test"' >"${PROJECT_ROOT}/mcpb.conf"
	(cd "${PROJECT_ROOT}" && "${MCPBASH_HOME}/bin/mcp-bash" bundle --output "${OUTPUT_DIR}" >/dev/null)
	unzip -q "${OUTPUT_DIR}/test-server-1.2.3.mcpb" -d "${EXTRACT_DIR}"
	# Should find literal "data*test" directory, not glob expand
	assert_file_exist "${EXTRACT_DIR}/server/data*test/file.txt"
}

# user_config tests

@test "bundle: generates manifest with user_config from file" {
	rm -rf "${OUTPUT_DIR}"/* "${EXTRACT_DIR}"/*
	cat > "${PROJECT_ROOT}/user-config.json" << 'EOF'
{
  "api_key": {
    "type": "string",
    "title": "API Key",
    "description": "Your API key for authentication",
    "sensitive": true,
    "required": true
  }
}
EOF
	cat > "${PROJECT_ROOT}/mcpb.conf" << 'EOF'
MCPB_NAME="test-server"
MCPB_VERSION="1.0.0"
MCPB_USER_CONFIG_FILE="user-config.json"
EOF
	run bash -c "cd '${PROJECT_ROOT}' && '${MCPBASH_HOME}/bin/mcp-bash' bundle --output '${OUTPUT_DIR}'"
	[ "$status" -eq 0 ]
	unzip -q "${OUTPUT_DIR}/test-server-1.0.0.mcpb" -d "${EXTRACT_DIR}"
	run jq -e '.user_config.api_key.sensitive == true' "${EXTRACT_DIR}/manifest.json"
	[ "$status" -eq 0 ]
}

@test "bundle: generates manifest with user_config from server.meta.json" {
	rm -rf "${OUTPUT_DIR}"/* "${EXTRACT_DIR}"/*
	cat > "${PROJECT_ROOT}/server.d/server.meta.json" << 'EOF'
{
  "name": "test",
  "version": "1.0.0",
  "description": "test",
  "user_config": {
    "debug": {
      "type": "boolean",
      "title": "Enable Debug Mode",
      "default": false
    }
  }
}
EOF
	run bash -c "cd '${PROJECT_ROOT}' && '${MCPBASH_HOME}/bin/mcp-bash' bundle --output '${OUTPUT_DIR}'"
	[ "$status" -eq 0 ]
	unzip -q "${OUTPUT_DIR}/test-1.0.0.mcpb" -d "${EXTRACT_DIR}"
	run jq -e '.user_config.debug.type == "boolean"' "${EXTRACT_DIR}/manifest.json"
	[ "$status" -eq 0 ]
}

@test "bundle: validates user_config field types" {
	rm -rf "${OUTPUT_DIR}"/* "${EXTRACT_DIR}"/*
	cat > "${PROJECT_ROOT}/user-config.json" << 'EOF'
{
  "bad_field": {
    "type": "invalid_type",
    "title": "Bad Field"
  }
}
EOF
	cat > "${PROJECT_ROOT}/mcpb.conf" << 'EOF'
MCPB_NAME="test-server"
MCPB_VERSION="1.0.0"
MCPB_USER_CONFIG_FILE="user-config.json"
EOF
	run bash -c "cd '${PROJECT_ROOT}' && '${MCPBASH_HOME}/bin/mcp-bash' bundle --validate"
	[ "$status" -ne 0 ]
	[[ "$output" == *"invalid type"* ]]
}

@test "bundle: validates user_config required fields (type and title)" {
	rm -rf "${OUTPUT_DIR}"/* "${EXTRACT_DIR}"/*
	cat > "${PROJECT_ROOT}/user-config.json" << 'EOF'
{
  "missing_type": {
    "title": "Missing Type"
  }
}
EOF
	cat > "${PROJECT_ROOT}/mcpb.conf" << 'EOF'
MCPB_NAME="test-server"
MCPB_VERSION="1.0.0"
MCPB_USER_CONFIG_FILE="user-config.json"
EOF
	run bash -c "cd '${PROJECT_ROOT}' && '${MCPBASH_HOME}/bin/mcp-bash' bundle --validate"
	[ "$status" -ne 0 ]
	[[ "$output" == *"must have \"type\" and \"title\""* ]]
}

@test "bundle: validates env_map references existing keys" {
	rm -rf "${OUTPUT_DIR}"/* "${EXTRACT_DIR}"/*
	cat > "${PROJECT_ROOT}/user-config.json" << 'EOF'
{
  "api_key": {
    "type": "string",
    "title": "API Key"
  }
}
EOF
	cat > "${PROJECT_ROOT}/mcpb.conf" << 'EOF'
MCPB_NAME="test-server"
MCPB_VERSION="1.0.0"
MCPB_USER_CONFIG_FILE="user-config.json"
MCPB_USER_CONFIG_ENV_MAP="nonexistent_key=MY_VAR"
EOF
	run bash -c "cd '${PROJECT_ROOT}' && '${MCPBASH_HOME}/bin/mcp-bash' bundle --validate"
	[ "$status" -ne 0 ]
	[[ "$output" == *"nonexistent_key"*"not defined"* ]]
}

@test "bundle: applies env_map in manifest" {
	rm -rf "${OUTPUT_DIR}"/* "${EXTRACT_DIR}"/*
	cat > "${PROJECT_ROOT}/user-config.json" << 'EOF'
{
  "api_key": {
    "type": "string",
    "title": "API Key",
    "sensitive": true
  }
}
EOF
	cat > "${PROJECT_ROOT}/mcpb.conf" << 'EOF'
MCPB_NAME="test-server"
MCPB_VERSION="1.0.0"
MCPB_USER_CONFIG_FILE="user-config.json"
MCPB_USER_CONFIG_ENV_MAP="api_key=MY_API_KEY"
EOF
	run bash -c "cd '${PROJECT_ROOT}' && '${MCPBASH_HOME}/bin/mcp-bash' bundle --output '${OUTPUT_DIR}'"
	[ "$status" -eq 0 ]
	unzip -q "${OUTPUT_DIR}/test-server-1.0.0.mcpb" -d "${EXTRACT_DIR}"
	run jq -e '.server.mcp_config.env.MY_API_KEY == "${user_config.api_key}"' "${EXTRACT_DIR}/manifest.json"
	[ "$status" -eq 0 ]
}

@test "bundle: MCPB_USER_CONFIG_FILE missing file is error" {
	rm -rf "${OUTPUT_DIR}"/* "${EXTRACT_DIR}"/*
	cat > "${PROJECT_ROOT}/mcpb.conf" << 'EOF'
MCPB_NAME="test-server"
MCPB_VERSION="1.0.0"
MCPB_USER_CONFIG_FILE="nonexistent.json"
EOF
	run bash -c "cd '${PROJECT_ROOT}' && '${MCPBASH_HOME}/bin/mcp-bash' bundle --validate"
	[ "$status" -ne 0 ]
	[[ "$output" == *"not found"* ]]
}

@test "bundle: empty user_config object is valid" {
	rm -rf "${OUTPUT_DIR}"/* "${EXTRACT_DIR}"/*
	cat > "${PROJECT_ROOT}/user-config.json" << 'EOF'
{}
EOF
	cat > "${PROJECT_ROOT}/mcpb.conf" << 'EOF'
MCPB_NAME="test-server"
MCPB_VERSION="1.0.0"
MCPB_USER_CONFIG_FILE="user-config.json"
EOF
	run bash -c "cd '${PROJECT_ROOT}' && '${MCPBASH_HOME}/bin/mcp-bash' bundle --validate"
	[ "$status" -eq 0 ]
}

@test "bundle: validates sensitive only for string type" {
	rm -rf "${OUTPUT_DIR}"/* "${EXTRACT_DIR}"/*
	cat > "${PROJECT_ROOT}/user-config.json" << 'EOF'
{
  "bad_sensitive": {
    "type": "number",
    "title": "Bad Sensitive",
    "sensitive": true
  }
}
EOF
	cat > "${PROJECT_ROOT}/mcpb.conf" << 'EOF'
MCPB_NAME="test-server"
MCPB_VERSION="1.0.0"
MCPB_USER_CONFIG_FILE="user-config.json"
EOF
	run bash -c "cd '${PROJECT_ROOT}' && '${MCPBASH_HOME}/bin/mcp-bash' bundle --validate"
	[ "$status" -ne 0 ]
	[[ "$output" == *"sensitive"*"only valid for string"* ]]
}

@test "bundle: validates min/max only for number type" {
	rm -rf "${OUTPUT_DIR}"/* "${EXTRACT_DIR}"/*
	cat > "${PROJECT_ROOT}/user-config.json" << 'EOF'
{
  "bad_minmax": {
    "type": "string",
    "title": "Bad MinMax",
    "min": 0
  }
}
EOF
	cat > "${PROJECT_ROOT}/mcpb.conf" << 'EOF'
MCPB_NAME="test-server"
MCPB_VERSION="1.0.0"
MCPB_USER_CONFIG_FILE="user-config.json"
EOF
	run bash -c "cd '${PROJECT_ROOT}' && '${MCPBASH_HOME}/bin/mcp-bash' bundle --validate"
	[ "$status" -ne 0 ]
	[[ "$output" == *"min"*"only valid for number"* ]]
}

@test "bundle: validates min <= max" {
	rm -rf "${OUTPUT_DIR}"/* "${EXTRACT_DIR}"/*
	cat > "${PROJECT_ROOT}/user-config.json" << 'EOF'
{
  "bad_range": {
    "type": "number",
    "title": "Bad Range",
    "min": 100,
    "max": 50
  }
}
EOF
	cat > "${PROJECT_ROOT}/mcpb.conf" << 'EOF'
MCPB_NAME="test-server"
MCPB_VERSION="1.0.0"
MCPB_USER_CONFIG_FILE="user-config.json"
EOF
	run bash -c "cd '${PROJECT_ROOT}' && '${MCPBASH_HOME}/bin/mcp-bash' bundle --validate"
	[ "$status" -ne 0 ]
	[[ "$output" == *"min"*"<="*"max"* ]]
}

@test "bundle: validates default type matches field type" {
	rm -rf "${OUTPUT_DIR}"/* "${EXTRACT_DIR}"/*
	cat > "${PROJECT_ROOT}/user-config.json" << 'EOF'
{
  "bad_default": {
    "type": "number",
    "title": "Bad Default",
    "default": "not a number"
  }
}
EOF
	cat > "${PROJECT_ROOT}/mcpb.conf" << 'EOF'
MCPB_NAME="test-server"
MCPB_VERSION="1.0.0"
MCPB_USER_CONFIG_FILE="user-config.json"
EOF
	run bash -c "cd '${PROJECT_ROOT}' && '${MCPBASH_HOME}/bin/mcp-bash' bundle --validate"
	[ "$status" -ne 0 ]
	[[ "$output" == *"default must be number"* ]]
}

@test "bundle: validates default in min/max range" {
	rm -rf "${OUTPUT_DIR}"/* "${EXTRACT_DIR}"/*
	cat > "${PROJECT_ROOT}/user-config.json" << 'EOF'
{
  "out_of_range": {
    "type": "number",
    "title": "Out of Range",
    "min": 10,
    "max": 100,
    "default": 5
  }
}
EOF
	cat > "${PROJECT_ROOT}/mcpb.conf" << 'EOF'
MCPB_NAME="test-server"
MCPB_VERSION="1.0.0"
MCPB_USER_CONFIG_FILE="user-config.json"
EOF
	run bash -c "cd '${PROJECT_ROOT}' && '${MCPBASH_HOME}/bin/mcp-bash' bundle --validate"
	[ "$status" -ne 0 ]
	[[ "$output" == *"default"*">="*"min"* ]]
}

@test "bundle: validates multiple only for directory/file types" {
	rm -rf "${OUTPUT_DIR}"/* "${EXTRACT_DIR}"/*
	cat > "${PROJECT_ROOT}/user-config.json" << 'EOF'
{
  "bad_multiple": {
    "type": "string",
    "title": "Bad Multiple",
    "multiple": true
  }
}
EOF
	cat > "${PROJECT_ROOT}/mcpb.conf" << 'EOF'
MCPB_NAME="test-server"
MCPB_VERSION="1.0.0"
MCPB_USER_CONFIG_FILE="user-config.json"
EOF
	run bash -c "cd '${PROJECT_ROOT}' && '${MCPBASH_HOME}/bin/mcp-bash' bundle --validate"
	[ "$status" -ne 0 ]
	[[ "$output" == *"multiple"*"only valid for directory/file"* ]]
}

@test "bundle: validates env var name is POSIX identifier" {
	rm -rf "${OUTPUT_DIR}"/* "${EXTRACT_DIR}"/*
	cat > "${PROJECT_ROOT}/user-config.json" << 'EOF'
{
  "api_key": {
    "type": "string",
    "title": "API Key"
  }
}
EOF
	cat > "${PROJECT_ROOT}/mcpb.conf" << 'EOF'
MCPB_NAME="test-server"
MCPB_VERSION="1.0.0"
MCPB_USER_CONFIG_FILE="user-config.json"
MCPB_USER_CONFIG_ENV_MAP="api_key=123-invalid"
EOF
	run bash -c "cd '${PROJECT_ROOT}' && '${MCPBASH_HOME}/bin/mcp-bash' bundle --validate"
	[ "$status" -ne 0 ]
	[[ "$output" == *"not a valid POSIX identifier"* ]]
}

@test "bundle: detects duplicate env var names" {
	rm -rf "${OUTPUT_DIR}"/* "${EXTRACT_DIR}"/*
	cat > "${PROJECT_ROOT}/user-config.json" << 'EOF'
{
  "api_key": {
    "type": "string",
    "title": "API Key"
  },
  "secret_key": {
    "type": "string",
    "title": "Secret Key"
  }
}
EOF
	cat > "${PROJECT_ROOT}/mcpb.conf" << 'EOF'
MCPB_NAME="test-server"
MCPB_VERSION="1.0.0"
MCPB_USER_CONFIG_FILE="user-config.json"
MCPB_USER_CONFIG_ENV_MAP="api_key=SAME_VAR,secret_key=SAME_VAR"
EOF
	run bash -c "cd '${PROJECT_ROOT}' && '${MCPBASH_HOME}/bin/mcp-bash' bundle --validate"
	[ "$status" -ne 0 ]
	[[ "$output" == *"duplicate env var name"* ]]
}

@test "bundle: args_map generates correct manifest" {
	rm -rf "${OUTPUT_DIR}"/* "${EXTRACT_DIR}"/*
	cat > "${PROJECT_ROOT}/user-config.json" << 'EOF'
{
  "allowed_dirs": {
    "type": "directory",
    "title": "Allowed Directories",
    "multiple": true
  }
}
EOF
	cat > "${PROJECT_ROOT}/mcpb.conf" << 'EOF'
MCPB_NAME="test-server"
MCPB_VERSION="1.0.0"
MCPB_USER_CONFIG_FILE="user-config.json"
MCPB_USER_CONFIG_ARGS_MAP="allowed_dirs"
EOF
	run bash -c "cd '${PROJECT_ROOT}' && '${MCPBASH_HOME}/bin/mcp-bash' bundle --output '${OUTPUT_DIR}'"
	[ "$status" -eq 0 ]
	unzip -q "${OUTPUT_DIR}/test-server-1.0.0.mcpb" -d "${EXTRACT_DIR}"
	run jq -e '.server.mcp_config.args | index("${user_config.allowed_dirs}") != null' "${EXTRACT_DIR}/manifest.json"
	[ "$status" -eq 0 ]
}

@test "bundle: validates args_map references existing user_config keys" {
	rm -rf "${OUTPUT_DIR}"/* "${EXTRACT_DIR}"/*
	cat > "${PROJECT_ROOT}/user-config.json" << 'EOF'
{
  "api_key": {
    "type": "string",
    "title": "API Key"
  }
}
EOF
	cat > "${PROJECT_ROOT}/mcpb.conf" << 'EOF'
MCPB_NAME="test-server"
MCPB_VERSION="1.0.0"
MCPB_USER_CONFIG_FILE="user-config.json"
MCPB_USER_CONFIG_ARGS_MAP="nonexistent_key"
EOF
	run bash -c "cd '${PROJECT_ROOT}' && '${MCPBASH_HOME}/bin/mcp-bash' bundle --validate"
	[ "$status" -ne 0 ]
	[[ "$output" == *"nonexistent_key"*"not defined"* ]]
}

@test "bundle: args_map from server.meta.json (JSON array form)" {
	rm -rf "${OUTPUT_DIR}"/* "${EXTRACT_DIR}"/*
	cat > "${PROJECT_ROOT}/server.d/server.meta.json" << 'EOF'
{
  "name": "test",
  "version": "1.0.0",
  "description": "test",
  "user_config": {
    "input_files": {
      "type": "file",
      "title": "Input Files",
      "multiple": true
    }
  },
  "user_config_args_map": ["input_files"]
}
EOF
	run bash -c "cd '${PROJECT_ROOT}' && '${MCPBASH_HOME}/bin/mcp-bash' bundle --output '${OUTPUT_DIR}'"
	[ "$status" -eq 0 ]
	unzip -q "${OUTPUT_DIR}/test-1.0.0.mcpb" -d "${EXTRACT_DIR}"
	run jq -e '.server.mcp_config.args | index("${user_config.input_files}") != null' "${EXTRACT_DIR}/manifest.json"
	[ "$status" -eq 0 ]
}

@test "bundle: mixed sources - user_config from file, env_map from server.meta.json" {
	rm -rf "${OUTPUT_DIR}"/* "${EXTRACT_DIR}"/*
	cat > "${PROJECT_ROOT}/server.d/server.meta.json" << 'EOF'
{
  "name": "test",
  "description": "test",
  "user_config_env_map": {
    "api_key": "MY_API_KEY"
  }
}
EOF
	cat > "${PROJECT_ROOT}/user-config.json" << 'EOF'
{
  "api_key": {
    "type": "string",
    "title": "API Key",
    "sensitive": true
  }
}
EOF
	cat > "${PROJECT_ROOT}/mcpb.conf" << 'EOF'
MCPB_NAME="test-server"
MCPB_VERSION="1.0.0"
MCPB_USER_CONFIG_FILE="user-config.json"
EOF
	run bash -c "cd '${PROJECT_ROOT}' && '${MCPBASH_HOME}/bin/mcp-bash' bundle --output '${OUTPUT_DIR}'"
	[ "$status" -eq 0 ]
	unzip -q "${OUTPUT_DIR}/test-server-1.0.0.mcpb" -d "${EXTRACT_DIR}"
	run jq -e '.user_config.api_key.sensitive == true' "${EXTRACT_DIR}/manifest.json"
	[ "$status" -eq 0 ]
	run jq -e '.server.mcp_config.env.MY_API_KEY == "${user_config.api_key}"' "${EXTRACT_DIR}/manifest.json"
	[ "$status" -eq 0 ]
}

@test "bundle: file type with multiple:true generates correct manifest" {
	rm -rf "${OUTPUT_DIR}"/* "${EXTRACT_DIR}"/*
	cat > "${PROJECT_ROOT}/user-config.json" << 'EOF'
{
  "input_files": {
    "type": "file",
    "title": "Input Files",
    "description": "Files to process",
    "multiple": true
  }
}
EOF
	cat > "${PROJECT_ROOT}/mcpb.conf" << 'EOF'
MCPB_NAME="test-server"
MCPB_VERSION="1.0.0"
MCPB_USER_CONFIG_FILE="user-config.json"
MCPB_USER_CONFIG_ARGS_MAP="input_files"
EOF
	run bash -c "cd '${PROJECT_ROOT}' && '${MCPBASH_HOME}/bin/mcp-bash' bundle --output '${OUTPUT_DIR}'"
	[ "$status" -eq 0 ]
	unzip -q "${OUTPUT_DIR}/test-server-1.0.0.mcpb" -d "${EXTRACT_DIR}"
	run jq -e '.user_config.input_files.type == "file" and .user_config.input_files.multiple == true' "${EXTRACT_DIR}/manifest.json"
	[ "$status" -eq 0 ]
}

@test "bundle: warns on MCPBASH namespace collision" {
	rm -rf "${OUTPUT_DIR}"/* "${EXTRACT_DIR}"/*
	cat > "${PROJECT_ROOT}/user-config.json" << 'EOF'
{
  "debug": {
    "type": "boolean",
    "title": "Debug Mode"
  }
}
EOF
	cat > "${PROJECT_ROOT}/mcpb.conf" << 'EOF'
MCPB_NAME="test-server"
MCPB_VERSION="1.0.0"
MCPB_USER_CONFIG_FILE="user-config.json"
MCPB_USER_CONFIG_ENV_MAP="debug=MCPBASH_DEBUG"
EOF
	run bash -c "cd '${PROJECT_ROOT}' && '${MCPBASH_HOME}/bin/mcp-bash' bundle --validate 2>&1"
	[ "$status" -eq 0 ]
	[[ "$output" == *"collides with reserved MCPBASH namespace"* ]]
}

@test "bundle: server.meta.json without args_map (TSV edge case)" {
	rm -rf "${OUTPUT_DIR}"/* "${EXTRACT_DIR}"/*
	cat > "${PROJECT_ROOT}/server.d/server.meta.json" << 'EOF'
{
  "name": "test",
  "version": "1.0.0",
  "description": "test",
  "user_config": {
    "api_key": {
      "type": "string",
      "title": "API Key"
    }
  },
  "user_config_env_map": {
    "api_key": "MY_API_KEY"
  }
}
EOF
	run bash -c "cd '${PROJECT_ROOT}' && '${MCPBASH_HOME}/bin/mcp-bash' bundle --output '${OUTPUT_DIR}'"
	[ "$status" -eq 0 ]
	unzip -q "${OUTPUT_DIR}/test-1.0.0.mcpb" -d "${EXTRACT_DIR}"
	run jq -e '.user_config.api_key.type == "string"' "${EXTRACT_DIR}/manifest.json"
	[ "$status" -eq 0 ]
	run jq -e '.server.mcp_config.env.MY_API_KEY == "${user_config.api_key}"' "${EXTRACT_DIR}/manifest.json"
	[ "$status" -eq 0 ]
}

@test "bundle: accepts min/max without default" {
	rm -rf "${OUTPUT_DIR}"/* "${EXTRACT_DIR}"/*
	cat > "${PROJECT_ROOT}/user-config.json" << 'EOF'
{
  "count": {
    "type": "number",
    "title": "Count",
    "min": 1,
    "max": 100
  }
}
EOF
	cat > "${PROJECT_ROOT}/mcpb.conf" << 'EOF'
MCPB_NAME="test-server"
MCPB_VERSION="1.0.0"
MCPB_USER_CONFIG_FILE="user-config.json"
EOF
	run bash -c "cd '${PROJECT_ROOT}' && '${MCPBASH_HOME}/bin/mcp-bash' bundle --validate"
	[ "$status" -eq 0 ]
}

@test "bundle: validates boolean default must be boolean" {
	rm -rf "${OUTPUT_DIR}"/* "${EXTRACT_DIR}"/*
	cat > "${PROJECT_ROOT}/user-config.json" << 'EOF'
{
  "debug": {
    "type": "boolean",
    "title": "Debug Mode",
    "default": "true"
  }
}
EOF
	cat > "${PROJECT_ROOT}/mcpb.conf" << 'EOF'
MCPB_NAME="test-server"
MCPB_VERSION="1.0.0"
MCPB_USER_CONFIG_FILE="user-config.json"
EOF
	run bash -c "cd '${PROJECT_ROOT}' && '${MCPBASH_HOME}/bin/mcp-bash' bundle --validate"
	[ "$status" -ne 0 ]
	[[ "$output" == *"default must be boolean"* ]]
}

@test "bundle: preserves variable substitution in defaults" {
	rm -rf "${OUTPUT_DIR}"/* "${EXTRACT_DIR}"/*
	cat > "${PROJECT_ROOT}/user-config.json" << 'EOF'
{
  "workspace": {
    "type": "directory",
    "title": "Workspace",
    "default": "${HOME}/workspace"
  }
}
EOF
	cat > "${PROJECT_ROOT}/mcpb.conf" << 'EOF'
MCPB_NAME="test-server"
MCPB_VERSION="1.0.0"
MCPB_USER_CONFIG_FILE="user-config.json"
EOF
	run bash -c "cd '${PROJECT_ROOT}' && '${MCPBASH_HOME}/bin/mcp-bash' bundle --output '${OUTPUT_DIR}'"
	[ "$status" -eq 0 ]
	unzip -q "${OUTPUT_DIR}/test-server-1.0.0.mcpb" -d "${EXTRACT_DIR}"
	# Verify variable substitution is preserved (not expanded)
	run jq -e '.user_config.workspace.default == "${HOME}/workspace"' "${EXTRACT_DIR}/manifest.json"
	[ "$status" -eq 0 ]
}

@test "bundle: validates config key cannot contain comma" {
	rm -rf "${OUTPUT_DIR}"/* "${EXTRACT_DIR}"/*
	cat > "${PROJECT_ROOT}/user-config.json" << 'EOF'
{
  "bad,key": {
    "type": "string",
    "title": "Bad Key"
  }
}
EOF
	cat > "${PROJECT_ROOT}/mcpb.conf" << 'EOF'
MCPB_NAME="test-server"
MCPB_VERSION="1.0.0"
MCPB_USER_CONFIG_FILE="user-config.json"
EOF
	run bash -c "cd '${PROJECT_ROOT}' && '${MCPBASH_HOME}/bin/mcp-bash' bundle --validate"
	[ "$status" -ne 0 ]
	[[ "$output" == *"cannot contain"*","* ]]
}

@test "bundle: validates config key cannot contain equals sign" {
	rm -rf "${OUTPUT_DIR}"/* "${EXTRACT_DIR}"/*
	cat > "${PROJECT_ROOT}/user-config.json" << 'EOF'
{
  "bad=key": {
    "type": "string",
    "title": "Bad Key"
  }
}
EOF
	cat > "${PROJECT_ROOT}/mcpb.conf" << 'EOF'
MCPB_NAME="test-server"
MCPB_VERSION="1.0.0"
MCPB_USER_CONFIG_FILE="user-config.json"
EOF
	run bash -c "cd '${PROJECT_ROOT}' && '${MCPBASH_HOME}/bin/mcp-bash' bundle --validate"
	[ "$status" -ne 0 ]
	[[ "$output" == *"cannot contain"*"="* ]]
}

@test "bundle: env_map with comma is parsed as multiple entries" {
	# Commas are used as entry delimiters in env_map, so "api_key=BAD,VAR"
	# becomes two entries: "api_key=BAD" and "VAR". The "VAR" entry fails
	# validation because it's not a valid config key reference.
	rm -rf "${OUTPUT_DIR}"/* "${EXTRACT_DIR}"/*
	cat > "${PROJECT_ROOT}/user-config.json" << 'EOF'
{
  "api_key": {
    "type": "string",
    "title": "API Key"
  }
}
EOF
	cat > "${PROJECT_ROOT}/mcpb.conf" << 'EOF'
MCPB_NAME="test-server"
MCPB_VERSION="1.0.0"
MCPB_USER_CONFIG_FILE="user-config.json"
MCPB_USER_CONFIG_ENV_MAP="api_key=BAD,VAR"
EOF
	run bash -c "cd '${PROJECT_ROOT}' && '${MCPBASH_HOME}/bin/mcp-bash' bundle --validate"
	[ "$status" -ne 0 ]
	# "VAR" is parsed as a config key reference, which doesn't exist
	[[ "$output" == *"VAR"*"not defined"* ]]
}

@test "bundle: MCPB_USER_CONFIG_FILE takes priority over server.meta.json user_config" {
	rm -rf "${OUTPUT_DIR}"/* "${EXTRACT_DIR}"/*
	# Put user_config in server.meta.json (should be ignored)
	cat > "${PROJECT_ROOT}/server.d/server.meta.json" << 'EOF'
{
  "name": "test",
  "version": "1.0.0",
  "description": "test",
  "user_config": {
    "meta_key": {
      "type": "string",
      "title": "From Meta"
    }
  }
}
EOF
	# Put different user_config in external file (should take priority)
	cat > "${PROJECT_ROOT}/user-config.json" << 'EOF'
{
  "file_key": {
    "type": "string",
    "title": "From File"
  }
}
EOF
	cat > "${PROJECT_ROOT}/mcpb.conf" << 'EOF'
MCPB_NAME="test-server"
MCPB_VERSION="1.0.0"
MCPB_USER_CONFIG_FILE="user-config.json"
EOF
	run bash -c "cd '${PROJECT_ROOT}' && '${MCPBASH_HOME}/bin/mcp-bash' bundle --output '${OUTPUT_DIR}'"
	[ "$status" -eq 0 ]
	unzip -q "${OUTPUT_DIR}/test-server-1.0.0.mcpb" -d "${EXTRACT_DIR}"
	# Should have file_key, not meta_key
	run jq -e '.user_config.file_key.title == "From File"' "${EXTRACT_DIR}/manifest.json"
	[ "$status" -eq 0 ]
	run jq -e '.user_config | has("meta_key") | not' "${EXTRACT_DIR}/manifest.json"
	[ "$status" -eq 0 ]
}

# ============================================================================
# MCPB Manifest Spec 0.3 - Optional Metadata Fields
# ============================================================================

@test "bundle: includes license from mcpb.conf" {
	rm -rf "${OUTPUT_DIR}"/* "${EXTRACT_DIR}"/*
	cat > "${PROJECT_ROOT}/mcpb.conf" << 'EOF'
MCPB_NAME="test-server"
MCPB_VERSION="1.0.0"
MCPB_LICENSE="MIT"
EOF
	run bash -c "cd '${PROJECT_ROOT}' && '${MCPBASH_HOME}/bin/mcp-bash' bundle --output '${OUTPUT_DIR}'"
	[ "$status" -eq 0 ]
	unzip -q "${OUTPUT_DIR}/test-server-1.0.0.mcpb" -d "${EXTRACT_DIR}"
	run jq -e '.license == "MIT"' "${EXTRACT_DIR}/manifest.json"
	[ "$status" -eq 0 ]
}

@test "bundle: includes keywords array from mcpb.conf" {
	rm -rf "${OUTPUT_DIR}"/* "${EXTRACT_DIR}"/*
	cat > "${PROJECT_ROOT}/mcpb.conf" << 'EOF'
MCPB_NAME="test-server"
MCPB_VERSION="1.0.0"
MCPB_KEYWORDS="cli automation bash mcp"
EOF
	run bash -c "cd '${PROJECT_ROOT}' && '${MCPBASH_HOME}/bin/mcp-bash' bundle --output '${OUTPUT_DIR}'"
	[ "$status" -eq 0 ]
	unzip -q "${OUTPUT_DIR}/test-server-1.0.0.mcpb" -d "${EXTRACT_DIR}"
	run jq -e '.keywords == ["cli", "automation", "bash", "mcp"]' "${EXTRACT_DIR}/manifest.json"
	[ "$status" -eq 0 ]
}

@test "bundle: includes homepage URL from mcpb.conf" {
	rm -rf "${OUTPUT_DIR}"/* "${EXTRACT_DIR}"/*
	cat > "${PROJECT_ROOT}/mcpb.conf" << 'EOF'
MCPB_NAME="test-server"
MCPB_VERSION="1.0.0"
MCPB_HOMEPAGE="https://example.com/my-tool"
EOF
	run bash -c "cd '${PROJECT_ROOT}' && '${MCPBASH_HOME}/bin/mcp-bash' bundle --output '${OUTPUT_DIR}'"
	[ "$status" -eq 0 ]
	unzip -q "${OUTPUT_DIR}/test-server-1.0.0.mcpb" -d "${EXTRACT_DIR}"
	run jq -e '.homepage == "https://example.com/my-tool"' "${EXTRACT_DIR}/manifest.json"
	[ "$status" -eq 0 ]
}

@test "bundle: includes documentation URL from mcpb.conf" {
	rm -rf "${OUTPUT_DIR}"/* "${EXTRACT_DIR}"/*
	cat > "${PROJECT_ROOT}/mcpb.conf" << 'EOF'
MCPB_NAME="test-server"
MCPB_VERSION="1.0.0"
MCPB_DOCUMENTATION="https://docs.example.com/my-tool"
EOF
	run bash -c "cd '${PROJECT_ROOT}' && '${MCPBASH_HOME}/bin/mcp-bash' bundle --output '${OUTPUT_DIR}'"
	[ "$status" -eq 0 ]
	unzip -q "${OUTPUT_DIR}/test-server-1.0.0.mcpb" -d "${EXTRACT_DIR}"
	run jq -e '.documentation == "https://docs.example.com/my-tool"' "${EXTRACT_DIR}/manifest.json"
	[ "$status" -eq 0 ]
}

@test "bundle: includes support URL from mcpb.conf" {
	rm -rf "${OUTPUT_DIR}"/* "${EXTRACT_DIR}"/*
	cat > "${PROJECT_ROOT}/mcpb.conf" << 'EOF'
MCPB_NAME="test-server"
MCPB_VERSION="1.0.0"
MCPB_SUPPORT="https://github.com/user/repo/issues"
EOF
	run bash -c "cd '${PROJECT_ROOT}' && '${MCPBASH_HOME}/bin/mcp-bash' bundle --output '${OUTPUT_DIR}'"
	[ "$status" -eq 0 ]
	unzip -q "${OUTPUT_DIR}/test-server-1.0.0.mcpb" -d "${EXTRACT_DIR}"
	run jq -e '.support == "https://github.com/user/repo/issues"' "${EXTRACT_DIR}/manifest.json"
	[ "$status" -eq 0 ]
}

@test "bundle: includes privacy_policies array from mcpb.conf" {
	rm -rf "${OUTPUT_DIR}"/* "${EXTRACT_DIR}"/*
	cat > "${PROJECT_ROOT}/mcpb.conf" << 'EOF'
MCPB_NAME="test-server"
MCPB_VERSION="1.0.0"
MCPB_PRIVACY_POLICIES="https://example.com/privacy https://example.com/gdpr"
EOF
	run bash -c "cd '${PROJECT_ROOT}' && '${MCPBASH_HOME}/bin/mcp-bash' bundle --output '${OUTPUT_DIR}'"
	[ "$status" -eq 0 ]
	unzip -q "${OUTPUT_DIR}/test-server-1.0.0.mcpb" -d "${EXTRACT_DIR}"
	run jq -e '.privacy_policies == ["https://example.com/privacy", "https://example.com/gdpr"]' "${EXTRACT_DIR}/manifest.json"
	[ "$status" -eq 0 ]
}

@test "bundle: includes compatibility.claude_desktop from mcpb.conf" {
	rm -rf "${OUTPUT_DIR}"/* "${EXTRACT_DIR}"/*
	cat > "${PROJECT_ROOT}/mcpb.conf" << 'EOF'
MCPB_NAME="test-server"
MCPB_VERSION="1.0.0"
MCPB_COMPAT_CLAUDE_DESKTOP=">=1.0.0"
EOF
	run bash -c "cd '${PROJECT_ROOT}' && '${MCPBASH_HOME}/bin/mcp-bash' bundle --output '${OUTPUT_DIR}'"
	[ "$status" -eq 0 ]
	unzip -q "${OUTPUT_DIR}/test-server-1.0.0.mcpb" -d "${EXTRACT_DIR}"
	run jq -e '.compatibility.claude_desktop == ">=1.0.0"' "${EXTRACT_DIR}/manifest.json"
	[ "$status" -eq 0 ]
	# platforms should still be present
	run jq -e '.compatibility.platforms | length > 0' "${EXTRACT_DIR}/manifest.json"
	[ "$status" -eq 0 ]
}

@test "bundle: includes compatibility.runtimes from mcpb.conf" {
	rm -rf "${OUTPUT_DIR}"/* "${EXTRACT_DIR}"/*
	cat > "${PROJECT_ROOT}/mcpb.conf" << 'EOF'
MCPB_NAME="test-server"
MCPB_VERSION="1.0.0"
MCPB_RUNTIME_PYTHON=">=3.8"
MCPB_RUNTIME_NODE=">=18"
EOF
	run bash -c "cd '${PROJECT_ROOT}' && '${MCPBASH_HOME}/bin/mcp-bash' bundle --output '${OUTPUT_DIR}'"
	[ "$status" -eq 0 ]
	unzip -q "${OUTPUT_DIR}/test-server-1.0.0.mcpb" -d "${EXTRACT_DIR}"
	run jq -e '.compatibility.runtimes.python == ">=3.8"' "${EXTRACT_DIR}/manifest.json"
	[ "$status" -eq 0 ]
	run jq -e '.compatibility.runtimes.node == ">=18"' "${EXTRACT_DIR}/manifest.json"
	[ "$status" -eq 0 ]
}

@test "bundle: omits empty optional metadata fields" {
	rm -rf "${OUTPUT_DIR}"/* "${EXTRACT_DIR}"/*
	cat > "${PROJECT_ROOT}/mcpb.conf" << 'EOF'
MCPB_NAME="test-server"
MCPB_VERSION="1.0.0"
EOF
	run bash -c "cd '${PROJECT_ROOT}' && '${MCPBASH_HOME}/bin/mcp-bash' bundle --output '${OUTPUT_DIR}'"
	[ "$status" -eq 0 ]
	unzip -q "${OUTPUT_DIR}/test-server-1.0.0.mcpb" -d "${EXTRACT_DIR}"
	# Should not have empty fields
	run jq -e 'has("license") | not' "${EXTRACT_DIR}/manifest.json"
	[ "$status" -eq 0 ]
	run jq -e 'has("keywords") | not' "${EXTRACT_DIR}/manifest.json"
	[ "$status" -eq 0 ]
	run jq -e 'has("homepage") | not' "${EXTRACT_DIR}/manifest.json"
	[ "$status" -eq 0 ]
	run jq -e 'has("privacy_policies") | not' "${EXTRACT_DIR}/manifest.json"
	[ "$status" -eq 0 ]
	run jq -e '.compatibility | has("claude_desktop") | not' "${EXTRACT_DIR}/manifest.json"
	[ "$status" -eq 0 ]
	run jq -e '.compatibility | has("runtimes") | not' "${EXTRACT_DIR}/manifest.json"
	[ "$status" -eq 0 ]
}

@test "bundle: includes all optional metadata fields together" {
	rm -rf "${OUTPUT_DIR}"/* "${EXTRACT_DIR}"/*
	cat > "${PROJECT_ROOT}/mcpb.conf" << 'EOF'
MCPB_NAME="full-metadata-server"
MCPB_VERSION="2.0.0"
MCPB_LICENSE="Apache-2.0"
MCPB_KEYWORDS="full featured server"
MCPB_HOMEPAGE="https://example.com"
MCPB_DOCUMENTATION="https://docs.example.com"
MCPB_SUPPORT="https://support.example.com"
MCPB_PRIVACY_POLICIES="https://example.com/privacy"
MCPB_COMPAT_CLAUDE_DESKTOP=">=1.5.0"
MCPB_RUNTIME_PYTHON=">=3.10"
EOF
	run bash -c "cd '${PROJECT_ROOT}' && '${MCPBASH_HOME}/bin/mcp-bash' bundle --output '${OUTPUT_DIR}'"
	[ "$status" -eq 0 ]
	unzip -q "${OUTPUT_DIR}/full-metadata-server-2.0.0.mcpb" -d "${EXTRACT_DIR}"
	# Verify all fields
	run jq -e '.license == "Apache-2.0"' "${EXTRACT_DIR}/manifest.json"
	[ "$status" -eq 0 ]
	run jq -e '.keywords == ["full", "featured", "server"]' "${EXTRACT_DIR}/manifest.json"
	[ "$status" -eq 0 ]
	run jq -e '.homepage == "https://example.com"' "${EXTRACT_DIR}/manifest.json"
	[ "$status" -eq 0 ]
	run jq -e '.documentation == "https://docs.example.com"' "${EXTRACT_DIR}/manifest.json"
	[ "$status" -eq 0 ]
	run jq -e '.support == "https://support.example.com"' "${EXTRACT_DIR}/manifest.json"
	[ "$status" -eq 0 ]
	run jq -e '.privacy_policies == ["https://example.com/privacy"]' "${EXTRACT_DIR}/manifest.json"
	[ "$status" -eq 0 ]
	run jq -e '.compatibility.claude_desktop == ">=1.5.0"' "${EXTRACT_DIR}/manifest.json"
	[ "$status" -eq 0 ]
	run jq -e '.compatibility.runtimes.python == ">=3.10"' "${EXTRACT_DIR}/manifest.json"
	[ "$status" -eq 0 ]
}
