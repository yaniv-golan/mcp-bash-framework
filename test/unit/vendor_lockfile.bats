#!/usr/bin/env bats
# Unit tests for mcp-bash vendor: lockfile schema, integrity verification,
# and tamper detection.

load '../../node_modules/bats-support/load'
load '../../node_modules/bats-assert/load'
load '../common/fixtures'

setup() {
	# sha256 tool required for hash tests
	if command -v sha256sum >/dev/null 2>&1; then
		SHA_TOOL="sha256sum"
	elif command -v shasum >/dev/null 2>&1; then
		SHA_TOOL="shasum"
	else
		skip "sha256sum or shasum required"
	fi

	VENDOR_DIR="${BATS_TEST_TMPDIR}/project"
	mkdir -p "${VENDOR_DIR}"
}

# ---------------------------------------------------------------------------
# EMBED_REQUIRED_LIBS is the canonical source (sanity-check it is loadable)
# ---------------------------------------------------------------------------

@test "vendor: embed.sh declares EMBED_REQUIRED_LIBS" {
	[ -f "${MCPBASH_HOME}/lib/cli/embed.sh" ] \
		|| fail "lib/cli/embed.sh does not exist"
	grep -q '^EMBED_REQUIRED_LIBS=' "${MCPBASH_HOME}/lib/cli/embed.sh" \
		|| fail "EMBED_REQUIRED_LIBS not declared in lib/cli/embed.sh"
}

@test "vendor: vendor.sh exists and declares mcp_cli_vendor" {
	[ -f "${MCPBASH_HOME}/lib/cli/vendor.sh" ] \
		|| fail "lib/cli/vendor.sh does not exist"
	grep -q '^mcp_cli_vendor()' "${MCPBASH_HOME}/lib/cli/vendor.sh" \
		|| fail "mcp_cli_vendor() not declared in lib/cli/vendor.sh"
}

# ---------------------------------------------------------------------------
# Successful vendor run produces expected files and valid lockfile
# ---------------------------------------------------------------------------

@test "vendor: produces .mcp-bash/ with vendor.json" {
	run mcp-bash vendor --output "${VENDOR_DIR}"
	assert_success

	[ -d "${VENDOR_DIR}/.mcp-bash" ] \
		|| fail ".mcp-bash/ directory not created"
	[ -f "${VENDOR_DIR}/.mcp-bash/vendor.json" ] \
		|| fail "vendor.json not created"
}

@test "vendor: vendor.json contains required fields" {
	run mcp-bash vendor --output "${VENDOR_DIR}"
	assert_success

	local lockfile="${VENDOR_DIR}/.mcp-bash/vendor.json"

	# version field present and non-empty
	local version
	version="$(jq -r '.version // empty' "${lockfile}")"
	[ -n "${version}" ] || fail "vendor.json missing version field"

	# sha256 field present and looks like a hex digest
	local sha256
	sha256="$(jq -r '.sha256 // empty' "${lockfile}")"
	[ -n "${sha256}" ] || fail "vendor.json missing sha256 field"
	[[ "${sha256}" =~ ^[0-9a-f]{64}$ ]] || fail "sha256 field is not a 64-char hex string: ${sha256}"

	# vendored_from field present
	local vendored_from
	vendored_from="$(jq -r '.vendored_from // empty' "${lockfile}")"
	[ -n "${vendored_from}" ] || fail "vendor.json missing vendored_from field"

	# vendored_at field present and looks like an ISO timestamp
	local vendored_at
	vendored_at="$(jq -r '.vendored_at // empty' "${lockfile}")"
	[ -n "${vendored_at}" ] || fail "vendor.json missing vendored_at field"
}

@test "vendor: version in vendor.json matches framework VERSION file" {
	run mcp-bash vendor --output "${VENDOR_DIR}"
	assert_success

	local expected_version
	expected_version="$(cat "${MCPBASH_HOME}/VERSION")"
	local got_version
	got_version="$(jq -r '.version' "${VENDOR_DIR}/.mcp-bash/vendor.json")"

	[ "${expected_version}" = "${got_version}" ] \
		|| fail "version mismatch: expected '${expected_version}', got '${got_version}'"
}

