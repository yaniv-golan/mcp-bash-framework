#!/usr/bin/env bats
# Unit layer: a modern (2026-07-28) request's fallback roots don't touch the
# legacy session's roots.debug file.

load '../../node_modules/bats-support/load'
load '../../node_modules/bats-assert/load'
load '../common/fixtures'

setup() {
	. "${MCPBASH_HOME}/lib/roots.sh"
	export MCPBASH_STATE_DIR="${BATS_TEST_TMPDIR}/state"
	mkdir -p "${MCPBASH_STATE_DIR}"
	export MCPBASH_PROJECT_ROOT="${BATS_TEST_TMPDIR}"
	printf 'legacy\n' >"${MCPBASH_STATE_DIR}/roots.debug"
}

@test "roots: a modern request leaves the legacy roots.debug alone" {
	MCPBASH_PROTOCOL_ERA=modern mcp_roots_load_all_fallbacks >/dev/null 2>&1 || true
	assert_equal "legacy" "$(cat "${MCPBASH_STATE_DIR}/roots.debug")"
}

@test "roots: a legacy load still writes roots.debug" {
	mcp_roots_load_all_fallbacks >/dev/null 2>&1 || true
	[ "$(cat "${MCPBASH_STATE_DIR}/roots.debug")" != "legacy" ]
}
