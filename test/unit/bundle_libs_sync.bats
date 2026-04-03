#!/usr/bin/env bats
# Unit layer: verify EMBED_REQUIRED_LIBS (in lib/cli/embed.sh) includes all libs
# sourced by bin/mcp-bash, and that all referenced files exist.
#
# This test prevents releases with missing embedded libraries (e.g., 0.9.9, 0.9.10).
# See docs/internal/plan-bundle-libs-sync-2026-01-08.md for background.
#
# EMBED_REQUIRED_LIBS is the canonical list consumed by both 'bundle' and 'vendor'.
# bundle.sh aliases it as BUNDLE_REQUIRED_LIBS for backward compat.

load '../../node_modules/bats-support/load'
load '../../node_modules/bats-assert/load'
load '../common/fixtures'

@test "bundle_libs_sync: EMBED_REQUIRED_LIBS includes all sourced libs" {
	# Extract libs sourced in bin/mcp-bash (lines like: . "${MCPBASH_HOME}/lib/foo.sh")
	local sourced
	sourced=$(grep -E '^\s*\. "\$\{MCPBASH_HOME\}/lib/[^/]+\.sh"' "${MCPBASH_HOME}/bin/mcp-bash" \
		| sed 's|.*lib/\([^.]*\)\.sh.*|\1|' | sort -u)

	# Extract EMBED_REQUIRED_LIBS from embed.sh (canonical source)
	local bundled
	bundled=$(grep '^EMBED_REQUIRED_LIBS=' "${MCPBASH_HOME}/lib/cli/embed.sh" \
		| sed 's/.*="\([^"]*\)".*/\1/' | tr ' ' '\n' | sort -u)

	# Check each sourced lib is in embed list
	local missing=""
	local lib
	for lib in ${sourced}; do
		echo "${bundled}" | grep -qx "${lib}" || missing="${missing} ${lib}"
	done

	[ -z "${missing}" ] || fail "Missing from EMBED_REQUIRED_LIBS:${missing}"
}

@test "bundle_libs_sync: all EMBED_REQUIRED_LIBS files exist" {
	# Extract EMBED_REQUIRED_LIBS from the canonical source
	local bundled
	bundled=$(grep '^EMBED_REQUIRED_LIBS=' "${MCPBASH_HOME}/lib/cli/embed.sh" \
		| sed 's/.*="\([^"]*\)".*/\1/')

	# Check each lib file exists
	local missing=""
	local lib
	for lib in ${bundled}; do
		[ -f "${MCPBASH_HOME}/lib/${lib}.sh" ] || missing="${missing} ${lib}"
	done

	[ -z "${missing}" ] || fail "EMBED_REQUIRED_LIBS references missing files:${missing}"
}

@test "bundle_libs_sync: BUNDLE_REQUIRED_LIBS in bundle.sh matches EMBED_REQUIRED_LIBS" {
	# bundle.sh aliases EMBED_REQUIRED_LIBS as BUNDLE_REQUIRED_LIBS for compat.
	# Verify the alias is still in sync (i.e. the assignment references EMBED_REQUIRED_LIBS).
	grep -q 'BUNDLE_REQUIRED_LIBS.*EMBED_REQUIRED_LIBS' "${MCPBASH_HOME}/lib/cli/bundle.sh" \
		|| fail "bundle.sh does not alias BUNDLE_REQUIRED_LIBS from EMBED_REQUIRED_LIBS"
}

@test "bundle_libs_sync: all built-in providers exist" {
	local provider
	for provider in file https git echo ui; do
		[ -f "${MCPBASH_HOME}/providers/${provider}.sh" ] \
			|| fail "Built-in provider missing: providers/${provider}.sh"
	done
}
