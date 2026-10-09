#!/usr/bin/env bash
# Stress: race symlink swaps against the file and ui providers and assert that
# no read ever returns content from outside the allowed directory.
#
# A background racer keeps swapping a path between an in-root regular file and
# a symlink (or, in "parent" mode, a parent directory and a symlink to an outside
# directory) while the provider is invoked repeatedly. Any output containing the
# outside secret is a leak. Bounded by attempts and wall time:
#   SYMLINK_RACE_ATTEMPTS (default 1500 per mode)
#   SYMLINK_RACE_SECONDS  (default 7 per mode)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../common/env.sh
# shellcheck disable=SC1091
. "${SCRIPT_DIR}/../common/env.sh"
# shellcheck source=../common/assert.sh
# shellcheck disable=SC1091
. "${SCRIPT_DIR}/../common/assert.sh"

test_require_command perl

case "${OSTYPE:-}" in
msys* | cygwin*)
	printf 'SKIP: symlink race stress needs native symlinks (not available on Git Bash by default)\n'
	exit 0
	;;
esac

ATTEMPTS="${SYMLINK_RACE_ATTEMPTS:-1500}"
SECONDS_LIMIT="${SYMLINK_RACE_SECONDS:-7}"

test_create_tmpdir
BASE="$(cd "${TEST_TMPDIR}" && pwd -P)"
SECRET_MARK="OUTSIDE-SECRET-$$"
INSIDE_MARK="inside-ok"

RACER_PID=""
stop_racer() {
	if [ -n "${RACER_PID}" ]; then
		kill "${RACER_PID}" 2>/dev/null || true
		wait "${RACER_PID}" 2>/dev/null || true
		RACER_PID=""
	fi
}
trap 'stop_racer; test_cleanup_tmpdir' EXIT INT TERM

# perl gives atomic rename(2)/symlink(2)/link(2) without a fork per swap, so the
# swap rate is high enough to hit the window reliably.
start_racer() {
	local mode="$1" dir="$2" target="$3" name="$4"
	perl -e '
		my ($mode, $dir, $target, $name) = @ARGV;
		chdir $dir or die "chdir $dir: $!";
		if ($mode eq "final") {
			while (1) {
				unlink ".s"; symlink($target, ".s"); rename(".s", $name);
				unlink ".h"; link(".orig", ".h"); rename(".h", $name);
			}
		} else {
			while (1) {
				rename($name, ".realdir");
				unlink ".s"; symlink($target, ".s"); rename(".s", $name);
				unlink $name; rename(".realdir", $name);
			}
		}
	' "${mode}" "${dir}" "${target}" "${name}" &
	RACER_PID=$!
}

# with_timeout SECONDS CMD...: run CMD in its own process group and kill the
# whole group if it is still running after SECONDS (exit 124). On macOS a
# getcwd() inside a directory whose parent is being renamed can spin forever;
# this keeps one stuck call from stalling the run.
with_timeout() {
	perl -e '
		my $t = shift;
		my $pid = fork;
		die "fork: $!" unless defined $pid;
		if (!$pid) { setpgrp(0, 0); exec @ARGV or exit 127; }
		local $SIG{ALRM} = sub { kill "KILL", -$pid; waitpid($pid, 0); exit 124; };
		alarm $t;
		waitpid($pid, 0);
		exit($? & 127 ? 128 + ($? & 127) : $? >> 8);
	' "$@"
}

