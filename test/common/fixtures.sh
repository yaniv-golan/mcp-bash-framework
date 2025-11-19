#!/usr/bin/env bash
# Helpers for staging temporary workspaces (fixtures).

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

# shellcheck source=test/common/env.sh
# shellcheck disable=SC1091
. "${REPO_ROOT}/test/common/env.sh"
# shellcheck source=test/common/assert.sh
# shellcheck disable=SC1091
. "${REPO_ROOT}/test/common/assert.sh"

test_stage_example() {
	local example_id="$1"
	if [ -z "${example_id}" ]; then
		test_fail "example id required"
	fi
	test_create_tmpdir
	EXAMPLE_DIR="${MCPBASH_ROOT}/examples/${example_id}"
	if [ ! -d "${EXAMPLE_DIR}" ]; then
		test_fail "example ${example_id} not found"
	fi
	TMP_WORKDIR="$(mktemp -d "${TEST_TMPDIR}/example.XXXXXX")"
	cp -a "${MCPBASH_ROOT}/bin" "${TMP_WORKDIR}/"
	cp -a "${MCPBASH_ROOT}/lib" "${TMP_WORKDIR}/"
	cp -a "${MCPBASH_ROOT}/handlers" "${TMP_WORKDIR}/"
	cp -a "${MCPBASH_ROOT}/providers" "${TMP_WORKDIR}/"
	cp -a "${MCPBASH_ROOT}/sdk" "${TMP_WORKDIR}/"
	cp -a "${MCPBASH_ROOT}/resources" "${TMP_WORKDIR}/" 2>/dev/null || true
	cp -a "${MCPBASH_ROOT}/tools" "${TMP_WORKDIR}/" 2>/dev/null || true
	cp -a "${MCPBASH_ROOT}/prompts" "${TMP_WORKDIR}/" 2>/dev/null || true
	cp -a "${EXAMPLE_DIR}/"* "${TMP_WORKDIR}/" 2>/dev/null || true
	# shellcheck disable=SC2034
	MCP_TEST_WORKDIR="${TMP_WORKDIR}"
}
