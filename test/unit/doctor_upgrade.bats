#!/usr/bin/env bats
# Unit tests for doctor managed-install upgrade flow (archive + verify).

load '../../node_modules/bats-support/load'
load '../../node_modules/bats-assert/load'
load '../common/fixtures'

# Exit code contract (see `mcp-bash doctor --help`):
# 3 = policy refusal (used for downgrade refusal unless --allow-downgrade).
EXIT_POLICY_REFUSAL="3"

setup() {
	[ -n "${TEST_JSON_TOOL_BIN:-}" ] || skip "jq/gojq required"

	# Initialize SHA256 command
	if command -v sha256sum >/dev/null 2>&1; then
		TEST_SHA256_CMD=(sha256sum)
	elif command -v shasum >/dev/null 2>&1; then
		TEST_SHA256_CMD=(shasum -a 256)
	else
		skip "sha256sum or shasum required"
	fi

	HOME_ROOT="${BATS_TEST_TMPDIR}/home"
	export HOME="${HOME_ROOT}"
	export XDG_DATA_HOME="${HOME}/.local/share"
	export XDG_BIN_HOME="${HOME}/.local/bin"
	mkdir -p "${XDG_DATA_HOME}" "${XDG_BIN_HOME}"

	MANAGED_ROOT="${XDG_DATA_HOME}/mcp-bash"
	mkdir -p "${MANAGED_ROOT}"

	# Seed managed install with old VERSION
	(
		cd "${MCPBASH_HOME}" || exit 1
		tar -cf - --exclude .git bin lib VERSION | (cd "${MANAGED_ROOT}" && tar -xf -)
	)
	printf '%s\n' '{"managed":true}' >"${MANAGED_ROOT}/INSTALLER.json"
	printf '%s\n' "0.0.0" >"${MANAGED_ROOT}/VERSION"

	# Build verified archive from repo
	ARCHIVE_STAGE="${BATS_TEST_TMPDIR}/archive-stage"
	mkdir -p "${ARCHIVE_STAGE}/mcp-bash"
	(
		cd "${MCPBASH_HOME}" || exit 1
		tar -cf - --exclude .git . | (cd "${ARCHIVE_STAGE}/mcp-bash" && tar -xf -)
	)
	ARCHIVE_PATH="${BATS_TEST_TMPDIR}/mcp-bash-test.tar.gz"
	(cd "${ARCHIVE_STAGE}" && tar -czf "${ARCHIVE_PATH}" mcp-bash)
	archive_sha="$("${TEST_SHA256_CMD[@]}" "${ARCHIVE_PATH}" | awk '{print $1}')"
	min_version="$(tr -d '[:space:]' <"${MCPBASH_HOME}/VERSION")"
}

@test "doctor_upgrade: doctor --dry-run proposes upgrade" {
	archive_sha="$("${TEST_SHA256_CMD[@]}" "${ARCHIVE_PATH}" | awk '{print $1}')"
	min_version="$(tr -d '[:space:]' <"${MCPBASH_HOME}/VERSION")"

	run env -u MCPBASH_HOME "${MANAGED_ROOT}/bin/mcp-bash" doctor --dry-run --json --min-version "${min_version}" --archive "${ARCHIVE_PATH}" --verify "${archive_sha}"
	assert_success
	printf '%s\n' "${output}" >"${BATS_TEST_TMPDIR}/dry.json"
	jq -e '.exitCode == 0' "${BATS_TEST_TMPDIR}/dry.json" >/dev/null
	jq -e '.proposedActions | map(.id) | index("self.upgrade") != null' "${BATS_TEST_TMPDIR}/dry.json" >/dev/null
}

@test "doctor_upgrade: doctor --fix performs upgrade" {
	archive_sha="$("${TEST_SHA256_CMD[@]}" "${ARCHIVE_PATH}" | awk '{print $1}')"
	min_version="$(tr -d '[:space:]' <"${MCPBASH_HOME}/VERSION")"

	run env -u MCPBASH_HOME "${MANAGED_ROOT}/bin/mcp-bash" doctor --fix --json --min-version "${min_version}" --archive "${ARCHIVE_PATH}" --verify "${archive_sha}"
	assert_success
	printf '%s\n' "${output}" >"${BATS_TEST_TMPDIR}/fix.json"
	jq -e '.exitCode == 0' "${BATS_TEST_TMPDIR}/fix.json" >/dev/null
	jq -e '.actionsTaken | map(.id) | index("self.upgrade") != null' "${BATS_TEST_TMPDIR}/fix.json" >/dev/null

	installed_version="$(tr -d '[:space:]' <"${MANAGED_ROOT}/VERSION")"
	assert_equal "${min_version}" "${installed_version}"
}

@test "doctor_upgrade: doctor refuses downgrade without --allow-downgrade" {
	archive_sha="$("${TEST_SHA256_CMD[@]}" "${ARCHIVE_PATH}" | awk '{print $1}')"

	printf '%s\n' "9.9.9" >"${MANAGED_ROOT}/VERSION"
	run env -u MCPBASH_HOME "${MANAGED_ROOT}/bin/mcp-bash" doctor --fix --json --archive "${ARCHIVE_PATH}" --verify "${archive_sha}"
	assert_equal "${EXIT_POLICY_REFUSAL}" "${status}"
	printf '%s\n' "${output}" >"${BATS_TEST_TMPDIR}/downgrade_refuse.json"
	jq -e '.exitCode == 3' "${BATS_TEST_TMPDIR}/downgrade_refuse.json" >/dev/null
	jq -e '.findings | map(.id) | index("self.upgrade_downgrade_refused") != null' "${BATS_TEST_TMPDIR}/downgrade_refuse.json" >/dev/null
	installed_version="$(tr -d '[:space:]' <"${MANAGED_ROOT}/VERSION")"
	assert_equal "9.9.9" "${installed_version}"
}

@test "doctor_upgrade: doctor allows downgrade with --allow-downgrade" {
	archive_sha="$("${TEST_SHA256_CMD[@]}" "${ARCHIVE_PATH}" | awk '{print $1}')"
	min_version="$(tr -d '[:space:]' <"${MCPBASH_HOME}/VERSION")"

	printf '%s\n' "9.9.9" >"${MANAGED_ROOT}/VERSION"
	run env -u MCPBASH_HOME "${MANAGED_ROOT}/bin/mcp-bash" doctor --fix --json --allow-downgrade --archive "${ARCHIVE_PATH}" --verify "${archive_sha}"
	assert_success
	printf '%s\n' "${output}" >"${BATS_TEST_TMPDIR}/downgrade_allow.json"
	jq -e '.exitCode == 0' "${BATS_TEST_TMPDIR}/downgrade_allow.json" >/dev/null
	installed_version="$(tr -d '[:space:]' <"${MANAGED_ROOT}/VERSION")"
	assert_equal "${min_version}" "${installed_version}"
}
