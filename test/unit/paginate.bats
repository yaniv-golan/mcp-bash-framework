#!/usr/bin/env bash
# Spec §18.2 (Unit layer): verify pagination cursor helpers.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

# shellcheck source=test/common/assert.sh
# shellcheck disable=SC1091
. "${REPO_ROOT}/test/common/assert.sh"
. "${REPO_ROOT}/test/common/env.sh"

# Provide JSON tooling expected by paginate helpers without full runtime init.
MCPBASH_JSON_TOOL="jq"
MCPBASH_JSON_TOOL_BIN="$(command -v jq)"

# shellcheck source=lib/paginate.sh
# shellcheck disable=SC1091
. "${REPO_ROOT}/lib/paginate.sh"

printf ' -> encode/decode roundtrip\n'
cursor="$(mcp_paginate_encode "tools" 10 "hash-value" "2025-01-01T00:00:00Z")"
if [ -z "${cursor}" ]; then
	test_fail "cursor should not be empty"
fi

decoded="$(mcp_paginate_decode "${cursor}" "tools" "hash-value")"
assert_eq "10" "${decoded}" "decoded offset mismatch"

printf ' -> hash mismatch detection\n'
if mcp_paginate_decode "${cursor}" "tools" "other-hash" >/dev/null 2>&1; then
	test_fail "expected hash mismatch to fail"
fi

printf ' -> invalid cursor rejection\n'
if mcp_paginate_decode "not-base64" "tools" "hash-value" >/dev/null 2>&1; then
	test_fail "expected invalid cursor to fail"
fi

printf ' -> nextCursor present when more pages remain\n'
payload='{"items":[1,2,3],"total":3}'
page="$(mcp_paginate_attach_next_cursor "${payload}" "tools" 0 2 3 "hash-value")"
cursor="$(printf '%s' "${page}" | jq -r '.nextCursor // empty')"
[ -z "${cursor}" ] && test_fail "expected nextCursor on non-terminal page"

printf ' -> nextCursor null on terminal page\n'
terminal="$(mcp_paginate_attach_next_cursor "${payload}" "tools" 2 2 3 "hash-value")"
terminal_cursor="$(printf '%s' "${terminal}" | jq -r '.nextCursor')"
assert_eq "null" "${terminal_cursor}" "nextCursor should be null on last page"

printf 'Pagination tests passed.\n'
