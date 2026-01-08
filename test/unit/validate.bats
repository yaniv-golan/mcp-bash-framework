#!/usr/bin/env bats
# Unit tests for validation helpers.

load '../../node_modules/bats-support/load'
load '../../node_modules/bats-assert/load'
load '../common/fixtures'

setup() {
	# shellcheck source=lib/validate.sh
	# shellcheck disable=SC1091
	. "${MCPBASH_HOME}/lib/validate.sh"

	MCPBASH_JSON_TOOL_BIN="$(command -v jq)"
	MCPBASH_JSON_TOOL="jq"
}

@test "validate: server meta missing yields warning only" {
	MCPBASH_SERVER_DIR="${BATS_TEST_TMPDIR}/server.d"
	mkdir -p "${MCPBASH_SERVER_DIR}"

	output="$(mcp_validate_server_meta "true" 2>/dev/null | tail -n 1)"
	read -r err warn <<<"${output}"

	assert_equal "0" "${err}"
	assert_equal "1" "${warn}"
}

@test "validate: tool chmod fix applies and reports fix count" {
	MCPBASH_TOOLS_DIR="${BATS_TEST_TMPDIR}/tools"
	mkdir -p "${MCPBASH_TOOLS_DIR}/hello"

	cat >"${MCPBASH_TOOLS_DIR}/hello/tool.meta.json" <<'EOF'
{
  "name": "hello",
  "description": "hi",
  "inputSchema": {"type": "object", "properties": {}}
}
EOF
	cat >"${MCPBASH_TOOLS_DIR}/hello/tool.sh" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
	chmod 644 "${MCPBASH_TOOLS_DIR}/hello/tool.sh"

	output="$(mcp_validate_tools "${MCPBASH_TOOLS_DIR}" "true" "true" 2>/dev/null | tail -n 1)"
	read -r terr twarn tfix <<<"${output}"

	assert_equal "0" "${terr}"
	assert_equal "1" "${twarn}"
	assert_equal "1" "${tfix}"

	[ -x "${MCPBASH_TOOLS_DIR}/hello/tool.sh" ]
}

@test "validate: resource with uri is valid" {
	local resources_dir="${BATS_TEST_TMPDIR}/resources"
	mkdir -p "${resources_dir}/test-res"

	cat >"${resources_dir}/test-res/test-res.meta.json" <<'EOF'
{
  "name": "test-resource",
  "uri": "test://example/resource"
}
EOF

	run mcp_validate_resources "${resources_dir}" "true" "false"
	assert_success
	assert_output --partial '✓ resources/test-res/test-res.meta.json - valid'
}

@test "validate: resource with uriTemplate is valid" {
	local resources_dir="${BATS_TEST_TMPDIR}/resources"
	mkdir -p "${resources_dir}/test-res"

	cat >"${resources_dir}/test-res/test-res.meta.json" <<'EOF'
{
  "name": "test-template",
  "uriTemplate": "test://example/{id}"
}
EOF

	run mcp_validate_resources "${resources_dir}" "true" "false"
	assert_success
	assert_output --partial '✓ resources/test-res/test-res.meta.json - valid'
}

@test "validate: resource with both uri and uriTemplate warns" {
	local resources_dir="${BATS_TEST_TMPDIR}/resources"
	mkdir -p "${resources_dir}/test-res"

	cat >"${resources_dir}/test-res/test-res.meta.json" <<'EOF'
{
  "name": "test-both",
  "uri": "test://example/resource",
  "uriTemplate": "test://example/{id}"
}
EOF

	run mcp_validate_resources "${resources_dir}" "true" "false"
	assert_success
	assert_output --partial 'uri and uriTemplate are mutually exclusive'
}

@test "validate: resource with neither uri nor uriTemplate errors" {
	local resources_dir="${BATS_TEST_TMPDIR}/resources"
	mkdir -p "${resources_dir}/test-res"

	cat >"${resources_dir}/test-res/test-res.meta.json" <<'EOF'
{
  "name": "test-missing"
}
EOF

	run mcp_validate_resources "${resources_dir}" "true" "false"
	assert_success
	assert_output --partial 'missing required "uri" or "uriTemplate"'
}

@test "validate: uriTemplate without variable placeholder errors" {
	local resources_dir="${BATS_TEST_TMPDIR}/resources"
	mkdir -p "${resources_dir}/test-res"

	cat >"${resources_dir}/test-res/test-res.meta.json" <<'EOF'
{
  "name": "test-bad-template",
  "uriTemplate": "test://example/no-variable"
}
EOF

	run mcp_validate_resources "${resources_dir}" "true" "false"
	assert_success
	assert_output --partial 'uriTemplate must contain {variable} placeholder'
}
