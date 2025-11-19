#!/usr/bin/env bash
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

cat <<'JSON' >"${TMP}/requests.ndjson"
{"jsonrpc":"2.0","id":"1","method":"initialize","params":{}}
{"jsonrpc":"2.0","method":"notifications/initialized"}
{"jsonrpc":"2.0","id":"2","method":"completion/complete","params":{"name":"example","arguments":{"query":"plan roadmap"},"limit":1}}
JSON

"${MCPBASH_ROOT}/examples/run" 00-hello-tool <"${TMP}/requests.ndjson" >"${TMP}/responses.ndjson" || true

if ! grep -q '"id":"2"' "${TMP}/responses.ndjson"; then
	test_fail "completion/complete response missing"
fi

resp_json="$(grep '"id":"2"' "${TMP}/responses.ndjson" | head -n1)"
suggestions_len="$(echo "$resp_json" | jq '.result.suggestions | length')"
suggestion_type="$(echo "$resp_json" | jq -r '.result.suggestions[0].type')"
suggestion_text="$(echo "$resp_json" | jq -r '.result.suggestions[0].text')"
has_more="$(echo "$resp_json" | jq '.result.hasMore')"

test_assert_eq "$suggestions_len" "1"
test_assert_eq "$suggestion_type" "text"
if [[ "$suggestion_text" != *"plan roadmap"* ]]; then
	test_fail "suggestion text mismatch: $suggestion_text"
fi
test_assert_eq "$has_more" "true"
