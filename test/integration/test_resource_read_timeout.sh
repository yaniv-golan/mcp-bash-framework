#!/usr/bin/env bash
# shellcheck disable=SC2034  # Used by test runner for reporting.
TEST_DESC="resources/read has a default timeout and answers with an error when it fires."
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
rm -f "${WS}/providers/"*.sh "${WS}/server.d/register.sh"
rm -rf "${WS}/resources"
mkdir -p "${WS}/resources" "${WS}/providers"
# $1: seconds the provider sleeps before answering.
set_provider_delay() {
	chmod u+w "${WS}/providers"
	printf '#!/usr/bin/env bash\nsleep %s\nprintf late\n' "$1" >"${WS}/providers/slow.sh"
	chmod 755 "${WS}/providers/slow.sh"
	chmod go-w "${WS}/providers"
}
set_provider_delay 1
printf 'x\n' >"${WS}/resources/s.txt"
printf '%s\n' '{"name": "s", "uri": "slow://one", "provider": "slow"}' >"${WS}/resources/s.meta.json"
chmod -R go-w "${WS}"

cat >"${WS}/requests.ndjson" <<'JSON'
{"jsonrpc":"2.0","id":"init","method":"initialize","params":{}}
{"jsonrpc":"2.0","method":"notifications/initialized"}
{"jsonrpc":"2.0","id":"read","method":"resources/read","params":{"uri":"slow://one"}}
JSON

# 1) The default timeout fires: the client gets an error, not silence.
start="${SECONDS}"
set_provider_delay 6131
MCPBASH_DEFAULT_RESOURCE_TIMEOUT=2 test_run_mcp "${WS}" "${WS}/requests.ndjson" "${WS}/r1.ndjson"
elapsed=$((SECONDS - start))
got="$(jq -c 'select(.id=="read") | .error // .result' "${WS}/r1.ndjson")"
case "${got}" in
*'"code":-32603'*'timed out after 2s'*) ;;
*) test_fail "timed-out read answered with: '${got}'" ;;
esac
[ "${elapsed}" -lt 30 ] || test_fail "timed-out read took ${elapsed}s"
if pgrep -f "sleep 6131\$" >/dev/null 2>&1; then
	pkill -f "sleep 6131\$" 2>/dev/null || true
	test_fail "the timed-out provider is still running"
fi
printf ' -> timeout: error after %ss, provider stopped\n' "${elapsed}"

# 2) 0 disables the default timeout.
set_provider_delay 3
MCPBASH_DEFAULT_RESOURCE_TIMEOUT=0 test_run_mcp "${WS}" "${WS}/requests.ndjson" "${WS}/r2.ndjson"
text="$(jq -r 'select(.id=="read") | .result.contents[0].text // "ERROR: \(.error)"' "${WS}/r2.ndjson")"
[ "${text}" = "late" ] || test_fail "read with the timeout disabled returned '${text}'"
printf ' -> MCPBASH_DEFAULT_RESOURCE_TIMEOUT=0: read finished\n'

printf 'resource read timeout test passed.\n'
