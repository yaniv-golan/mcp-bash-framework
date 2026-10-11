#!/usr/bin/env bash
# shellcheck disable=SC2034  # Used by test runner for reporting.
TEST_DESC="Background helpers exit when the server is killed, even before its parent reaps it."
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../common/env.sh
# shellcheck disable=SC1091
. "${SCRIPT_DIR}/../common/env.sh"
# shellcheck source=../common/assert.sh
# shellcheck disable=SC1091
. "${SCRIPT_DIR}/../common/assert.sh"

case "$(uname -s 2>/dev/null)" in
CYGWIN* | MINGW* | MSYS*)
	printf 'SKIP: needs FIFOs and POSIX zombies\n'
	exit 0
	;;
esac
if ! command -v perl >/dev/null 2>&1; then
	printf 'SKIP: perl not available\n'
	exit 0
fi

test_create_tmpdir
WS="${TEST_TMPDIR}/ws"
test_stage_workspace "${WS}"
mkdir -p "${WS}/server.d"
printf '%s\n' '{"name": "zombie-helpers"}' >"${WS}/server.d/server.meta.json"
chmod -R go-w "${WS}"

in="${TEST_TMPDIR}/in"
out="${TEST_TMPDIR}/out"
pidf="${TEST_TMPDIR}/server.pid"
go="${TEST_TMPDIR}/go"
mkfifo "${in}" "${out}"

# The parent: starts the server, SIGKILLs it on request, and never reaps it,
# so the server stays a zombie for as long as the parent lives.
(
	cd "${WS}" || exit 1
	MCPBASH_ENABLE_LIVE_PROGRESS=true MCPBASH_IDLE_TIMEOUT=0 \
		PIDF="${pidf}" GO="${go}" exec perl -e '
		my $pid = fork;
		defined $pid or exit 1;
		if (!$pid) { exec @ARGV or exit 127; }
		open(my $f, ">", $ENV{PIDF}) or exit 1; print $f $pid; close $f;
		until (-e $ENV{GO}) { select(undef, undef, undef, 0.1); }
		kill 9, $pid;
		sleep 30;
	' bash ./bin/mcp-bash <"${in}" >"${out}" 2>"${TEST_TMPDIR}/server.err"
) &
parent=$!

helpers=""
cleanup() {
	kill "${parent}" 2>/dev/null || true
	local p
	for p in ${helpers}; do kill -KILL "${p}" 2>/dev/null || true; done
}
trap cleanup EXIT

exec 7>"${in}"
exec 8<"${out}"
printf '%s\n' '{"jsonrpc":"2.0","id":"init","method":"initialize","params":{}}' >&7
IFS= read -r -t 10 line <&8 || test_fail "no initialize response"
printf '%s\n' '{"jsonrpc":"2.0","method":"notifications/initialized"}' >&7
server="$(cat "${pidf}")"

# Live progress starts the progress flusher, a long-lived child of the server.
n=0
while [ -z "${helpers}" ]; do
	helpers="$(pgrep -P "${server}" 2>/dev/null | tr '\n' ' ' || true)"
	n=$((n + 1))
	[ "${n}" -lt 100 ] || test_fail "server started no background helpers"
	sleep 0.1
done

: >"${go}"
n=0
# Process state: /proc where it exists (BusyBox ps has no -p), else ps.
proc_state() {
	if [ -r "/proc/$1/stat" ]; then
		local line
		line="$(cat "/proc/$1/stat" 2>/dev/null)" || return 1
		line="${line##*) }"
		printf '%s\n' "${line%% *}"
	else
		ps -o stat= -p "$1" 2>/dev/null
	fi
}
until proc_state "${server}" | grep -q '^ *Z'; do
	n=$((n + 1))
	[ "${n}" -lt 50 ] || test_fail "server did not become a zombie"
	sleep 0.1
done

# The helpers must notice that the server is gone. Allow 10s for slow runners;
# fixed code takes about one flush interval.
n=0
while :; do
	alive=""
	for p in ${helpers}; do
		if kill -0 "${p}" 2>/dev/null; then alive="${alive} ${p}"; fi
	done
	[ -n "${alive}" ] || break
	n=$((n + 1))
	if [ "${n}" -ge 100 ]; then
		test_fail "helpers still running 10s after the server was killed (zombie, not reaped):${alive}"
	fi
	sleep 0.1
done
printf ' -> helpers exited within %s.%ss of the server being killed\n' "$((n / 10))" "$((n % 10))"

exec 7>&- 8<&-
