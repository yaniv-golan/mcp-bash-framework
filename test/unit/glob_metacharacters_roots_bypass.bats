#!/usr/bin/env bats
# Unit: regression for roots/tool containment checks with glob metacharacters.
#
# Paths may legally contain glob metacharacters like []?*. Using [[ == "${root}/"* ]]
# or case "${candidate}" in "${root}"/*) turns a literal prefix check into a wildcard
# match (e.g., root[1] matches root1), which can bypass roots containment.

load '../../node_modules/bats-support/load'
load '../../node_modules/bats-assert/load'
load '../common/fixtures'

setup() {
	ROOT_GLOB="${BATS_TEST_TMPDIR}/root[1]"
	ROOT_SIBLING="${BATS_TEST_TMPDIR}/root1"
	mkdir -p "${ROOT_GLOB}" "${ROOT_SIBLING}"

	ROOT_GLOB_REALPATH="$(cd "${ROOT_GLOB}" && pwd -P)"
	ROOT_SIBLING_REALPATH="$(cd "${ROOT_SIBLING}" && pwd -P)"

	SECRET_PATH="${ROOT_SIBLING_REALPATH}/secret.txt"
	printf 'secret\n' >"${SECRET_PATH}"
}

@test "glob: file provider root[1] must not match root1" {
	run bash -c "MCP_RESOURCES_ROOTS='${ROOT_GLOB_REALPATH}' '${MCPBASH_HOME}/providers/file.sh' 'file://${SECRET_PATH}'"
	assert_equal "2" "${status}"
}

@test "glob: mcp_roots_contains_path must not treat [] as wildcard" {
	# shellcheck source=lib/roots.sh
	# shellcheck disable=SC1091
	. "${MCPBASH_HOME}/lib/roots.sh"
	MCPBASH_ROOTS_PATHS=("${ROOT_GLOB_REALPATH}")

	run mcp_roots_contains_path "${SECRET_PATH}"
	assert_failure
}

@test "glob: sdk mcp_roots_contains must not treat [] as wildcard" {
	# shellcheck source=lib/runtime.sh
	# shellcheck disable=SC1091
	. "${MCPBASH_HOME}/lib/runtime.sh"
	MCPBASH_FORCE_MINIMAL=false
	mcp_runtime_detect_json_tool
	if [ "${MCPBASH_MODE}" = "minimal" ]; then
		skip "JSON tooling unavailable"
	fi

	# shellcheck source=sdk/tool-sdk.sh
	# shellcheck disable=SC1091
	. "${MCPBASH_HOME}/sdk/tool-sdk.sh"
	MCP_ROOTS_PATHS="${ROOT_GLOB_REALPATH}"
	MCP_ROOTS_COUNT="1"

	run mcp_roots_contains "${SECRET_PATH}"
	assert_failure
}

@test "glob: mcp_tools_validate_path must not treat [] as wildcard" {
	# shellcheck source=lib/tools.sh
	# shellcheck disable=SC1091
	. "${MCPBASH_HOME}/lib/tools.sh"

	TOOLS_GLOB="${BATS_TEST_TMPDIR}/tools[1]"
	TOOLS_SIBLING="${BATS_TEST_TMPDIR}/tools1"
	mkdir -p "${TOOLS_GLOB}" "${TOOLS_SIBLING}"
	TOOL_PATH="${TOOLS_SIBLING}/t.sh"
	printf '#!/usr/bin/env bash\nprintf ok\n' >"${TOOL_PATH}"
	chmod 700 "${TOOL_PATH}" 2>/dev/null || true

	MCPBASH_TOOLS_DIR="${TOOLS_GLOB}"
	export MCPBASH_TOOLS_DIR

	run mcp_tools_validate_path "${TOOL_PATH}"
	assert_failure
}
