#!/usr/bin/env bash
# Integration: concurrent servers sharing one temp root each get a private
# state dir, ignore names planted at the old predictable paths, and clean up.
# shellcheck disable=SC2034  # Used by test runner for reporting.
TEST_DESC="Concurrent servers use private runtime dirs and leave nothing behind."

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
WORKSPACE="${TEST_TMPDIR}/workspace"
test_stage_workspace "${WORKSPACE}"
cp -a "${MCPBASH_HOME}/examples/00-hello-tool/." "${WORKSPACE}/"

SHARED_TMP="${TEST_TMPDIR}/shared-tmp"
VICTIM="${TEST_TMPDIR}/victim"
mkdir -p "${SHARED_TMP}" "${VICTIM}"

# What another local user could plant at the old fixed names.
ln -s "${VICTIM}" "${SHARED_TMP}/mcpbash.locks"
mkdir -p "${SHARED_TMP}/mcpbash.state.planted"

cat <<'JSON' >"${WORKSPACE}/requests.ndjson"
{"jsonrpc":"2.0","id":"init","method":"initialize","params":{}}
{"jsonrpc":"2.0","method":"notifications/initialized"}
{"jsonrpc":"2.0","id":"call","method":"tools/call","params":{"name":"hello","arguments":{}}}
JSON

SERVERS=4
pids=""
for i in $(seq 1 "${SERVERS}"); do
	(
		cd "${WORKSPACE}" || exit 1
		# Clear the debug-retention switches CI jobs set: they keep state dirs on purpose.
		env -u MCPBASH_TMP_ROOT -u MCPBASH_STATE_DIR -u MCPBASH_LOCK_ROOT \
			-u MCPBASH_KEEP_LOGS -u MCPBASH_PRESERVE_STATE -u MCPBASH_LOG_DIR \
			TMPDIR="${SHARED_TMP}" MCPBASH_PROJECT_ROOT="${WORKSPACE}" \
			./bin/mcp-bash <"${WORKSPACE}/requests.ndjson" >"${WORKSPACE}/responses.${i}.ndjson" 2>"${WORKSPACE}/stderr.${i}.log"
	) &
	pids="${pids} $!"
done
for pid in ${pids}; do
	wait "${pid}" || test_fail "a server exited non-zero"
done

for i in $(seq 1 "${SERVERS}"); do
	out="${WORKSPACE}/responses.${i}.ndjson"
	if ! jq -e 'select(.id=="call") | .result.isError != true' "${out}" >/dev/null; then
		test_fail "server ${i}: tools/call failed: $(cat "${out}") $(cat "${WORKSPACE}/stderr.${i}.log")"
	fi
done

if [ -n "$(ls -A "${VICTIM}")" ]; then
	test_fail "something was written through the planted symlink: $(ls -A "${VICTIM}")"
fi

leftover="$(find "${SHARED_TMP}" -mindepth 1 -maxdepth 1 ! -name 'mcpbash.locks' ! -name 'mcpbash.state.planted' -exec basename {} \; || true)"
if [ -n "${leftover}" ]; then
	test_fail "servers left runtime dirs behind: ${leftover}"
fi

printf 'Runtime dirs concurrency test passed.\n'
