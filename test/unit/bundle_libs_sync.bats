#!/usr/bin/env bats
# Unit layer: verify BUNDLE_REQUIRED_LIBS includes all libs sourced by bin/mcp-bash.
#
# This test prevents releases with missing bundled libraries (e.g., 0.9.9, 0.9.10).
# See docs/internal/plan-bundle-libs-sync-2026-01-08.md for background.

load '../../node_modules/bats-support/load'
load '../../node_modules/bats-assert/load'
load '../common/fixtures'

@test "bundle_libs_sync: BUNDLE_REQUIRED_LIBS includes all sourced libs" {
	# Extract libs sourced in bin/mcp-bash (lines like: . "${MCPBASH_HOME}/lib/foo.sh")
	local sourced
	sourced=$(grep -E '^\s*\. "\$\{MCPBASH_HOME\}/lib/[^/]+\.sh"' "${MCPBASH_HOME}/bin/mcp-bash" \
		| sed 's|.*lib/\([^.]*\)\.sh.*|\1|' | sort -u)

	# Extract BUNDLE_REQUIRED_LIBS from bundle.sh
	local bundled
	bundled=$(grep '^BUNDLE_REQUIRED_LIBS=' "${MCPBASH_HOME}/lib/cli/bundle.sh" \
		| sed 's/.*="\([^"]*\)".*/\1/' | tr ' ' '\n' | sort -u)

	# Check each sourced lib is in bundle list
	local missing=""
	local lib
	for lib in ${sourced}; do
		echo "${bundled}" | grep -qx "${lib}" || missing="${missing} ${lib}"
	done

	[ -z "${missing}" ] || fail "Missing from BUNDLE_REQUIRED_LIBS:${missing}"
}

@test "bundle_libs_sync: all BUNDLE_REQUIRED_LIBS files exist" {
	# Extract BUNDLE_REQUIRED_LIBS
	local bundled
	bundled=$(grep '^BUNDLE_REQUIRED_LIBS=' "${MCPBASH_HOME}/lib/cli/bundle.sh" \
		| sed 's/.*="\([^"]*\)".*/\1/')

	# Check each lib file exists
	local missing=""
	local lib
	for lib in ${bundled}; do
		[ -f "${MCPBASH_HOME}/lib/${lib}.sh" ] || missing="${missing} ${lib}"
	done

	[ -z "${missing}" ] || fail "BUNDLE_REQUIRED_LIBS references missing files:${missing}"
}
