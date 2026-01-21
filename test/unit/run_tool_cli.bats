#!/usr/bin/env bats
# Unit layer: CLI run-tool wrapper.

load '../../node_modules/bats-support/load'
load '../../node_modules/bats-assert/load'
load '../common/fixtures'
load '../common/ndjson'

setup() {
	PROJECT_ROOT="${BATS_TEST_TMPDIR}/proj"
	export MCPBASH_PROJECT_ROOT="${PROJECT_ROOT}"
	mkdir -p "${PROJECT_ROOT}/tools/echo" "${PROJECT_ROOT}/tools/sideeffect" "${PROJECT_ROOT}/tools/slow" "${PROJECT_ROOT}/server.d"

	cat >"${PROJECT_ROOT}/server.d/server.meta.json" <<'EOF'
{"name":"cli-runner"}
EOF

	cat >"${PROJECT_ROOT}/tools/echo/tool.meta.json" <<'EOF'
{
  "name": "test.echo",
  "description": "Echo a provided value",
  "inputSchema": {
    "type": "object",
    "required": ["value"],
    "properties": { "value": { "type": "string" } }
  },
  "outputSchema": {
    "type": "object",
    "required": ["message"],
    "properties": { "message": { "type": "string" } }
  }
}
EOF

	cat >"${PROJECT_ROOT}/tools/echo/tool.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
source "${MCP_SDK}/tool-sdk.sh"
value="$(mcp_args_require '.value')"
mcp_emit_json "$(mcp_json_obj message "${value}")"
EOF
	chmod +x "${PROJECT_ROOT}/tools/echo/tool.sh"

	side_effect_file="${PROJECT_ROOT}/.sideeffect-ran"
	cat >"${PROJECT_ROOT}/tools/sideeffect/tool.meta.json" <<'EOF'
{
  "name": "test.sideeffect",
  "description": "Side effect sentinel",
  "inputSchema": { "type": "object" }
}
EOF
	cat >"${PROJECT_ROOT}/tools/sideeffect/tool.sh" <<EOF
#!/usr/bin/env bash
set -euo pipefail
source "\${MCP_SDK}/tool-sdk.sh"
touch "${side_effect_file}"
mcp_emit_json "\$(mcp_json_obj message \"ran\")"
EOF
	chmod +x "${PROJECT_ROOT}/tools/sideeffect/tool.sh"

	cat >"${PROJECT_ROOT}/tools/slow/tool.meta.json" <<'EOF'
{
  "name": "test.slow",
  "description": "Sleep to test timeout overrides",
  "timeoutSecs": 2,
  "inputSchema": { "type": "object" }
}
EOF
	cat >"${PROJECT_ROOT}/tools/slow/tool.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
source "${MCP_SDK}/tool-sdk.sh"
sleep 5
mcp_emit_json "$(mcp_json_obj message "done")"
EOF
	chmod +x "${PROJECT_ROOT}/tools/slow/tool.sh"
}

@test "run_tool_cli: print-env shows wiring without executing tool" {
	env_output="$("${MCPBASH_HOME}/bin/mcp-bash" run-tool test.echo --print-env)"
	assert_contains "MCPBASH_PROJECT_ROOT=${PROJECT_ROOT}" "${env_output}"
	assert_contains "ROOTS=none" "${env_output}"
}

@test "run_tool_cli: dry-run does not execute tool" {
	run "${MCPBASH_HOME}/bin/mcp-bash" run-tool test.sideeffect --dry-run
	assert_success
	[ ! -e "${PROJECT_ROOT}/.sideeffect-ran" ]
}

@test "run_tool_cli: happy path returns structured content" {
	echo_output="$("${MCPBASH_HOME}/bin/mcp-bash" run-tool test.echo --args '{"value":"ok"}')"
	echo_message="$(printf '%s\n' "${echo_output}" | jq -r 'select(.name=="test.echo") | .structuredContent.message')"
	assert_equal "ok" "${echo_message}"
}

@test "run_tool_cli: tool not found surfaces error" {
	run "${MCPBASH_HOME}/bin/mcp-bash" run-tool test.missing
	assert_failure
	assert_output --partial "tool not found"
}

@test "run_tool_cli: invalid args must be rejected" {
	run "${MCPBASH_HOME}/bin/mcp-bash" run-tool test.echo --args '"not-an-object"'
	assert_failure
	assert_output --partial "JSON object"
}

@test "run_tool_cli: --no-refresh fails loudly on corrupt cache" {
	mkdir -p "${PROJECT_ROOT}/.registry"
	printf '%s\n' '{"not":"a-tools-registry"' >"${PROJECT_ROOT}/.registry/tools.json"

	run "${MCPBASH_HOME}/bin/mcp-bash" run-tool test.echo --no-refresh --args '{"value":"ok"}'
	assert_failure
	assert_output --partial "invalid tools registry cache"
}

@test "run_tool_cli: timeout override permits slow tool" {
	# Without override, tool should timeout (returns isError:true, exit 0)
	timeout_output="$("${MCPBASH_HOME}/bin/mcp-bash" run-tool test.slow)"
	timeout_is_error="$(printf '%s\n' "${timeout_output}" | jq -r '.isError')"
	assert_equal "true" "${timeout_is_error}"
	# Verify it's a timeout error
	timeout_type="$(printf '%s\n' "${timeout_output}" | jq -r '.structuredContent.error.type')"
	assert_equal "timeout" "${timeout_type}"

	# With override, tool should complete successfully
	slow_override_output="$("${MCPBASH_HOME}/bin/mcp-bash" run-tool test.slow --timeout 8)"
	slow_message="$(printf '%s\n' "${slow_override_output}" | jq -r 'select(.name=="test.slow") | .structuredContent.message')"
	assert_equal "done" "${slow_message}"
}
