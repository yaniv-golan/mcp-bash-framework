#!/usr/bin/env bash
# Integration: getting-started helper activates when MCPBASH_PROJECT_ROOT is unset.
# shellcheck disable=SC2034  # Used by test runner for reporting.
TEST_DESC="Auto getting-started helper when project root is unset."

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../common/env.sh
# shellcheck disable=SC1091
. "${SCRIPT_DIR}/../common/env.sh"
# shellcheck source=../common/assert.sh
# shellcheck disable=SC1091
. "${SCRIPT_DIR}/../common/assert.sh"

test_create_tmpdir

REQUESTS="${TEST_TMPDIR}/requests.ndjson"
RESPONSES="${TEST_TMPDIR}/responses.ndjson"
STDERR_LOG="${TEST_TMPDIR}/stderr.log"

# Dump diagnostic info on failure (stderr/responses are redirected separately)
dump_diagnostics() {
	local exit_code=$?
	if [ "${exit_code}" -ne 0 ]; then
		printf '\n--- mcp-bash stderr ---\n' >&2
		cat "${STDERR_LOG}" 2>/dev/null || printf '(no stderr log)\n' >&2
		printf '--- mcp-bash responses ---\n' >&2
		cat "${RESPONSES}" 2>/dev/null || printf '(no responses)\n' >&2
		printf '--- end diagnostics ---\n' >&2
	fi
	test_cleanup_tmpdir
}
trap dump_diagnostics EXIT

cat <<'JSON' >"${REQUESTS}"
{"jsonrpc":"2.0","id":"bootstrap-init","method":"initialize","params":{}}
{"jsonrpc":"2.0","method":"notifications/initialized"}
{"jsonrpc":"2.0","id":"bootstrap-list","method":"tools/list","params":{}}
{"jsonrpc":"2.0","id":"bootstrap-call","method":"tools/call","params":{"name":"getting_started","arguments":{}}}
JSON

(
	cd "${MCPBASH_TEST_ROOT}" || exit 1
	MCPBASH_PROJECT_ROOT="" MCPBASH_REGISTRY_DIR="" MCPBASH_LOG_JSON_TOOL="quiet" ./bin/mcp-bash <"${REQUESTS}" >"${RESPONSES}" 2>"${STDERR_LOG}"
)

assert_json_lines "${RESPONSES}"

list_resp="$(grep '"id":"bootstrap-list"' "${RESPONSES}" | head -n1)"
tools_count="$(echo "${list_resp}" | jq '.result.tools | length')"
tool_name="$(echo "${list_resp}" | jq -r '.result.tools[0].name // empty')"

assert_eq "1" "${tools_count}" "expected only the getting_started tool in bootstrap mode"
assert_eq "getting_started" "${tool_name}" "expected getting_started tool to be registered"

call_resp="$(grep '"id":"bootstrap-call"' "${RESPONSES}" | head -n1)"
call_text="$(echo "${call_resp}" | jq -r '.result.content[] | select(.type=="text") | .text' | paste -sd ' ' -)"

assert_contains "README.md#quick-start" "${call_text}" "helper output should link to README quick start"
assert_contains "docs/PROJECT-STRUCTURE.md" "${call_text}" "helper output should link to project structure doc"
assert_contains "MCPBASH_PROJECT_ROOT" "${call_text}" "helper output should mention MCPBASH_PROJECT_ROOT"

bootstrap_dir="$(grep -oE '/[^ )]*mcpbash\.bootstrap\.[A-Za-z0-9]+' "${STDERR_LOG}" | tail -n1 || true)"
if [ "${MCPBASH_KEEP_LOGS:-false}" = "true" ]; then
	printf 'Note: KEEP_LOGS enabled; bootstrap workspace may be preserved: %s\n' "${bootstrap_dir:-<none>}"
else
	if [ -n "${bootstrap_dir}" ] && [ -d "${bootstrap_dir}" ]; then
		test_fail "bootstrap workspace not cleaned up: ${bootstrap_dir}"
	fi
fi

printf 'Bootstrap helper test passed.\n'
