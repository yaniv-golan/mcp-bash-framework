#!/usr/bin/env bash
# Integration: clients that probe with server/discover before initialize.
# shellcheck disable=SC2034  # Used by test runner for reporting.
TEST_DESC="server/discover and unknown methods before initialize get one -32601 each, then initialize works."

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
WORKSPACE="${TEST_TMPDIR}/probe"
test_stage_workspace "${WORKSPACE}"
mkdir -p "${WORKSPACE}/tools/hello"
cp "${MCPBASH_HOME}/examples/00-hello-tool/tools/hello/"* "${WORKSPACE}/tools/hello/"

# Newer clients send server/discover (protocol 2026-07-28) before initialize and
# fall back to initialize on an error. The error must echo the id, arrive once,
# and leave the process ready for initialize.
cat <<'JSON' >"${WORKSPACE}/requests.ndjson"
{"jsonrpc":"2.0","id":"discover","method":"server/discover","params":{"protocolVersion":"2026-07-28"}}
{"jsonrpc":"2.0","id":7,"method":"some/unknownMethod"}
{"jsonrpc":"2.0","id":"early-list","method":"tools/list"}
{"jsonrpc":"2.0","id":"init","method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"probe-test","version":"0"}}}
{"jsonrpc":"2.0","method":"notifications/initialized"}
{"jsonrpc":"2.0","id":"list","method":"tools/list"}
{"jsonrpc":"2.0","id":"call","method":"tools/call","params":{"name":"example-hello","arguments":{}}}
JSON

MCPBASH_TOOL_ALLOWLIST="*" test_run_mcp "${WORKSPACE}" "${WORKSPACE}/requests.ndjson" "${WORKSPACE}/responses.ndjson"
resp="${WORKSPACE}/responses.ndjson"
assert_json_lines "${resp}"

count_id() { jq -s --argjson id "$1" '[.[] | select(.id == $id)] | length' "${resp}"; }
test_assert_eq "$(count_id '"discover"')" "1"
test_assert_eq "$(count_id '7')" "1"
test_assert_eq "$(jq -r 'select(.id == "discover") | .error.code' "${resp}")" "-32601"
test_assert_eq "$(jq -r 'select(.id == 7) | .error.code' "${resp}")" "-32601"
# A method the server does implement still reports that it needs initialize.
test_assert_eq "$(jq -r 'select(.id == "early-list") | .error.code' "${resp}")" "-32000"

if ! jq -e 'select(.id == "init") | .result.protocolVersion' "${resp}" >/dev/null; then
	test_fail "initialize after the probe failed: $(cat "${resp}")"
fi
if ! jq -e 'select(.id == "list") | .result.tools | map(.name) | index("example-hello")' "${resp}" >/dev/null; then
	test_fail "tools/list after the probe failed: $(grep "\"list\"" "${resp}")"
fi
if ! jq -e 'select(.id == "call") | .result.isError != true' "${resp}" >/dev/null; then
	test_fail "tools/call after the probe failed"
fi

printf 'Pre-initialize probe test passed.\n'
