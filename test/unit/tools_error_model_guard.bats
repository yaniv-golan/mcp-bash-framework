#!/usr/bin/env bats
# Unit layer: once a tool has run, its failures are error results, never
# JSON-RPC errors. Only framework faults may still use _mcp_tools_emit_error
# after the tool exits.

load '../../node_modules/bats-support/load'
load '../../node_modules/bats-assert/load'
load '../common/fixtures'

# Print the lines of FUNCTION (in lib/tools.sh) from the first line matching
# START to the end of the function.
tools_fn_from() {
	awk -v fn="$1() {" -v start="$2" '
		$0 == fn { infn = 1 }
		infn && index($0, start) { on = 1 }
		on { print }
		infn && $0 == "}" { exit }
	' "${MCPBASH_HOME}/lib/tools.sh"
}

@test "error model guard: no tool failure becomes a JSON-RPC error after the tool runs" {
	local after_run
	after_run="$(tools_fn_from mcp_tools_call 'exit_code=${exit_code:-0}')"
	[ -n "${after_run}" ] || fail "could not find the post-run part of mcp_tools_call"
	local calls
	calls="$(printf '%s\n' "${after_run}" | grep '_mcp_tools_emit_error ' || true)"
	# Allowed: a cancelled call (dropped before it reaches the client) and a
	# failure to attach embedded resources (a framework fault).
	local unexpected
	unexpected="$(printf '%s\n' "${calls}" | grep -v -e '"Tool cancelled"' -e '"Unable to attach embedded resources to tool result"' | grep -v '^$' || true)"
	[ -z "${unexpected}" ] || fail "tool failures still sent as JSON-RPC errors:
${unexpected}"
}

@test "error model guard: outputSchema failures are error results unless the check can't run" {
	local body
	body="$(tools_fn_from mcp_tools_validate_output_schema 'local stdout_file')"
	[ -n "${body}" ] || fail "could not find mcp_tools_validate_output_schema"
	local unexpected
	unexpected="$(printf '%s\n' "${body}" | grep '_mcp_tools_emit_error ' | grep -v '"Unable to check tool output against outputSchema"' || true)"
	[ -z "${unexpected}" ] || fail "outputSchema failures still sent as JSON-RPC errors:
${unexpected}"
}
