#!/usr/bin/env bats
# Unit: tool SDK should not leak args/meta payloads in bash -x traces.

load '../../node_modules/bats-support/load'
load '../../node_modules/bats-assert/load'
load '../common/fixtures'

setup() {
	trace_file="${BATS_TEST_TMPDIR}/sdk.trace.log"
	secret_marker="SHOULD_NOT_APPEAR_IN_TRACE"
}

@test "sdk_trace_redaction: sdk does not leak payload expansions in xtrace" {
	trace_file="${BATS_TEST_TMPDIR}/sdk.trace.log"
	secret_marker="SHOULD_NOT_APPEAR_IN_TRACE"

	(
		set -euo pipefail

		# Configure JSON tooling as the server would.
		MCPBASH_JSON_TOOL_BIN="${TEST_JSON_TOOL_BIN}"
		MCPBASH_JSON_TOOL="$(basename "${TEST_JSON_TOOL_BIN}")"
		case "${MCPBASH_JSON_TOOL}" in
		jq | gojq) ;;
		*) MCPBASH_JSON_TOOL="jq" ;;
		esac
		export MCPBASH_JSON_TOOL MCPBASH_JSON_TOOL_BIN
		MCPBASH_MODE="full"
		export MCPBASH_MODE

		# Secret-bearing payloads (must not appear in the trace).
		MCP_TOOL_ARGS_JSON="{\"token\":\"${secret_marker}\",\"foo\":\"bar\"}"
		MCP_TOOL_META_JSON="{\"client_secret\":\"${secret_marker}\"}"
		export MCP_TOOL_ARGS_JSON MCP_TOOL_META_JSON

		# Route xtrace output to a file.
		: >"${trace_file}"
		exec 9>"${trace_file}"
		export BASH_XTRACEFD=9
		export PS4='+ '
		set -x

		# shellcheck source=sdk/tool-sdk.sh
		# shellcheck disable=SC1091
		. "${MCPBASH_HOME}/sdk/tool-sdk.sh"

		# These should not cause the full JSON payload to be expanded in xtrace output.
		mcp_args_raw >/dev/null 2>&1 || true
		mcp_args_get '.token' >/dev/null 2>&1 || true
		mcp_meta_raw >/dev/null 2>&1 || true
		mcp_meta_get '.client_secret' >/dev/null 2>&1 || true

		set +x
	)

	# Positive assertion: tracing produced some output.
	[ -s "${trace_file}" ]

	# Critical assertion: secret marker must not appear in trace.
	run grep -- "${secret_marker}" "${trace_file}"
	assert_failure

	# Sanity: confirm we captured function names (trace still useful).
	run cat "${trace_file}"
	assert_output --regexp "(mcp_args_get|mcp_meta_get)"
}
