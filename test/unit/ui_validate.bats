#!/usr/bin/env bats
# Unit tests for MCP Apps / UI author-time validation warnings.

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

# Build a clean, otherwise-valid tool whose only validation concern is the
# thing under test, so warning counts are unambiguous.
_make_clean_tool() {
	local dir="$1"
	local meta="$2"
	mkdir -p "${dir}"
	printf '%s' "${meta}" >"${dir}/tool.meta.json"
	cat >"${dir}/tool.sh" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
	chmod +x "${dir}/tool.sh"
}

@test "validate: deprecated flat _meta[\"ui/resourceUri\"] warns" {
	MCPBASH_TOOLS_DIR="${BATS_TEST_TMPDIR}/tools"
	_make_clean_tool "${MCPBASH_TOOLS_DIR}/my-tool" \
		'{"name":"my-tool","description":"hi","inputSchema":{"type":"object","properties":{}},"_meta":{"ui/resourceUri":"ui://s/my-tool"}}'

	run mcp_validate_tools "${MCPBASH_TOOLS_DIR}" "true" "false"
	assert_success
	assert_output --partial 'ui/resourceUri'
	assert_output --partial 'deprecated'

	local counts
	counts="$(mcp_validate_tools "${MCPBASH_TOOLS_DIR}" "true" "false" 2>/dev/null | tail -n 1)"
	read -r terr twarn tfix <<<"${counts}"
	assert_equal "0" "${terr}"
	assert_equal "1" "${twarn}"
	assert_equal "0" "${tfix}"
}

@test "validate: nested _meta.ui.resourceUri does NOT warn" {
	MCPBASH_TOOLS_DIR="${BATS_TEST_TMPDIR}/tools"
	_make_clean_tool "${MCPBASH_TOOLS_DIR}/my-tool" \
		'{"name":"my-tool","description":"hi","inputSchema":{"type":"object","properties":{}},"_meta":{"ui":{"resourceUri":"ui://s/my-tool"}}}'

	local counts
	counts="$(mcp_validate_tools "${MCPBASH_TOOLS_DIR}" "true" "false" 2>/dev/null | tail -n 1)"
	read -r terr twarn tfix <<<"${counts}"
	assert_equal "0" "${terr}"
	assert_equal "0" "${twarn}"
}

@test "validate: unknown ui.meta.json permission key warns (tools/*/ui)" {
	MCPBASH_TOOLS_DIR="${BATS_TEST_TMPDIR}/tools"
	MCPBASH_PROJECT_ROOT="${BATS_TEST_TMPDIR}"
	mkdir -p "${MCPBASH_TOOLS_DIR}/my-tool/ui"
	printf '%s' '{"meta":{"permissions":{"microhpone":true}}}' \
		>"${MCPBASH_TOOLS_DIR}/my-tool/ui/ui.meta.json"

	run mcp_validate_ui_meta "${MCPBASH_TOOLS_DIR}" "${MCPBASH_PROJECT_ROOT}" "true"
	assert_success
	assert_output --partial 'microhpone'

	local counts
	counts="$(mcp_validate_ui_meta "${MCPBASH_TOOLS_DIR}" "${MCPBASH_PROJECT_ROOT}" "true" 2>/dev/null | tail -n 1)"
	read -r uerr uwarn ufix <<<"${counts}"
	assert_equal "0" "${uerr}"
	assert_equal "1" "${uwarn}"
}

@test "validate: known ui.meta.json permission keys do NOT warn" {
	MCPBASH_TOOLS_DIR="${BATS_TEST_TMPDIR}/tools"
	MCPBASH_PROJECT_ROOT="${BATS_TEST_TMPDIR}"
	mkdir -p "${MCPBASH_PROJECT_ROOT}/ui/dash"
	printf '%s' '{"meta":{"permissions":{"camera":true,"clipboardWrite":true}}}' \
		>"${MCPBASH_PROJECT_ROOT}/ui/dash/ui.meta.json"

	local counts
	counts="$(mcp_validate_ui_meta "${MCPBASH_TOOLS_DIR}" "${MCPBASH_PROJECT_ROOT}" "true" 2>/dev/null | tail -n 1)"
	read -r uerr uwarn ufix <<<"${counts}"
	assert_equal "0" "${uerr}"
	assert_equal "0" "${uwarn}"
}