# run_race LABEL MODE RACE_DIR RACE_TARGET RACE_NAME -- CMD...
# CMD must be an external command (it runs under with_timeout).
run_race() {
	local label="$1" mode="$2" race_dir="$3" race_target="$4" race_name="$5"
	shift 6
	local ok=0 denied=0 notfound=0 hung=0 other=0 leaks=0 attempts=0 out rc
	local start="${SECONDS}"
	start_racer "${mode}" "${race_dir}" "${race_target}" "${race_name}"
	while [ "${attempts}" -lt "${ATTEMPTS}" ] && [ $((SECONDS - start)) -lt "${SECONDS_LIMIT}" ]; do
		attempts=$((attempts + 1))
		rc=0
		out="$(with_timeout 10 "$@" 2>/dev/null)" || rc=$?
		case "${out}" in
		*"${SECRET_MARK}"*) leaks=$((leaks + 1)) ;;
		esac
		case "${rc}" in
		0) ok=$((ok + 1)) ;;
		2) denied=$((denied + 1)) ;;
		3) notfound=$((notfound + 1)) ;;
		124) hung=$((hung + 1)) ;;
		*) other=$((other + 1)) ;;
		esac
	done
	stop_racer
	printf '  %s: attempts=%d ok=%d denied=%d notfound=%d hung=%d other=%d SECRET_leaks=%d (%ss)\n' \
		"${label}" "${attempts}" "${ok}" "${denied}" "${notfound}" "${hung}" "${other}" "${leaks}" "$((SECONDS - start))"
	LEAKS_TOTAL=$((LEAKS_TOTAL + leaks))
}

LEAKS_TOTAL=0

# --- Layout -----------------------------------------------------------------
OUTSIDE="${BASE}/outside"
ROOT="${BASE}/root"
mkdir -p "${OUTSIDE}/sub" "${ROOT}/sub"
printf '%s\n' "${SECRET_MARK}" >"${OUTSIDE}/secret"
printf '%s\n' "${SECRET_MARK}" >"${OUTSIDE}/sub/x"
printf '%s\n' "${INSIDE_MARK}" >"${ROOT}/.orig"
ln "${ROOT}/.orig" "${ROOT}/x"
printf '%s\n' "${INSIDE_MARK}" >"${ROOT}/sub/x"

FILE_CMD=(env MCP_RESOURCES_ROOTS="${ROOT}" "${MCPBASH_HOME}/providers/file.sh")

# Sanity: without a racer both reads succeed.
test_assert_eq "$("${FILE_CMD[@]}" "file://${ROOT}/x")" "${INSIDE_MARK}"
test_assert_eq "$("${FILE_CMD[@]}" "file://${ROOT}/sub/x")" "${INSIDE_MARK}"

printf 'Symlink race stress (attempts<=%s, seconds<=%s per mode)\n' "${ATTEMPTS}" "${SECONDS_LIMIT}"

run_race "file final-component" final "${ROOT}" "${OUTSIDE}/secret" x -- \
	"${FILE_CMD[@]}" "file://${ROOT}/x"

run_race "file parent-directory" parent "${ROOT}" "${OUTSIDE}/sub" sub -- \
	"${FILE_CMD[@]}" "file://${ROOT}/sub/x"

# --- UI provider (static file path, no registry) -----------------------------
# UI directories are not a confinement boundary (a UI directory may be a
# symlink), so only the final component is raced here.
UI_DIR="${BASE}/ui"
mkdir -p "${UI_DIR}/app"
printf '%s\n' "${INSIDE_MARK}" >"${UI_DIR}/app/.orig"
ln "${UI_DIR}/app/.orig" "${UI_DIR}/app/index.html"

UI_CMD=(env -u MCPBASH_HOME MCPBASH_UI_DIR="${UI_DIR}" MCPBASH_TOOLS_DIR="${BASE}/no-tools"
	"${MCPBASH_HOME}/providers/ui.sh" "ui://srv/app")

test_assert_eq "$("${UI_CMD[@]}")" "${INSIDE_MARK}"

run_race "ui final-component" final "${UI_DIR}/app" "${OUTSIDE}/secret" index.html -- \
	"${UI_CMD[@]}"

if [ "${LEAKS_TOTAL}" -ne 0 ]; then
	test_fail "symlink race leaked outside content ${LEAKS_TOTAL} time(s)"
fi
printf 'No leaks.\n'