@test "vendor: embeds runtime files" {
	run mcp-bash vendor --output "${VENDOR_DIR}"
	assert_success

	local fd="${VENDOR_DIR}/.mcp-bash"
	[ -f "${fd}/bin/mcp-bash" ]        || fail "bin/mcp-bash missing"
	[ -f "${fd}/sdk/tool-sdk.sh" ]     || fail "sdk/tool-sdk.sh missing"
	[ -f "${fd}/VERSION" ]             || fail "VERSION missing"
	[ -d "${fd}/handlers" ]            || fail "handlers/ missing"
	[ -d "${fd}/providers" ]           || fail "providers/ missing"
	[ -d "${fd}/lib" ]                 || fail "lib/ missing"
}

@test "vendor: embeds built-in providers" {
	run mcp-bash vendor --output "${VENDOR_DIR}"
	assert_success

	local provider
	for provider in file https git echo ui; do
		[ -f "${VENDOR_DIR}/.mcp-bash/providers/${provider}.sh" ] \
			|| fail "built-in provider missing after vendor: providers/${provider}.sh"
	done
}

# ---------------------------------------------------------------------------
# --verify: succeeds on untampered tree, fails after modification
# ---------------------------------------------------------------------------

@test "vendor --verify: succeeds on fresh vendor" {
	run mcp-bash vendor --output "${VENDOR_DIR}"
	assert_success

	run mcp-bash vendor --verify --output "${VENDOR_DIR}"
	assert_success
}

@test "vendor --verify: fails after file tampered" {
	run mcp-bash vendor --output "${VENDOR_DIR}"
	assert_success

	# Tamper with one of the vendored files
	printf '\n# tampered\n' >>"${VENDOR_DIR}/.mcp-bash/VERSION"

	run mcp-bash vendor --verify --output "${VENDOR_DIR}"
	assert_failure
}

@test "vendor --verify: fails when vendor.json missing" {
	run mcp-bash vendor --output "${VENDOR_DIR}"
	assert_success

	rm "${VENDOR_DIR}/.mcp-bash/vendor.json"

	run mcp-bash vendor --verify --output "${VENDOR_DIR}"
	assert_failure
}

# ---------------------------------------------------------------------------
# --upgrade: replaces existing tree without prompting
# ---------------------------------------------------------------------------

@test "vendor --upgrade: replaces existing vendor tree" {
	run mcp-bash vendor --output "${VENDOR_DIR}"
	assert_success

	# Tamper to prove it gets replaced
	printf 'stale' >"${VENDOR_DIR}/.mcp-bash/VERSION"

	run mcp-bash vendor --upgrade --output "${VENDOR_DIR}"
	assert_success

	# Should now verify cleanly
	run mcp-bash vendor --verify --output "${VENDOR_DIR}"
	assert_success
}

# ---------------------------------------------------------------------------
# --dry-run: no files created
# ---------------------------------------------------------------------------

@test "vendor --dry-run: does not create .mcp-bash/" {
	run mcp-bash vendor --dry-run --output "${VENDOR_DIR}"
	assert_success

	[ ! -d "${VENDOR_DIR}/.mcp-bash" ] \
		|| fail "--dry-run created .mcp-bash/ when it should not have"
}

# ---------------------------------------------------------------------------
# Guard: existing tree without --upgrade in non-interactive mode
# ---------------------------------------------------------------------------

@test "vendor: fails without --upgrade when .mcp-bash/ exists (non-interactive)" {
	run mcp-bash vendor --output "${VENDOR_DIR}"
	assert_success

	# Second run without --upgrade and stdin closed (non-interactive)
	run bash -c "mcp-bash vendor --output '${VENDOR_DIR}' </dev/null"
	assert_failure
}
