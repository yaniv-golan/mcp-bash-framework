#!/usr/bin/env bash
# shellcheck disable=SC2034  # Used by test runner for reporting.
TEST_DESC="Per-prompt completion scripts: contract, env and default timeout."
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
mkdir -p "${WS}/prompts/pick" "${WS}/prompts/hang" "${WS}/server.d"
printf '%s\n' '{"name": "prompt-completion"}' >"${WS}/server.d/server.meta.json"

# prompts/<name>/<name>.meta.json + .txt + .completion.sh (scaffold layout)
cat >"${WS}/prompts/pick/pick.meta.json" <<'JSON'
{"name": "pick", "description": "Pick a list", "path": "pick/pick.txt",
 "arguments": {"type": "object", "properties": {"listName": {"type": "string"}}}}
JSON
printf 'Review {{listName}}\n' >"${WS}/prompts/pick/pick.txt"
cat >"${WS}/prompts/pick/pick.completion.sh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
query="$(printf '%s' "${MCP_COMPLETION_ARGS_JSON}" | "${MCPBASH_JSON_TOOL_BIN}" -r '.query // .prefix // ""')"
printf '["%s:%s","rel=%s","cwd=%s","limit=%s"]' "${MCP_COMPLETION_NAME}" "${query}" "${MCP_PROMPT_REL_PATH}" "$(basename "$(pwd)")" "${MCP_COMPLETION_LIMIT}"
SH

cat >"${WS}/prompts/hang/hang.meta.json" <<'JSON'
{"name": "hang", "description": "Never answers", "path": "hang/hang.txt"}
JSON
printf 'x\n' >"${WS}/prompts/hang/hang.txt"
cat >"${WS}/prompts/hang/hang.completion.sh" <<'SH'
#!/usr/bin/env bash
sleep 60
printf '["too-late"]'
SH
chmod +x "${WS}/prompts/pick/pick.completion.sh" "${WS}/prompts/hang/hang.completion.sh"
chmod -R go-w "${WS}"

cat >"${WS}/requests.ndjson" <<'JSON'
{"jsonrpc":"2.0","id":"init","method":"initialize","params":{}}
{"jsonrpc":"2.0","method":"notifications/initialized"}
{"jsonrpc":"2.0","id":"pick","method":"completion/complete","params":{"ref":{"type":"ref/prompt","name":"pick"},"argument":{"name":"listName","value":"dea"},"limit":10}}
{"jsonrpc":"2.0","id":"hang","method":"completion/complete","params":{"ref":{"type":"ref/prompt","name":"hang"},"argument":{"name":"q","value":""}}}
JSON

start=$(date +%s)
MCPBASH_COMPLETION_TIMEOUT_SECS=2 test_run_mcp "${WS}" "${WS}/requests.ndjson" "${WS}/responses.ndjson" || true
elapsed=$(($(date +%s) - start))

values="$(jq -c 'select(.id=="pick") | .result.completion.values' "${WS}/responses.ndjson")"
assert_eq '["pick:dea","rel=pick/pick.txt","cwd=ws","limit=10"]' "${values}" "per-prompt completion script contract"

hang_err="$(jq -r 'select(.id=="hang") | has("error")' "${WS}/responses.ndjson")"
assert_eq "true" "${hang_err}" "a hung completion script must fail, not answer"
if [ "${elapsed}" -ge 30 ]; then
	test_fail "hung completion script was not timed out (took ${elapsed}s)"
fi

printf 'Per-prompt completion script integration test passed (%ss).\n' "${elapsed}"
