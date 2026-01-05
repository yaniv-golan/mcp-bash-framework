#!/usr/bin/env bats
# Spec §18.2 (Unit layer): verify pagination cursor helpers.

load '../../node_modules/bats-support/load'
load '../../node_modules/bats-assert/load'
load '../common/fixtures'

setup() {
	# Provide JSON tooling expected by paginate helpers without full runtime init.
	MCPBASH_JSON_TOOL="jq"
	MCPBASH_JSON_TOOL_BIN="$(command -v jq)"

	# shellcheck source=lib/paginate.sh
	# shellcheck disable=SC1091
	. "${MCPBASH_HOME}/lib/paginate.sh"
}

@test "paginate: encode/decode roundtrip" {
	cursor="$(mcp_paginate_encode "tools" 10 "hash-value" "2025-01-01T00:00:00Z")"
	[ -n "${cursor}" ]

	decoded="$(mcp_paginate_decode "${cursor}" "tools" "hash-value")"
	assert_equal "10" "${decoded}"
}

@test "paginate: hash mismatch detection" {
	cursor="$(mcp_paginate_encode "tools" 10 "hash-value" "2025-01-01T00:00:00Z")"

	run mcp_paginate_decode "${cursor}" "tools" "other-hash"
	assert_failure
}

@test "paginate: invalid cursor rejection" {
	run mcp_paginate_decode "not-base64" "tools" "hash-value"
	assert_failure
}

@test "paginate: nextCursor present when more pages remain" {
	payload='{"items":[1,2,3],"total":3}'
	page="$(mcp_paginate_attach_next_cursor "${payload}" "tools" 0 2 3 "hash-value")"

	cursor="$(printf '%s' "${page}" | jq -r '.nextCursor // empty')"
	[ -n "${cursor}" ]
}

@test "paginate: nextCursor null on terminal page" {
	payload='{"items":[1,2,3],"total":3}'
	terminal="$(mcp_paginate_attach_next_cursor "${payload}" "tools" 2 2 3 "hash-value")"

	terminal_cursor="$(printf '%s' "${terminal}" | jq -r '.nextCursor')"
	assert_equal "null" "${terminal_cursor}"
}
