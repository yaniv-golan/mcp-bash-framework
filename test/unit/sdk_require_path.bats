#!/usr/bin/env bats
# Unit layer: mcp_require_path helper.

load '../../node_modules/bats-support/load'
load '../../node_modules/bats-assert/load'
load '../common/fixtures'

setup() {
	# shellcheck source=lib/runtime.sh
	# shellcheck disable=SC1091
	. "${MCPBASH_HOME}/lib/runtime.sh"

	MCPBASH_FORCE_MINIMAL=false
	mcp_runtime_detect_json_tool
	if [ "${MCPBASH_MODE}" = "minimal" ]; then
		skip "JSON tooling unavailable for SDK helper tests"
	fi

	# shellcheck source=sdk/tool-sdk.sh
	# shellcheck disable=SC1091
	. "${MCPBASH_HOME}/sdk/tool-sdk.sh"

	ROOT_ONE="${BATS_TEST_TMPDIR}/root-one"
	ROOT_TWO="${BATS_TEST_TMPDIR}/root-two"
	mkdir -p "${ROOT_ONE}" "${ROOT_TWO}"
	ROOT_ONE_REALPATH="$(cd "${ROOT_ONE}" && pwd -P)"
	ROOT_TWO_REALPATH="$(cd "${ROOT_TWO}" && pwd -P)"
}

@test "sdk_require_path: defaults to single root when requested" {
	MCP_ROOTS_PATHS="${ROOT_ONE_REALPATH}"
	MCP_ROOTS_COUNT="1"
	MCP_TOOL_ARGS_JSON="{}"

	resolved="$(mcp_require_path '.path' --default-to-single-root)"
	assert_equal "${ROOT_ONE_REALPATH}" "${resolved}"
}

@test "sdk_require_path: rejects paths outside roots" {
	MCP_ROOTS_PATHS="${ROOT_ONE_REALPATH}"
	MCP_ROOTS_COUNT="1"
	MCP_TOOL_ARGS_JSON="$(printf '{"path":"%s"}' "${ROOT_TWO_REALPATH}")"

	run bash -c "
		export MCP_TOOL_ARGS_JSON='${MCP_TOOL_ARGS_JSON}'
		export MCP_ROOTS_PATHS='${MCP_ROOTS_PATHS}'
		export MCP_ROOTS_COUNT='${MCP_ROOTS_COUNT}'
		export MCPBASH_JSON_TOOL='${MCPBASH_JSON_TOOL:-}'
		export MCPBASH_JSON_TOOL_BIN='${MCPBASH_JSON_TOOL_BIN:-}'
		export MCPBASH_MODE='${MCPBASH_MODE:-full}'
		source '${MCPBASH_HOME}/sdk/tool-sdk.sh'
		mcp_require_path '.path' --default-to-single-root
	"
	assert_failure
}

@test "sdk_require_path: normalizes relative paths against cwd" {
	cd "${ROOT_ONE}"
	MCP_TOOL_ARGS_JSON='{"path":"./nested/../"}'
	MCP_ROOTS_PATHS="${ROOT_ONE_REALPATH}"
	MCP_ROOTS_COUNT="1"

	resolved_rel="$(mcp_require_path '.path')"
	assert_equal "${ROOT_ONE_REALPATH}" "${resolved_rel}"
}
