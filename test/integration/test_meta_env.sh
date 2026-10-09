#!/usr/bin/env bash
# shellcheck disable=SC2034  # Used by test runner for reporting.
TEST_DESC="Declarative env policy in server.meta.json reaches tools, resource and completion providers."
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../common/env.sh
# shellcheck disable=SC1091
. "${SCRIPT_DIR}/../common/env.sh"
# shellcheck source=../common/assert.sh
# shellcheck disable=SC1091
. "${SCRIPT_DIR}/../common/assert.sh"

test_require_command jq
test_create_tmpdir

# Bundle-style launch: the host injects SECRET_X but sets no env policy.
export SECRET_X="from-host"
export MCPBASH_TOOL_ALLOWLIST="*"
unset MCPBASH_TOOL_ENV_MODE MCPBASH_TOOL_ENV_ALLOWLIST MCPBASH_PROVIDER_ENV_MODE MCPBASH_PROVIDER_ENV_ALLOWLIST

stage_project() {
	local ws="$1"
	test_stage_workspace "${ws}"
	mkdir -p "${ws}/tools/show" "${ws}/providers" "${ws}/resources" "${ws}/completions" "${ws}/server.d"
	cat >"${ws}/tools/show/tool.meta.json" <<'JSON'
{"name": "show", "description": "Show SECRET_X", "inputSchema": {"type": "object"}}
JSON
	cat >"${ws}/tools/show/tool.sh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
source "${MCP_SDK}/tool-sdk.sh"
mcp_emit_json "$(mcp_json_obj secret "${SECRET_X:-absent}")"
SH
	cat >"${ws}/providers/sec.sh" <<'SH'
#!/usr/bin/env bash
printf 'secret=%s' "${SECRET_X:-absent}"
SH
	cat >"${ws}/resources/sec.meta.json" <<'JSON'
{"name": "sec", "uriTemplate": "sec://{id}"}
JSON
	cat >"${ws}/completions/suggest.sh" <<'SH'
#!/usr/bin/env bash
printf '["%s"]' "${SECRET_X:-absent}"
SH
	cat >"${ws}/server.d/register.json" <<'JSON'
{"version": 1, "completions": [{"name": "sec.completion", "path": "completions/suggest.sh", "timeoutSecs": 5}]}
JSON
	chmod +x "${ws}/tools/show/tool.sh" "${ws}/providers/sec.sh" "${ws}/completions/suggest.sh"
	chmod -R go-w "${ws}"
}

write_requests() {
	cat >"$1" <<'JSON'
{"jsonrpc":"2.0","id":"init","method":"initialize","params":{}}
{"jsonrpc":"2.0","method":"notifications/initialized"}
{"jsonrpc":"2.0","id":"tool","method":"tools/call","params":{"name":"show","arguments":{}}}
{"jsonrpc":"2.0","id":"res","method":"resources/read","params":{"uri":"sec://1"}}
{"jsonrpc":"2.0","id":"comp","method":"completion/complete","params":{"ref":{"type":"ref/prompt","name":"sec.completion"},"argument":{"name":"q","value":""}}}
JSON
}

read_results() {
	local responses="$1"
	tool_out="$(jq -r 'select(.id=="tool") | (.result.structuredContent.secret // .result.content[0].text // .error.message // empty)' "${responses}")"
	res_out="$(jq -r 'select(.id=="res") | (.result.contents[0].text // .error.message // empty)' "${responses}")"
	comp_out="$(jq -r 'select(.id=="comp") | (.result.completion.values[0] // .error.message // empty)' "${responses}")"
}

# --- With the env section: all three see SECRET_X ---
WITH="${TEST_TMPDIR}/with"
stage_project "${WITH}"
cat >"${WITH}/server.d/server.meta.json" <<'JSON'
{"name": "meta-env", "env": {
  "MCPBASH_TOOL_ENV_MODE": "allowlist", "MCPBASH_TOOL_ENV_ALLOWLIST": "SECRET_X",
  "MCPBASH_PROVIDER_ENV_MODE": "allowlist", "MCPBASH_PROVIDER_ENV_ALLOWLIST": "SECRET_X"}}
JSON
chmod go-w "${WITH}/server.d/server.meta.json"
write_requests "${WITH}/requests.ndjson"
test_run_mcp "${WITH}" "${WITH}/requests.ndjson" "${WITH}/responses.ndjson" || true
read_results "${WITH}/responses.ndjson"
assert_contains "from-host" "${tool_out}" "tool should receive SECRET_X via server.meta.json env"
assert_eq "secret=from-host" "${res_out}" "resource provider should receive SECRET_X"
assert_eq "from-host" "${comp_out}" "completion provider should receive SECRET_X"

# --- Without the env section: none of them see it ---
WITHOUT="${TEST_TMPDIR}/without"
stage_project "${WITHOUT}"
printf '%s\n' '{"name": "meta-env"}' >"${WITHOUT}/server.d/server.meta.json"
chmod go-w "${WITHOUT}/server.d/server.meta.json"
write_requests "${WITHOUT}/requests.ndjson"
test_run_mcp "${WITHOUT}" "${WITHOUT}/requests.ndjson" "${WITHOUT}/responses.ndjson" || true
read_results "${WITHOUT}/responses.ndjson"
assert_contains "absent" "${tool_out}" "tool must not receive SECRET_X without a policy"
assert_eq "secret=absent" "${res_out}" "resource provider must not receive SECRET_X without a policy"
assert_eq "absent" "${comp_out}" "completion provider must not receive SECRET_X without a policy"

# --- inherit from server.meta.json still needs the operator's INHERIT_ALLOW ---
INHERIT="${TEST_TMPDIR}/inherit"
stage_project "${INHERIT}"
printf '%s\n' '{"name": "meta-env", "env": {"MCPBASH_TOOL_ENV_MODE": "inherit"}}' >"${INHERIT}/server.d/server.meta.json"
chmod go-w "${INHERIT}/server.d/server.meta.json"
write_requests "${INHERIT}/requests.ndjson"
test_run_mcp "${INHERIT}" "${INHERIT}/requests.ndjson" "${INHERIT}/responses.ndjson" || true
inherit_refused="$(jq -r 'select(.id=="tool") | has("error")' "${INHERIT}/responses.ndjson")"
assert_eq "true" "${inherit_refused}" "inherit from server.meta.json must still require the operator opt-in"
if grep -q "from-host" "${INHERIT}/responses.ndjson"; then
	test_fail "SECRET_X leaked through inherit mode without INHERIT_ALLOW"
fi

printf 'Declarative env policy integration test passed.\n'
