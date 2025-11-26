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

printf 'Pagination tests passed.\n'
