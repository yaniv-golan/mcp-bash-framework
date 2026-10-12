#!/usr/bin/env bash
# shellcheck disable=SC2034  # Used by test runner for reporting.
TEST_DESC="file:// reads stop at MCPBASH_MAX_RESOURCE_BYTES instead of copying the whole file first."
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

WS="${TEST_TMPDIR}/ws"
test_stage_workspace "${WS}"
rm -f "${WS}/server.d/register.sh"
rm -rf "${WS}/resources"
mkdir -p "${WS}/resources"
printf '0123456789' >"${WS}/resources/ten.txt"
printf '01234' >"${WS}/resources/five.txt"
chmod -R go-w "${WS}"

cat >"${WS}/requests.ndjson" <<JSON
{"jsonrpc":"2.0","id":"init","method":"initialize","params":{}}
{"jsonrpc":"2.0","method":"notifications/initialized"}
{"jsonrpc":"2.0","id":"ten","method":"resources/read","params":{"uri":"file://${WS}/resources/ten.txt"}}
{"jsonrpc":"2.0","id":"five","method":"resources/read","params":{"uri":"file://${WS}/resources/five.txt"}}
JSON

MCPBASH_MAX_RESOURCE_BYTES=5 test_run_mcp "${WS}" "${WS}/requests.ndjson" "${WS}/r.ndjson"

# The provider itself refuses: the file is never read past the limit.
got="$(jq -c 'select(.id=="ten") | .error // .result' "${WS}/r.ndjson")"
case "${got}" in
*'file exceeds 5 bytes'*) ;;
*) test_fail "10-byte file with a 5-byte limit answered with: '${got}'" ;;
esac
text="$(jq -r 'select(.id=="five") | .result.contents[0].text // "ERROR: \(.error)"' "${WS}/r.ndjson")"
[ "${text}" = "01234" ] || test_fail "5-byte file with a 5-byte limit returned '${text}'"

printf 'file resource size limit test passed.\n'
