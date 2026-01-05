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
