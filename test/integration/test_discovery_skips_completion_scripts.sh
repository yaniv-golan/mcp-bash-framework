#!/usr/bin/env bash
# shellcheck disable=SC2034  # Used by test runner for reporting.
TEST_DESC="Prompt/resource discovery skips per-prompt/per-resource completion scripts."
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
mkdir -p "${WS}/prompts/pick" "${WS}/resources" "${WS}/server.d"
printf '%s\n' '{"name": "discovery-skip"}' >"${WS}/server.d/server.meta.json"

# A prompt with a per-prompt completion script beside it (scaffold layout).
printf '%s\n' '{"name": "pick", "description": "Pick", "path": "pick/pick.txt"}' >"${WS}/prompts/pick/pick.meta.json"
printf 'Pick {{x}}\n' >"${WS}/prompts/pick/pick.txt"
printf '#!/usr/bin/env bash\nprintf %s\n' "'[\"a\"]'" >"${WS}/prompts/pick/pick.completion.sh"
printf '#!/usr/bin/env bash\nprintf %s\n' "'[\"b\"]'" >"${WS}/prompts/pick/pick.txt.completion"

# A resource with a per-resource completion script beside it.
printf 'hello\n' >"${WS}/resources/notes.txt"
printf '%s\n' '{"name": "notes", "description": "Notes"}' >"${WS}/resources/notes.meta.json"
printf '#!/usr/bin/env bash\nprintf %s\n' "'[\"note-1\"]'" >"${WS}/resources/notes.completion.sh"
chmod +x "${WS}/prompts/pick/pick.completion.sh" "${WS}/prompts/pick/pick.txt.completion" "${WS}/resources/notes.completion.sh"
chmod -R go-w "${WS}"

cat >"${WS}/requests.ndjson" <<'JSON'
{"jsonrpc":"2.0","id":"init","method":"initialize","params":{}}
{"jsonrpc":"2.0","method":"notifications/initialized"}
{"jsonrpc":"2.0","id":"prompts","method":"prompts/list","params":{}}
{"jsonrpc":"2.0","id":"resources","method":"resources/list","params":{}}

JSON

test_run_mcp "${WS}" "${WS}/requests.ndjson" "${WS}/responses.ndjson" || true

prompt_names="$(jq -r 'select(.id=="prompts") | [.result.prompts[].name] | sort | join(",")' "${WS}/responses.ndjson")"
assert_eq "pick" "${prompt_names}" "completion scripts must not be listed as prompts"

resource_names="$(jq -r 'select(.id=="resources") | [.result.resources[].name] | sort | join(",")' "${WS}/responses.ndjson")"
assert_eq "notes" "${resource_names}" "completion scripts must not be listed as resources"

# The per-prompt completion script must still serve completions for its prompt.
cat >"${WS}/requests2.ndjson" <<'JSON'
{"jsonrpc":"2.0","id":"init","method":"initialize","params":{}}
{"jsonrpc":"2.0","method":"notifications/initialized"}
{"jsonrpc":"2.0","id":"comp","method":"completion/complete","params":{"ref":{"type":"ref/prompt","name":"pick"},"argument":{"name":"x","value":""}}}
JSON
test_run_mcp "${WS}" "${WS}/requests2.ndjson" "${WS}/responses2.ndjson" || true
comp="$(jq -c 'select(.id=="comp") | .result.completion.values' "${WS}/responses2.ndjson")"
assert_eq '["b"]' "${comp}" "per-prompt completion script still serves its prompt (first candidate: <path>.completion)"

printf 'Discovery skips completion scripts test passed.\n'
