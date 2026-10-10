#!/usr/bin/env bats
# Unit: doctor warns when the git provider is enabled but the installed git is
# too old (< 2.37) to pin DNS, since the provider then refuses every hostname
# fetch. No network: git is a fake on PATH.

load '../../node_modules/bats-support/load'
load '../../node_modules/bats-assert/load'
load '../common/fixtures'

setup() {
	[ -n "${TEST_JSON_TOOL_BIN:-}" ] || skip "jq/gojq required"
	BIN_DIR="${BATS_TEST_TMPDIR}/bin"
	mkdir -p "${BIN_DIR}"
	# Run outside any project so only runtime checks apply.
	WORK_DIR="${BATS_TEST_TMPDIR}/work"
	mkdir -p "${WORK_DIR}"
	cd "${WORK_DIR}" || return 1
}

# write_fake_git <version>
write_fake_git() {
	cat >"${BIN_DIR}/git" <<EOF
#!/usr/bin/env bash
if [ "\${1:-}" = "--version" ]; then
	printf 'git version %s\n' "$1"
	exit 0
fi
exit 1
EOF
	chmod 700 "${BIN_DIR}/git"
}

# make_path_without_git: NOGIT_DIR mirrors every command on PATH except git, so
# doctor runs with git genuinely absent (macOS ships /usr/bin/git, so dropping
# a directory from PATH is not enough).
make_path_without_git() {
	NOGIT_DIR="${BATS_TEST_TMPDIR}/nogit-bin"
	mkdir -p "${NOGIT_DIR}"
	local dir entry name
	local IFS=':'
	for dir in ${PATH}; do
		[ -d "${dir}" ] || continue
		for entry in "${dir}"/*; do
			name="${entry##*/}"
			[ "${name}" = "git" ] && continue
			[ -x "${entry}" ] && [ ! -d "${entry}" ] || continue
			[ -e "${NOGIT_DIR}/${name}" ] || ln -s "${entry}" "${NOGIT_DIR}/${name}"
		done
	done
}

# run_doctor_without_git <enable-git-provider> [doctor args...]
run_doctor_without_git() {
	local enable="$1"
	shift
	run env PATH="${NOGIT_DIR}" \
		HOME="${BATS_TEST_TMPDIR}/home" \
		MCPBASH_ENABLE_GIT_PROVIDER="${enable}" \
		"${MCPBASH_HOME}/bin/mcp-bash" doctor "$@"
}

# run_doctor <enable-git-provider> [doctor args...]
run_doctor() {
	local enable="$1"
	shift
	run env PATH="${BIN_DIR}:${PATH}" \
		HOME="${BATS_TEST_TMPDIR}/home" \
		MCPBASH_ENABLE_GIT_PROVIDER="${enable}" \
		"${MCPBASH_HOME}/bin/mcp-bash" doctor "$@"
}

# assert_json_finding_count <n>: doctor --json output (in $output) holds <n>
# git.version_unpinnable warnings. On bash 3.2, doctor --json can currently
# emit malformed JSON for unrelated fields (empty-string quoting), so there the
# finding is counted textually when the document does not parse.
assert_json_finding_count() {
	local want="$1" got=""
	if got="$(printf '%s\n' "${output}" | "${TEST_JSON_TOOL_BIN}" -e \
		'.findings | map(select(.id == "git.version_unpinnable" and .severity == "warning")) | length' 2>/dev/null)"; then
		assert_equal "${got}" "${want}"
		return 0
	fi
	[ "$(bash -c 'printf %s "${BASH_VERSINFO[0]}"')" -lt 4 ] || fail "doctor --json output is not valid JSON: ${output}"
	got="$(printf '%s\n' "${output}" | grep -c '"git.version_unpinnable"' || true)"
	assert_equal "${got}" "${want}"
}

@test "doctor_git_version: warns when the git provider is enabled and git is older than 2.37" {
	write_fake_git "2.34.1"
	run_doctor true
	assert_output --partial "git 2.34.1 is older than 2.37"
	assert_output --partial "MCPBASH_ENABLE_GIT_PROVIDER"
	assert_output --partial "upgrade git to >= 2.37"
	run_doctor true --json
	assert_json_finding_count 1
	assert_output --partial "upgrade git to >= 2.37"
}

@test "doctor_git_version: silent when git is new enough" {
	write_fake_git "2.40.1"
	run_doctor true
	refute_output --partial "older than 2.37"
	run_doctor true --json
	assert_json_finding_count 0
}

@test "doctor_git_version: silent when the git provider is not enabled" {
	write_fake_git "2.34.1"
	run_doctor false
	refute_output --partial "older than 2.37"
	run_doctor false --json
	assert_json_finding_count 0
}

# count_git_missing: number of git.missing warnings in doctor --json output.
count_git_missing() {
	local got=""
	if got="$(printf '%s\n' "${output}" | "${TEST_JSON_TOOL_BIN}" -e \
		'.findings | map(select(.id == "git.missing" and .severity == "warning")) | length' 2>/dev/null)"; then
		printf '%s' "${got}"
		return 0
	fi
	[ "$(bash -c 'printf %s "${BASH_VERSINFO[0]}"')" -lt 4 ] || fail "doctor --json output is not valid JSON: ${output}"
	printf '%s\n' "${output}" | grep -c '"git.missing"' || true
}

@test "doctor_git_version: warns when the git provider is enabled and git is missing" {
	make_path_without_git
	run env PATH="${NOGIT_DIR}" bash -c 'command -v git'
	assert_failure
	run_doctor_without_git true
	assert_output --partial "git is not on PATH"
	assert_output --partial "MCPBASH_ENABLE_GIT_PROVIDER"
	run_doctor_without_git true --json
	assert_equal "$(count_git_missing)" "1"
}

@test "doctor_git_version: no missing-git warning when the git provider is off" {
	make_path_without_git
	run_doctor_without_git false
	refute_output --partial "git is not on PATH"
	run_doctor_without_git false --json
	assert_equal "$(count_git_missing)" "0"
}
