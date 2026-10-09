#!/usr/bin/env bash
# shellcheck disable=SC2034  # Used by test runner for reporting.
TEST_DESC="Registered completions: default timeout, explicit timeoutSecs, 0 disables, negative ignored."
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
mkdir -p "${WS}/completions" "${WS}/server.d"
printf '%s\n' '{"name": "registered-timeout"}' >"${WS}/server.d/server.meta.json"

make_script() {
	local name="$1" secs="$2"
	cat >"${WS}/completions/${name}.sh" <<SH
#!/usr/bin/env bash
sleep ${secs}
printf '["${name}-ok"]'
SH
	chmod +x "${WS}/completions/${name}.sh"
}
# Default timeout is 5s (set below). Each case sits at least 4s away from the
# limit that decides it, so a loaded machine cannot flip the result: "explicit"
# and "zero" sleep 7s, which only succeeds if their own setting replaces the
# 5s default; "negative" sleeps 1s under that default; "hang" never finishes.
make_script hang 60
make_script explicit 7
make_script zero 7
make_script negative 1

cat >"${WS}/server.d/register.json" <<'JSON'
{"version": 1, "completions": [
  {"name": "hang", "path": "completions/hang.sh"},
  {"name": "explicit", "path": "completions/explicit.sh", "timeoutSecs": 20},
  {"name": "zero", "path": "completions/zero.sh", "timeoutSecs": 0},
  {"name": "negative", "path": "completions/negative.sh", "timeoutSecs": -5}
]}
JSON
chmod -R go-w "${WS}"

req() {
	printf '{"jsonrpc":"2.0","id":"%s","method":"completion/complete","params":{"ref":{"type":"ref/prompt","name":"%s"},"argument":{"name":"q","value":""}}}\n' "$1" "$1"
}
{
	printf '%s\n' '{"jsonrpc":"2.0","id":"init","method":"initialize","params":{}}' '{"jsonrpc":"2.0","method":"notifications/initialized"}'
	req hang
	req explicit
	req zero
	req negative
} >"${WS}/requests.ndjson"

start=$(date +%s)
MCPBASH_COMPLETION_REGISTERED_TIMEOUT_SECS=5 test_run_mcp "${WS}" "${WS}/requests.ndjson" "${WS}/responses.ndjson" || true
elapsed=$(($(date +%s) - start))

val() { jq -c --arg id "$1" 'select(.id==$id) | (.result.completion.values // "ERR")' "${WS}/responses.ndjson"; }

assert_eq "true" "$(jq -r 'select(.id=="hang") | has("error")' "${WS}/responses.ndjson")" "registered completion without timeoutSecs is cut off"
assert_eq '["explicit-ok"]' "$(val explicit)" "explicit timeoutSecs: 20 lets a 7s script outlive the 5s default"
assert_eq '["zero-ok"]' "$(val zero)" "explicit timeoutSecs: 0 lets a 7s script outlive the 5s default"
assert_eq '["negative-ok"]' "$(val negative)" "negative timeoutSecs is ignored (falls back to default)"
if [ "${elapsed}" -ge 45 ]; then
	test_fail "hung registered completion was not timed out (took ${elapsed}s)"
fi

printf 'Registered completion timeout integration test passed (%ss).\n' "${elapsed}"
