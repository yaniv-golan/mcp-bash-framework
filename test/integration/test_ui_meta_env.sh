#!/usr/bin/env bash
# shellcheck disable=SC2034  # Used by test runner for reporting.
TEST_DESC="A UI provider receives an allowlisted secret from server.meta.json env, and only then."
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
unset MCPBASH_TOOL_ENV_MODE MCPBASH_TOOL_ENV_ALLOWLIST MCPBASH_PROVIDER_ENV_MODE MCPBASH_PROVIDER_ENV_ALLOWLIST

# Providers resolve project-first, so a project providers/ui.sh stands in for
# the framework's UI provider and reports what its curated env contained.
stage_project() {
	local ws="$1"
	test_stage_workspace "${ws}"
	mkdir -p "${ws}/providers" "${ws}/ui/dashboard" "${ws}/server.d"
	printf '%s\n' '<html><body>dashboard</body></html>' >"${ws}/ui/dashboard/index.html"
	cat >"${ws}/providers/ui.sh" <<'SH'
#!/usr/bin/env bash
printf '<html><body>secret=%s</body></html>' "${SECRET_X:-absent}"
SH
	chmod +x "${ws}/providers/ui.sh"
	chmod -R go-w "${ws}"
}

write_requests() {
	cat >"$1" <<'JSON'
{"jsonrpc":"2.0","id":"init","method":"initialize","params":{"capabilities":{"extensions":{"io.modelcontextprotocol/ui":{}}}}}
{"jsonrpc":"2.0","method":"notifications/initialized"}
{"jsonrpc":"2.0","id":"read","method":"resources/read","params":{"uri":"ui://mcp-server/dashboard"}}
JSON
}

read_ui() {
	jq -r 'select(.id=="read") | (.result.contents[0].text // .error.message // empty)' "$1"
}

export MCPBASH_SERVER_NAME="mcp-server"

# --- With the env section: the UI provider sees SECRET_X ---
WITH="${TEST_TMPDIR}/with"
stage_project "${WITH}"
cat >"${WITH}/server.d/server.meta.json" <<'JSON'
{"name": "ui-meta-env", "env": {"MCPBASH_PROVIDER_ENV_MODE": "allowlist", "MCPBASH_PROVIDER_ENV_ALLOWLIST": "SECRET_X"}}
JSON
chmod go-w "${WITH}/server.d/server.meta.json"
write_requests "${WITH}/requests.ndjson"
test_run_mcp "${WITH}" "${WITH}/requests.ndjson" "${WITH}/responses.ndjson" || true
assert_contains "secret=from-host" "$(read_ui "${WITH}/responses.ndjson")" "UI provider should receive the allowlisted SECRET_X"

# --- Without it: the UI provider runs isolated and never sees SECRET_X ---
WITHOUT="${TEST_TMPDIR}/without"
stage_project "${WITHOUT}"
printf '%s\n' '{"name": "ui-meta-env"}' >"${WITHOUT}/server.d/server.meta.json"
chmod go-w "${WITHOUT}/server.d/server.meta.json"
write_requests "${WITHOUT}/requests.ndjson"
test_run_mcp "${WITHOUT}" "${WITHOUT}/requests.ndjson" "${WITHOUT}/responses.ndjson" || true
assert_contains "secret=absent" "$(read_ui "${WITHOUT}/responses.ndjson")" "UI provider must not receive SECRET_X without a policy"
if grep -q "from-host" "${WITHOUT}/responses.ndjson"; then
	test_fail "SECRET_X leaked to the UI provider without a policy"
fi

printf 'UI provider env policy integration test passed.\n'
