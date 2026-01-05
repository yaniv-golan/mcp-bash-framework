#!/usr/bin/env bats
# Unit: regression for registry refresh path containment checks.
#
# mcp_registry_resolve_scan_root must treat paths literally (not as globs).
# Otherwise, a default dir like "default[1]" could wildcard-match "default1"
# and allow scanning outside the intended directory.

load '../../node_modules/bats-support/load'
load '../../node_modules/bats-assert/load'
load '../common/fixtures'

setup() {
	# shellcheck source=lib/registry.sh
	# shellcheck disable=SC1091
	. "${MCPBASH_HOME}/lib/registry.sh"

	DEFAULT_DIR="${BATS_TEST_TMPDIR}/default[1]"
	OUTSIDE_DIR="${BATS_TEST_TMPDIR}/default1"
	INSIDE_DIR="${DEFAULT_DIR}/sub"
	mkdir -p "${DEFAULT_DIR}" "${OUTSIDE_DIR}" "${INSIDE_DIR}"

	export MCPBASH_PROJECT_ROOT="${BATS_TEST_TMPDIR}"
}

@test "registry: rejects refresh path that only matches via glob metacharacters" {
	export MCPBASH_REGISTRY_REFRESH_PATH="default1"
	resolved="$(mcp_registry_resolve_scan_root "${DEFAULT_DIR}")"
	assert_equal "${DEFAULT_DIR}" "${resolved}"
}

@test "registry: accepts refresh path under default dir (literal containment)" {
	export MCPBASH_REGISTRY_REFRESH_PATH="default[1]/sub"
	resolved_inside="$(mcp_registry_resolve_scan_root "${DEFAULT_DIR}")"
	assert_equal "${INSIDE_DIR}" "${resolved_inside}"
}
