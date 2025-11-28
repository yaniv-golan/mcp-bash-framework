#!/usr/bin/env bash
# Unit layer: validate lock helpers from lib/lock.sh.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

# shellcheck source=test/common/env.sh
# shellcheck disable=SC1091
. "${REPO_ROOT}/test/common/env.sh"
# shellcheck source=test/common/assert.sh
# shellcheck disable=SC1091
. "${REPO_ROOT}/test/common/assert.sh"

# shellcheck source=lib/runtime.sh
# shellcheck disable=SC1091
. "${REPO_ROOT}/lib/runtime.sh"
# shellcheck source=lib/lock.sh
# shellcheck disable=SC1091
. "${REPO_ROOT}/lib/lock.sh"

test_create_tmpdir
MCPBASH_TMP_ROOT="${TEST_TMPDIR}"
# Unit tests require a project root; point it at the temp workspace.
export MCPBASH_PROJECT_ROOT="${TEST_TMPDIR}"
mcp_runtime_init_paths

printf ' -> lock initialization\n'
MCPBASH_LOCK_ROOT="${TEST_TMPDIR}/locks"
mcp_lock_init
assert_eq "${TEST_TMPDIR}/locks" "${MCPBASH_LOCK_ROOT}"

printf ' -> acquire/release cycle\n'
mcp_lock_acquire "unit"
assert_file_exists "${MCPBASH_LOCK_ROOT}/unit.lock/pid"
mcp_lock_release "unit"
if [ -d "${MCPBASH_LOCK_ROOT}/unit.lock" ]; then
	test_fail "lock directory not removed after release"
fi

printf ' -> reap stale owner\n'
mkdir -p "${MCPBASH_LOCK_ROOT}/stale.lock"
printf '%s' "999999" >"${MCPBASH_LOCK_ROOT}/stale.lock/pid"
mcp_lock_acquire "stale"
assert_file_exists "${MCPBASH_LOCK_ROOT}/stale.lock/pid"
mcp_lock_release "stale"

printf ' -> grace period for pid creation\n'
MCPBASH_LOCK_REAP_GRACE_SECS=5
mkdir -p "${MCPBASH_LOCK_ROOT}/grace.lock"
mcp_lock_try_reap "${MCPBASH_LOCK_ROOT}/grace.lock"
if [ ! -d "${MCPBASH_LOCK_ROOT}/grace.lock" ]; then
	test_fail "lock reaped during grace window"
fi
MCPBASH_LOCK_REAP_GRACE_SECS=0
mcp_lock_try_reap "${MCPBASH_LOCK_ROOT}/grace.lock"
if [ -d "${MCPBASH_LOCK_ROOT}/grace.lock" ]; then
	test_fail "stale lock without pid not reaped after grace"
fi

printf 'All lock tests passed.\n'
