#!/usr/bin/env bash
# shellcheck disable=SC2034  # Used by test runner for reporting.
TEST_DESC="Built-in completion provider and cursor handling."
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../common/env.sh
# shellcheck disable=SC1091
. "${SCRIPT_DIR}/../common/env.sh"
# shellcheck source=../common/assert.sh
# shellcheck disable=SC1091
. "${SCRIPT_DIR}/../common/assert.sh"

TMP=$(mktemp -d)
trap 'rm -rf "${TMP}"' EXIT

# Relies on the builtin completion provider when no project-defined completion exists.
cat <<'JSON' >"${TMP}/requests.ndjson"
{"jsonrpc":"2.0","id":"1","method":"initialize","params":{}}
{"jsonrpc":"2.0","method":"notifications/initialized"}
{"jsonrpc":"2.0","id":"2","method":"completion/complete","params":{"ref":{"type":"ref/prompt","name":"example"},"argument":{"name":"query","value":"plan roadmap"},"limit":1}}
{"jsonrpc":"2.0","id":"badcursor","method":"completion/complete","params":{"ref":{"type":"ref/prompt","name":"example"},"argument":{"name":"query","value":"plan roadmap"},"cursor":"not-a-cursor"}}
JSON

"${MCPBASH_HOME}/examples/run" 00-hello-tool <"${TMP}/requests.ndjson" >"${TMP}/responses.ndjson" || true

init_caps="$(grep '"id":"1"' "${TMP}/responses.ndjson" | head -n1)"
if ! echo "${init_caps}" | jq -e '.result.capabilities.completions? | . == {}' >/dev/null; then
	test_fail "initialize response missing completions capability"
fi

if ! grep -q '"id":"2"' "${TMP}/responses.ndjson"; then
	test_fail "completion/complete response missing"
fi

resp_json="$(grep '"id":"2"' "${TMP}/responses.ndjson" | head -n1)"
suggestions_len="$(echo "$resp_json" | jq '.result.completion.values | length')"
suggestion_text="$(echo "$resp_json" | jq -r '.result.completion.values[0]')"
has_more="$(echo "$resp_json" | jq '.result.completion.hasMore')"
cursor="$(echo "$resp_json" | jq -r '.result.completion.nextCursor // empty')"

test_assert_eq "$suggestions_len" "1"
if [[ "$suggestion_text" != *"plan roadmap"* ]]; then
	test_fail "suggestion text mismatch: $suggestion_text"
fi
test_assert_eq "$has_more" "true"
if [ -z "${cursor}" ] || [ "${cursor}" = "null" ]; then
	test_fail "expected cursor for pagination when hasMore=true"
fi

bad_cursor_code="$(jq -r 'select(.id=="badcursor") | .error.code // empty' "${TMP}/responses.ndjson")"
test_assert_eq "${bad_cursor_code}" "-32602"

# Second page using returned cursor should yield the next suggestion.
cat >"${TMP}/requests_page2.ndjson" <<JSON
{"jsonrpc":"2.0","id":"init","method":"initialize","params":{}}
{"jsonrpc":"2.0","method":"notifications/initialized"}
{"jsonrpc":"2.0","id":"page2","method":"completion/complete","params":{"ref":{"type":"ref/prompt","name":"example"},"argument":{"name":"query","value":"plan roadmap"},"cursor":"${cursor}","limit":1}}
JSON

"${MCPBASH_HOME}/examples/run" 00-hello-tool <"${TMP}/requests_page2.ndjson" >"${TMP}/responses_page2.ndjson" || true

page2_json="$(grep '"id":"page2"' "${TMP}/responses_page2.ndjson" | head -n1)"
if [ -z "${page2_json}" ]; then
	test_fail "missing page2 completion response"
fi
page2_text="$(echo "${page2_json}" | jq -r '.result.completion.values[0] // empty')"
page2_has_more="$(echo "${page2_json}" | jq -r '.result.completion.hasMore // false')"
if [[ "${page2_text}" != *"snippet"* ]]; then
	test_fail "second page suggestion unexpected: ${page2_text}"
fi
if [ "${page2_has_more}" != "true" ]; then
	test_fail "expected hasMore on second page to remain true for final item"
fi
