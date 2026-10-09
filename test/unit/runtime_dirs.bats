#!/usr/bin/env bats
# Unit layer: runtime state/lock/log directories must not be predictable or
# reachable through a planted symlink in a shared temp dir (lib/runtime.sh).

load '../../node_modules/bats-support/load'
load '../../node_modules/bats-assert/load'
load '../../node_modules/bats-file/load'
load '../common/fixtures'

setup() {
	unset MCPBASH_STATE_DIR MCPBASH_LOCK_ROOT MCPBASH_LOG_DIR MCPBASH_STATE_SEED
	unset MCPBASH_REGISTRY_DIR MCPBASH_CI_MODE MCPBASH_KEEP_LOGS MCPBASH_PRESERVE_STATE

	# shellcheck source=lib/runtime.sh
	# shellcheck disable=SC1091
	. "${MCPBASH_HOME}/lib/runtime.sh"

	TMP_BASE="${BATS_TEST_TMPDIR}/tmp"
	mkdir -p "${TMP_BASE}"
	export MCPBASH_TMP_ROOT="${TMP_BASE}"
	export MCPBASH_PROJECT_ROOT="${BATS_TEST_TMPDIR}/project"
	mkdir -p "${MCPBASH_PROJECT_ROOT}/server.d"

	# Where a planted symlink points: anything written through it lands here.
	VICTIM="${BATS_TEST_TMPDIR}/victim"
	mkdir -p "${VICTIM}"
}

victim_is_empty() {
	[ -z "$(ls -A "${VICTIM}")" ]
}

@test "runtime dirs: server state dir is fresh, private and holds the lock root" {
	mcp_runtime_init_paths
	assert_dir_exist "${MCPBASH_STATE_DIR}"
	[ ! -L "${MCPBASH_STATE_DIR}" ]
	case "${MCPBASH_STATE_DIR}" in
	"${TMP_BASE}"/mcpbash.state.*) ;;
	*) fail "unexpected state dir ${MCPBASH_STATE_DIR}" ;;
	esac
	assert_equal "${MCPBASH_LOCK_ROOT}" "${MCPBASH_STATE_DIR}/locks"
	assert_dir_exist "${MCPBASH_LOCK_ROOT}"
	run ls -ld "${MCPBASH_STATE_DIR}"
	assert_output --regexp '^drwx------'
}

@test "runtime dirs: symlink planted at the old predictable server path is not followed" {
	export MCPBASH_STATE_SEED=42
	# The pre-1.6.0 name: ${PPID}.${BASHPID:-$$}.${MCPBASH_STATE_SEED}.
	local predicted="${TMP_BASE}/mcpbash.state.${PPID}.${BASHPID:-$$}.42"
	ln -s "${VICTIM}" "${predicted}"
	mcp_runtime_init_paths
	[ "${MCPBASH_STATE_DIR}" != "${predicted}" ]
	[ ! -L "${MCPBASH_STATE_DIR}" ]
	victim_is_empty
}

@test "runtime dirs: two servers get distinct state dirs" {
	local first second
	first="$(mcp_runtime_init_paths >/dev/null && printf '%s' "${MCPBASH_STATE_DIR}")"
	second="$(mcp_runtime_init_paths >/dev/null && printf '%s' "${MCPBASH_STATE_DIR}")"
	[ -n "${first}" ] && [ -n "${second}" ]
	[ "${first}" != "${second}" ]
	assert_dir_exist "${first}"
	assert_dir_exist "${second}"
}

@test "runtime dirs: cli mode does not use a symlinked shared lock root or state path" {
	ln -s "${VICTIM}" "${TMP_BASE}/mcpbash.locks"
	ln -s "${VICTIM}" "${TMP_BASE}/mcpbash.state.$$"
	mcp_runtime_init_paths cli
	[ ! -L "${MCPBASH_STATE_DIR}" ]
	[ ! -L "${MCPBASH_LOCK_ROOT}" ]
	# shellcheck source=lib/lock.sh
	# shellcheck disable=SC1091
	. "${MCPBASH_HOME}/lib/lock.sh"
	mcp_lock_acquire "probe"
	mcp_lock_release "probe"
	victim_is_empty
}

