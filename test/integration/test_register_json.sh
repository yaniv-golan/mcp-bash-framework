#!/usr/bin/env bash
# shellcheck disable=SC2034  # Used by test runner for reporting.
TEST_DESC="Declarative server.d/register.json overrides without executing register.sh"
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../common/env.sh
# shellcheck disable=SC1091
. "${SCRIPT_DIR}/../common/env.sh"
# shellcheck source=../common/assert.sh
# shellcheck disable=SC1091
. "${SCRIPT_DIR}/../common/assert.sh"

test_create_tmpdir

WORKSPACE="${TEST_TMPDIR}/workspace"
test_stage_workspace "${WORKSPACE}"
mkdir -p "${WORKSPACE}/prompts"

# Case A: register.json present but does not declare prompts => prompts fall through to discovery.
cat >"${WORKSPACE}/prompts/demo.txt" <<'EOF'
demo
EOF
cat >"${WORKSPACE}/prompts/demo.meta.json" <<'EOF'
{
  "name": "demo-prompt",
  "description": "Demo prompt",
  "path": "demo.txt",
  "arguments": {"type":"object","properties":{}}
}
EOF

cat >"${WORKSPACE}/server.d/register.json" <<'EOF'
{
  "version": 1,
  "tools": []
}
EOF

REQUESTS="${WORKSPACE}/requests.ndjson"
RESPONSES="${WORKSPACE}/responses.ndjson"
cat >"${REQUESTS}" <<'JSON'
{"jsonrpc":"2.0","id":"init","method":"initialize","params":{}}
{"jsonrpc":"2.0","method":"notifications/initialized"}
{"jsonrpc":"2.0","id":"list","method":"prompts/list","params":{"limit":50}}
JSON

test_run_mcp "${WORKSPACE}" "${REQUESTS}" "${RESPONSES}"
assert_json_lines "${RESPONSES}"

found_name="$(jq -r 'select(.id=="list") | .result.prompts[].name // empty' "${RESPONSES}" | grep -Fx "demo-prompt" || true)"
if [ -z "${found_name}" ]; then
	test_fail "expected demo-prompt to be discoverable when register.json omits prompts key"
fi

# Case B: register.json declares prompts as empty array => prompts are disabled (no scan).
cat >"${WORKSPACE}/server.d/register.json" <<'EOF'
{
  "version": 1,
  "prompts": []
}
EOF

REQUESTS="${WORKSPACE}/requests_b.ndjson"
RESPONSES="${WORKSPACE}/responses_b.ndjson"
cat >"${REQUESTS}" <<'JSON'
{"jsonrpc":"2.0","id":"init","method":"initialize","params":{}}
{"jsonrpc":"2.0","method":"notifications/initialized"}
{"jsonrpc":"2.0","id":"list","method":"prompts/list","params":{"limit":50}}
JSON

test_run_mcp "${WORKSPACE}" "${REQUESTS}" "${RESPONSES}"
assert_json_lines "${RESPONSES}"

found_name="$(jq -r 'select(.id=="list") | .result.prompts[].name // empty' "${RESPONSES}" | grep -Fx "demo-prompt" || true)"
if [ -n "${found_name}" ]; then
	test_fail "expected demo-prompt to be hidden when register.json declares prompts: []"
fi

# Case C: invalid register.json fails closed and does not fall back to register.sh.
cat >"${WORKSPACE}/server.d/register.json" <<'EOF'
{
  "version": 1,
  "prompts": [
EOF

cat >"${WORKSPACE}/server.d/register.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
# If this runs, it will leave a marker file.
printf 'ran\n' >"${MCPBASH_PROJECT_ROOT}/hook_ran.txt"
# No registrations.
exit 0
EOF
chmod +x "${WORKSPACE}/server.d/register.sh"
rm -f "${WORKSPACE}/hook_ran.txt"

REQUESTS="${WORKSPACE}/requests_c.ndjson"
RESPONSES="${WORKSPACE}/responses_c.ndjson"
cat >"${REQUESTS}" <<'JSON'
{"jsonrpc":"2.0","id":"init","method":"initialize","params":{}}
{"jsonrpc":"2.0","method":"notifications/initialized"}
{"jsonrpc":"2.0","id":"list","method":"prompts/list","params":{"limit":50}}
JSON

MCPBASH_ALLOW_PROJECT_HOOKS=true test_run_mcp "${WORKSPACE}" "${REQUESTS}" "${RESPONSES}"
assert_json_lines "${RESPONSES}"

err_code="$(jq -r 'select(.id=="list") | .error.code // empty' "${RESPONSES}")"
if [ "${err_code}" != "-32603" ]; then
	test_fail "expected prompts/list to fail with -32603 when register.json is invalid; got ${err_code:-empty}"
fi

if [ -f "${WORKSPACE}/hook_ran.txt" ]; then
	test_fail "expected register.sh not to execute when register.json exists (even invalid)"
fi

printf 'register.json integration tests passed.\n'
