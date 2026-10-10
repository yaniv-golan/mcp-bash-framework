#!/usr/bin/env bash
# Integration: the cached staging tarball is rebuilt when the framework changes.
# shellcheck disable=SC2034  # Used by test runner for reporting.
TEST_DESC="Staging tarball cache key is recomputed from the source, not read back from the cache."

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../common/env.sh
# shellcheck disable=SC1091
. "${SCRIPT_DIR}/../common/env.sh"
# shellcheck source=../common/assert.sh
# shellcheck disable=SC1091
. "${SCRIPT_DIR}/../common/assert.sh"

test_create_tmpdir

# A cache left by an earlier run, built from different framework files.
MCPBASH_TAR_DIR="${TEST_TMPDIR}/staging"
MCPBASH_BASE_TAR="${MCPBASH_TAR_DIR}/base.tar"
MCPBASH_BASE_TAR_META="${MCPBASH_TAR_DIR}/base.tar.sha256"
mkdir -p "${MCPBASH_TAR_DIR}"
printf 'old tarball' >"${MCPBASH_BASE_TAR}"
printf 'stale-key' >"${MCPBASH_BASE_TAR_META}"
unset MCPBASH_BASE_TAR_KEY

key="$(test_compute_base_tar_key)"
if [ "${key}" = "stale-key" ]; then
	test_fail "cache key was read back from the stale cache instead of computed from ${MCPBASH_HOME}"
fi
if [ -z "${key}" ]; then
	test_fail "cache key is empty"
fi

# Within one process the computed key is reused, so it is computed once per run.
MCPBASH_BASE_TAR_KEY="${key}"
again="$(test_compute_base_tar_key)"
assert_eq "${key}" "${again}" "key reused within a run"

printf 'Staging cache key recomputed from source.\n'
