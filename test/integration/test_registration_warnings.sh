#!/usr/bin/env bash
# shellcheck disable=SC2034  # Used by test runner for reporting.
TEST_DESC="Registration warnings reach the client and never corrupt registry data."
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
WS="${TEST_TMPDIR}/warnings"
test_stage_workspace "${WS}"
# The staged workspace carries copies of the built-in providers; as project
# providers they would make any template provider valid.
rm -f "${WS}/providers/"*.sh
rm -rf "${WS}/resources"
mkdir -p "${WS}/resources" "${WS}/providers"

cat <<'SH' >"${WS}/providers/svc.sh"
#!/usr/bin/env bash
printf 'svc %s' "$1"
SH
chmod +x "${WS}/providers/svc.sh"
# A template whose provider is refused (a built-in on a foreign scheme), and a
# static resource whose custom scheme has no provider script: both log a
# warning while the registries are built.
printf '%s\n' '{"name": "svc-bad", "uriTemplate": "svc://bad/{id}", "provider": "ui"}' >"${WS}/resources/svc-bad.meta.json"
printf 'x\n' >"${WS}/resources/svc-one.txt"
printf '%s\n' '{"name": "svc-one", "uri": "svc://one", "provider": "svc"}' >"${WS}/resources/svc-one.meta.json"
printf 'x\n' >"${WS}/resources/orphan.txt"
printf '%s\n' '{"name": "orphan", "uri": "noscript://orphan"}' >"${WS}/resources/orphan.meta.json"
chmod -R go-w "${WS}"

cat <<'JSON' >"${WS}/requests.ndjson"
{"jsonrpc":"2.0","id":"init","method":"initialize","params":{}}
{"jsonrpc":"2.0","method":"notifications/initialized"}
{"jsonrpc":"2.0","id":"templates","method":"resources/templates/list","params":{}}
{"jsonrpc":"2.0","id":"read","method":"resources/read","params":{"uri":"svc://bad/4"}}
{"jsonrpc":"2.0","id":"list","method":"resources/list","params":{}}
JSON

RESP="${WS}/responses.ndjson"
test_run_mcp "${WS}" "${WS}/requests.ndjson" "${RESP}"
assert_json_lines "${RESP}"

failures=0
fail() {
	printf 'FAIL: %s\n' "$1" >&2
	failures=$((failures + 1))
}

# A warning written into a $(...) capture corrupts the data it was building.
if grep -E 'jq: error|invalid JSON text|integer expression expected|parse error' "${RESP}.stderr" >/dev/null 2>&1; then
	fail "server stderr shows corrupted registry data:"
	sed 's/^/    /' "${RESP}.stderr" >&2
fi

total="$(jq -r 'select(.id=="templates") | .result._meta["mcpbash/total"] | tostring' "${RESP}")"
case "${total}" in
1) ;;
*) fail "templates/list total is '${total}', expected 1" ;;
esac
names="$(jq -c 'select(.id=="list") | [.result.resources[].name] | sort' "${RESP}")"
[ "${names}" = '["orphan","svc-one"]' ] || fail "resources/list names are ${names}"
text="$(jq -r 'select(.id=="read") | .result.contents[0].text // .error.message' "${RESP}")"
[ "${text}" = "svc svc://bad/4" ] || fail "svc-bad read returned '${text}'"

# Both warnings reach the client as notifications/message.
warnings="$(jq -r 'select(.method=="notifications/message" and .params.level=="warning") | .params.data' "${RESP}")"
case "${warnings}" in
*"svc-bad: provider 'ui'"*) ;;
*) fail "no warning for svc-bad; warnings were: ${warnings}" ;;
esac
case "${warnings}" in
*"noscript"*) ;;
*) fail "no warning for the noscript:// resource; warnings were: ${warnings}" ;;
esac

# register.json: a custom-scheme resource without a provider or script takes
# the manual registration path, which logs the same warning while building
# the registry JSON.
WS2="${TEST_TMPDIR}/warnings-json"
test_stage_workspace "${WS2}"
rm -f "${WS2}/providers/"*.sh
rm -rf "${WS2}/resources"
mkdir -p "${WS2}/resources"
cat <<'JSON' >"${WS2}/server.d/register.json"
{
  "version": 1,
  "resources": [
    {"name": "nosuch", "uri": "nosuch://x"},
    {"name": "plain", "uri": "file:///tmp/plain.txt", "provider": "file"}
  ]
}
JSON
chmod -R go-w "${WS2}"
cat <<'JSON' >"${WS2}/requests.ndjson"
{"jsonrpc":"2.0","id":"init","method":"initialize","params":{}}
{"jsonrpc":"2.0","method":"notifications/initialized"}
{"jsonrpc":"2.0","id":"list","method":"resources/list","params":{}}
JSON
RESP2="${WS2}/responses.ndjson"
test_run_mcp "${WS2}" "${WS2}/requests.ndjson" "${RESP2}"
assert_json_lines "${RESP2}"
if grep -E 'jq: error|invalid JSON text|integer expression expected|parse error' "${RESP2}.stderr" >/dev/null 2>&1; then
	fail "register.json: server stderr shows corrupted registry data:"
	sed 's/^/    /' "${RESP2}.stderr" >&2
fi
names2="$(jq -c 'select(.id=="list") | [.result.resources[].name] | sort' "${RESP2}")"
[ "${names2}" = '["nosuch","plain"]' ] || fail "register.json: resources/list names are ${names2}"
warnings2="$(jq -r 'select(.method=="notifications/message" and .params.level=="warning") | .params.data' "${RESP2}")"
case "${warnings2}" in
*"nosuch"*) ;;
*) fail "register.json: no warning for nosuch://; warnings were: ${warnings2}" ;;
esac

if [ "${failures}" -gt 0 ]; then
	test_fail "${failures} registration-warning check(s) failed"
fi
printf ' -> warnings delivered, registries intact\n'
