#!/usr/bin/env bats
# Unit layer: path normalization helpers (lib/path.sh).

load '../../node_modules/bats-support/load'
load '../../node_modules/bats-assert/load'
load '../common/fixtures'

setup() {
	# shellcheck source=lib/path.sh
	# shellcheck disable=SC1091
	. "${MCPBASH_HOME}/lib/path.sh"

	TEST_WORKDIR="${BATS_TEST_TMPDIR}/pathtest"
	mkdir -p "${TEST_WORKDIR}/base/dir"
}

@test "path: collapses relative with dot-dot relative to PWD" {
	cd "${TEST_WORKDIR}/base/dir"
	collapsed="$(mcp_path_collapse '../../..')"
	expected_collapse="$(cd ../../.. && pwd)"
	assert_equal "${expected_collapse}" "${collapsed}"
}

@test "path: normalize relative dot-dot to absolute path" {
	cd "${TEST_WORKDIR}/base/dir"
	normalized="$(mcp_path_normalize "../dir")"
	expected_norm="$(cd . && pwd -P)"
	assert_equal "${expected_norm}" "${normalized}"
}

@test "path: squashes multiple slashes" {
	cd "${TEST_WORKDIR}"
	raw_path="${TEST_WORKDIR}//base///dir//"
	normalized_slash="$(mcp_path_normalize "${raw_path}")"
	expected_slash="$(cd "${TEST_WORKDIR}/base/dir" && pwd -P)"
	assert_equal "${expected_slash}" "${normalized_slash}"
}

@test "path: collapses parent traversal components" {
	parent_path="${TEST_WORKDIR}/base/dir/../other"
	normalized_parent="$(mcp_path_collapse "${parent_path}")"
	expected_parent="${TEST_WORKDIR}/base/other"
	assert_equal "${expected_parent}" "${normalized_parent}"
}

@test "path: empty normalize resolves to PWD when resolver exists" {
	cd "${TEST_WORKDIR}"
	empty_norm="$(mcp_path_normalize '')"
	assert_equal "$(pwd -P)" "${empty_norm}"
}

@test "path: normalizes msys-style drive letters to uppercase" {
	msys_path="/c/Users/Test"
	normalized_drive="$(mcp_path_normalize "${msys_path}")"
	assert_equal "/C/Users/Test" "${normalized_drive}"
}
