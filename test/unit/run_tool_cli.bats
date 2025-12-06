#!/usr/bin/env bash
# Unit layer: CLI run-tool wrapper.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

# shellcheck source=test/common/env.sh
# shellcheck disable=SC1091
. "${REPO_ROOT}/test/common/env.sh"
# shellcheck source=test/common/assert.sh
# shellcheck disable=SC1091
. "${REPO_ROOT}/test/common/assert.sh"

test_require_command jq

test_create_tmpdir
PROJECT_ROOT="${TEST_TMPDIR}/proj"
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

printf ' -> print-env shows wiring without executing tool\n'
env_output="$("${REPO_ROOT}/bin/mcp-bash" run-tool test.echo --print-env)"
assert_contains "MCPBASH_PROJECT_ROOT=${PROJECT_ROOT}" "${env_output}"
assert_contains "ROOTS=none" "${env_output}"

printf ' -> dry-run does not execute tool\n'
"${REPO_ROOT}/bin/mcp-bash" run-tool test.sideeffect --dry-run >/dev/null
if [ -e "${side_effect_file}" ]; then
	test_fail "dry-run executed tool"
fi

printf ' -> happy path returns structured content\n'
echo_output="$("${REPO_ROOT}/bin/mcp-bash" run-tool test.echo --args '{"value":"ok"}')"
echo_message="$(printf '%s\n' "${echo_output}" | jq -r 'select(.name=="test.echo") | .structuredContent.message')"
assert_eq "ok" "${echo_message}" "run-tool did not return expected message"

printf ' -> tool not found surfaces error\n'
if "${REPO_ROOT}/bin/mcp-bash" run-tool test.missing >/dev/null 2>/"${TEST_TMPDIR}/err"; then
	test_fail "run-tool should fail for missing tool"
fi
assert_contains "tool not found" "$(cat "${TEST_TMPDIR}/err")"

printf ' -> invalid args must be rejected\n'
if "${REPO_ROOT}/bin/mcp-bash" run-tool test.echo --args '"not-an-object"' >/dev/null 2>/"${TEST_TMPDIR}/args_err"; then
	test_fail "run-tool should fail for non-object args"
fi
assert_contains "JSON object" "$(cat "${TEST_TMPDIR}/args_err")"

printf ' -> timeout override permits slow tool\n'
if "${REPO_ROOT}/bin/mcp-bash" run-tool test.slow >/dev/null 2>/"${TEST_TMPDIR}/slow_err"; then
	test_fail "expected slow tool to time out with metadata timeout"
fi
slow_override_output="$("${REPO_ROOT}/bin/mcp-bash" run-tool test.slow --timeout 8)"
slow_message="$(printf '%s\n' "${slow_override_output}" | jq -r 'select(.name=="test.slow") | .structuredContent.message')"
assert_eq "done" "${slow_message}" "timeout override did not allow tool to complete"

printf 'run-tool CLI tests passed.\n'
