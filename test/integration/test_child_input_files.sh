#!/usr/bin/env bash
# shellcheck disable=SC2034  # Used by test runner for reporting.
TEST_DESC="Input files for completion scripts and providers are 0600 and removed however the request ends."
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
unset MCPBASH_KEEP_LOGS MCPBASH_PRESERVE_STATE MCPBASH_LOG_DIR

WS="${TEST_TMPDIR}/ws"
test_stage_workspace "${WS}"
mkdir -p "${WS}/prompts/hang" "${WS}/prompts/quick" "${WS}/providers" "${WS}/resources" "${WS}/server.d"
printf '%s\n' '{"name": "input-files"}' >"${WS}/server.d/server.meta.json"

# Each child records the paths and modes of its input files, then (hang) waits
# to be stopped: by a cancel, or by the request's timeoutSecs.
SEEN="${WS}/seen"
: >"${SEEN}"
cat >"${WS}/record.sh" <<'SH'
for f in "$@"; do
	[ -n "${f}" ] || continue
	mode="$(stat -c '%a' "${f}" 2>/dev/null || stat -f '%Lp' "${f}")"
	printf '%s %s\n' "${mode}" "${f}" >>"${MCPBASH_PROJECT_ROOT}/seen"
done
SH
for p in hang quick; do
	printf '{"name": "%s", "description": "d", "path": "%s/%s.txt",\n "arguments": {"type": "object", "properties": {"q": {"type": "string"}}}}\n' "${p}" "${p}" "${p}" >"${WS}/prompts/${p}/${p}.meta.json"
	printf 'x {{q}}\n' >"${WS}/prompts/${p}/${p}.txt"
done
cat >"${WS}/prompts/hang/hang.completion.sh" <<'SH'
#!/usr/bin/env bash
. "${MCPBASH_PROJECT_ROOT}/record.sh" "${MCP_COMPLETION_ARGS_FILE}" "${MCP_PROMPT_METADATA_FILE}"
sleep 60
printf '["too-late"]'
SH
cat >"${WS}/prompts/quick/quick.completion.sh" <<'SH'
#!/usr/bin/env bash
. "${MCPBASH_PROJECT_ROOT}/record.sh" "${MCP_COMPLETION_ARGS_FILE}" "${MCP_PROMPT_METADATA_FILE}"
sleep 3
printf '["done"]'
SH
# A template read whose provider hangs, and one that answers.
cat >"${WS}/providers/kv.sh" <<'SH'
#!/usr/bin/env bash
. "${MCPBASH_PROJECT_ROOT}/record.sh" "${MCP_RESOURCE_TEMPLATE_VARS_FILE}"
case "$1" in
kv://hang/*) sleep 60 ;;
esac
cat "${MCP_RESOURCE_TEMPLATE_VARS_FILE}"
SH
printf '%s\n' '{"name": "kv-item", "uriTemplate": "kv://{kind}/{id}"}' >"${WS}/resources/kv-item.meta.json"
chmod +x "${WS}/prompts/hang/hang.completion.sh" "${WS}/prompts/quick/quick.completion.sh" "${WS}/providers/kv.sh"
chmod -R go-w "${WS}"

cat >"${WS}/requests.ndjson" <<'JSON'
{"jsonrpc":"2.0","id":"init","method":"initialize","params":{}}
{"jsonrpc":"2.0","method":"notifications/initialized"}
{"jsonrpc":"2.0","id":"cancelled","method":"completion/complete","params":{"ref":{"type":"ref/prompt","name":"hang"},"argument":{"name":"q","value":"a"}}}
{"jsonrpc":"2.0","id":"timed-out","method":"completion/complete","params":{"ref":{"type":"ref/prompt","name":"hang"},"argument":{"name":"q","value":"b"},"timeoutSecs":2}}
{"jsonrpc":"2.0","id":"read-timed-out","method":"resources/read","params":{"uri":"kv://hang/1","timeoutSecs":2}}
{"jsonrpc":"2.0","id":"read","method":"resources/read","params":{"uri":"kv://item/7"}}
{"jsonrpc":"2.0","id":"quick","method":"completion/complete","params":{"ref":{"type":"ref/prompt","name":"quick"},"argument":{"name":"q","value":"c"}}}
JSON
# The cancel goes after the server has started the script.
{
	head -n 3 "${WS}/requests.ndjson"
	printf '%s\n' '{"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":"cancelled"}}'
	tail -n +4 "${WS}/requests.ndjson"
} >"${WS}/requests-cancel.ndjson"

# A state dir the server didn't create is never removed, so leftovers show;
# a private temp root shows files left outside it.
STATE="${TEST_TMPDIR}/state"
TMPROOT="${TEST_TMPDIR}/tmproot"
mkdir -p "${STATE}" "${TMPROOT}"
chmod 700 "${STATE}" "${TMPROOT}"
MCPBASH_STATE_DIR="${STATE}" MCPBASH_TMP_ROOT="${TMPROOT}" MCPBASH_COMPLETION_TIMEOUT_SECS=0 \
	test_run_mcp "${WS}" "${WS}/requests-cancel.ndjson" "${WS}/responses.ndjson" || true

assert_eq '7' "$(jq -r 'select(.id=="read") | (.result.contents[0].text | fromjson | .id) // .error.message' "${WS}/responses.ndjson")" "template read"
assert_eq '["done"]' "$(jq -c 'select(.id=="quick") | .result.completion.values' "${WS}/responses.ndjson")" "quick completion"

# Every child saw its files, and only you could read them. (The cancel can
# reach the server before the cancelled script starts: 6 or 8 files.)
seen_count="$(awk '{print $2}' "${SEEN}" | sort -u | wc -l | tr -d ' ')"
[ "${seen_count}" -ge 6 ] || test_fail "expected at least 6 input files, saw ${seen_count}"
bad_modes="$(awk '$1 != "600"' "${SEEN}")"
[ -z "${bad_modes}" ] || test_fail "input files not 0600: ${bad_modes}"

# None is left, whether the child finished, was cancelled or timed out.
while read -r _ seen; do
	[ ! -e "${seen}" ] || test_fail "input file left behind: ${seen}"
done <"${SEEN}"
left="$(find "${STATE}" "${TMPROOT}" -name 'inputs.*' -o -name 'mcp-completion.args.*' -o -name 'mcp-completion.meta.*' -o -name 'mcp-resource-vars.*' 2>/dev/null)"
[ -z "${left}" ] || test_fail "input files left behind: ${left}"

printf 'Child input file test passed.\n'