@test "runtime dirs: cli mode does not reuse a pre-created shared lock root" {
	mkdir -p "${TMP_BASE}/mcpbash.locks"
	chmod 777 "${TMP_BASE}/mcpbash.locks"
	mcp_runtime_init_paths cli
	[ "${MCPBASH_LOCK_ROOT}" != "${TMP_BASE}/mcpbash.locks" ]
	case "${MCPBASH_LOCK_ROOT}" in
	"${MCPBASH_STATE_DIR}"/*) ;;
	*) fail "lock root ${MCPBASH_LOCK_ROOT} is outside the private state dir" ;;
	esac
}

@test "runtime dirs: MCPBASH_STATE_DIR override that is a symlink is refused" {
	ln -s "${VICTIM}" "${BATS_TEST_TMPDIR}/state-link"
	export MCPBASH_STATE_DIR="${BATS_TEST_TMPDIR}/state-link"
	run mcp_runtime_init_paths
	assert_failure
	assert_output --partial "symlink"
	victim_is_empty
}

@test "runtime dirs: MCPBASH_LOCK_ROOT override that is a symlink is refused" {
	ln -s "${VICTIM}" "${BATS_TEST_TMPDIR}/lock-link"
	export MCPBASH_LOCK_ROOT="${BATS_TEST_TMPDIR}/lock-link"
	run mcp_runtime_init_paths
	assert_failure
	assert_output --partial "symlink"
	victim_is_empty
}

@test "runtime dirs: MCPBASH_LOG_DIR that is a symlink is refused" {
	ln -s "${VICTIM}" "${BATS_TEST_TMPDIR}/log-link"
	export MCPBASH_LOG_DIR="${BATS_TEST_TMPDIR}/log-link"
	run mcp_runtime_init_paths
	assert_failure
	assert_output --partial "symlink"
	victim_is_empty
}

@test "runtime dirs: CI log dir default is fresh and private" {
	export MCPBASH_CI_MODE=true
	mcp_runtime_init_paths
	assert_dir_exist "${MCPBASH_LOG_DIR}"
	[ ! -L "${MCPBASH_LOG_DIR}" ]
	case "${MCPBASH_LOG_DIR}" in
	"${TMP_BASE}"/mcpbash.logs.*) ;;
	*) fail "unexpected log dir ${MCPBASH_LOG_DIR}" ;;
	esac
	run ls -ld "${MCPBASH_LOG_DIR}"
	assert_output --regexp '^drwx------'
}

@test "runtime dirs: operator overrides that are real dirs are honoured" {
	export MCPBASH_STATE_DIR="${BATS_TEST_TMPDIR}/op-state"
	export MCPBASH_LOCK_ROOT="${BATS_TEST_TMPDIR}/op-locks"
	mcp_runtime_init_paths
	assert_equal "${MCPBASH_STATE_DIR}" "${BATS_TEST_TMPDIR}/op-state"
	assert_equal "${MCPBASH_LOCK_ROOT}" "${BATS_TEST_TMPDIR}/op-locks"
	assert_dir_exist "${MCPBASH_STATE_DIR}"
	assert_dir_exist "${MCPBASH_LOCK_ROOT}"
}

@test "runtime dirs: safe_rmrf refuses a symlink and leaves its target alone" {
	touch "${VICTIM}/keep"
	ln -s "${VICTIM}" "${TMP_BASE}/mcpbash.state.planted"
	run mcp_runtime_safe_rmrf "${TMP_BASE}/mcpbash.state.planted"
	assert_failure
	assert_file_exist "${VICTIM}/keep"
}

@test "runtime dirs: cleanup removes the state dir it created" {
	mcp_io_log_corruption_summary() { :; }
	mcp_runtime_init_paths
	local state="${MCPBASH_STATE_DIR}"
	assert_dir_exist "${state}"
	mcp_runtime_cleanup
	assert_dir_not_exist "${state}"
}

@test "runtime dirs: cleanup does not follow a state dir swapped for a symlink" {
	mcp_io_log_corruption_summary() { :; }
	mcp_runtime_init_paths
	local state="${MCPBASH_STATE_DIR}"
	rm -rf "${state}"
	touch "${VICTIM}/keep"
	ln -s "${VICTIM}" "${state}"
	mcp_runtime_cleanup
	assert_file_exist "${VICTIM}/keep"
}

@test "runtime dirs: cli commands leave no state or lock dirs behind" {
	cp -a "${MCPBASH_HOME}/examples/00-hello-tool/." "${MCPBASH_PROJECT_ROOT}/"
	unset MCPBASH_TMP_ROOT
	export TMPDIR="${TMP_BASE}"
	run "${MCPBASH_HOME}/bin/mcp-bash" registry refresh --project-root "${MCPBASH_PROJECT_ROOT}"
	assert_success
	run ls -A "${TMP_BASE}"
	refute_output --partial "mcpbash.state."
	refute_output --partial "mcpbash.locks"
}
