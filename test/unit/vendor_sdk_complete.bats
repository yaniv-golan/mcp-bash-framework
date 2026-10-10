#!/usr/bin/env bats
# Unit: a vendored runtime carries the whole SDK, not just tool-sdk.sh.
# tool-sdk.sh loads its siblings (ui-sdk.sh) by path; when
# they were missing, UI helpers such as mcp_result_with_ui did not exist in
# vendored projects or MCPB bundles.

load '../../node_modules/bats-support/load'
load '../../node_modules/bats-assert/load'
load '../common/fixtures'

@test "vendor: every sdk/*.sh is embedded" {
	dest="${BATS_TEST_TMPDIR}/project"
	mkdir -p "${dest}"
	run mcp-bash vendor --output "${dest}"
	assert_success
	local f
	for f in "${MCPBASH_HOME}"/sdk/*.sh; do
		[ -f "${dest}/.mcp-bash/sdk/$(basename "${f}")" ] || fail "missing .mcp-bash/sdk/$(basename "${f}")"
	done
}

@test "vendor: UI helpers are defined when a tool sources the vendored SDK" {
	dest="${BATS_TEST_TMPDIR}/project"
	mkdir -p "${dest}"
	run mcp-bash vendor --output "${dest}"
	assert_success
	run bash -c '. "$1/.mcp-bash/sdk/tool-sdk.sh" && declare -F mcp_result_with_ui' _ "${dest}"
	assert_success
}

@test "vendor --verify: passes with the full SDK embedded" {
	dest="${BATS_TEST_TMPDIR}/project"
	mkdir -p "${dest}"
	run mcp-bash vendor --output "${dest}"
	assert_success
	run mcp-bash vendor --verify --output "${dest}"
	assert_success
}
