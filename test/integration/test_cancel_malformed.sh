#!/usr/bin/env bash
# Integration: a malformed or unsupported notifications/cancelled is ignored.
# shellcheck disable=SC2034  # Used by test runner for reporting.
TEST_DESC="Malformed cancel notifications are ignored; the server keeps answering."

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../common/env.sh
# shellcheck disable=SC1091
. "${SCRIPT_DIR}/../common/env.sh"
# shellcheck source=../common/assert.sh
# shellcheck disable=SC1091
. "${SCRIPT_DIR}/../common/assert.sh"

test_require_command jq

test_create_tmpdir
WS="${TEST_TMPDIR}/ws"
test_stage_workspace "${WS}"

INIT='{"jsonrpc":"2.0","id":"init","method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{}}}'
INITIALIZED='{"jsonrpc":"2.0","method":"notifications/initialized"}'
PING='{"jsonrpc":"2.0","id":"ping","method":"ping"}'

# Notifications get no response, so the only acceptable outcome for a cancel
# the server cannot use is to drop it and keep serving.
FAILURES=""
run_case() {
	local shell_bin="$1" label="$2" cancel="$3" mode_env="$4"
	local out="${TEST_TMPDIR}/out.$$.${RANDOM}"
	local rc=0 problem=""
	printf '%s\n' "${INIT}" "${INITIALIZED}" "${cancel}" "${PING}" \
		| (cd "${WS}" && env "${mode_env}" MCPBASH_PROJECT_ROOT="${WS}" "${shell_bin}" ./bin/mcp-bash >"${out}" 2>/dev/null) || rc=$?
	if ! jq -e -s 'any(.[]; .id == "ping" and .result == {})' "${out}" >/dev/null 2>&1; then
		problem="no ping response after the cancel"
	elif jq -e -s 'any(.[]; has("id") and .id == null)' "${out}" >/dev/null 2>&1; then
		problem="a response was sent for the cancel notification"
	elif [ "${rc}" -ne 0 ]; then
		problem="server exited with status ${rc}"
	fi
	rm -f "${out}"
	if [ -n "${problem}" ]; then
		printf '  %s %s: FAIL (%s; server rc=%s)\n' "${shell_bin}" "${label}" "${problem}" "${rc}"
		FAILURES="${FAILURES}${shell_bin} ${label}; "
		return 0
	fi
	printf '  %s %s: ok\n' "${shell_bin}" "${label}"
}

shells="bash"
if [ -x /bin/bash ] && [ "$(/bin/bash -c 'echo ${BASH_VERSINFO[0]}')" != "$(bash -c 'echo ${BASH_VERSINFO[0]}')" ]; then
	shells="bash /bin/bash"
fi

for shell_bin in ${shells}; do
	printf '%s (%s):\n' "${shell_bin}" "$("${shell_bin}" -c 'echo ${BASH_VERSION}')"
	run_case "${shell_bin}" "params {}" '{"jsonrpc":"2.0","method":"notifications/cancelled","params":{}}' MCPBASH_FORCE_MINIMAL=false
	run_case "${shell_bin}" "no params" '{"jsonrpc":"2.0","method":"notifications/cancelled"}' MCPBASH_FORCE_MINIMAL=false
	run_case "${shell_bin}" "requestId null" '{"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":null}}' MCPBASH_FORCE_MINIMAL=false
	run_case "${shell_bin}" "requestId false" '{"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":false}}' MCPBASH_FORCE_MINIMAL=false
	run_case "${shell_bin}" "params string" '{"jsonrpc":"2.0","method":"notifications/cancelled","params":"x"}' MCPBASH_FORCE_MINIMAL=false
	run_case "${shell_bin}" "unknown requestId" '{"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":5}}' MCPBASH_FORCE_MINIMAL=false
	# Minimal mode (no JSON tool) cannot extract the id at all.
	run_case "${shell_bin}" "minimal mode" '{"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":5}}' MCPBASH_FORCE_MINIMAL=true
done

if [ -n "${FAILURES}" ]; then
	test_fail "a cancel notification the server cannot use stopped it: ${FAILURES}"
fi
printf 'Malformed cancel test passed.\n'
