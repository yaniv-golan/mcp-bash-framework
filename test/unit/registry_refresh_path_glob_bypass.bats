#!/usr/bin/env bash
# Unit: regression for registry refresh path containment checks.
#
# mcp_registry_resolve_scan_root must treat paths literally (not as globs).
# Otherwise, a default dir like "default[1]" could wildcard-match "default1"
# and allow scanning outside the intended directory.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

# shellcheck source=test/common/env.sh
# shellcheck disable=SC1091
. "${REPO_ROOT}/test/common/env.sh"
# shellcheck source=test/common/assert.sh
# shellcheck disable=SC1091
. "${REPO_ROOT}/test/common/assert.sh"

# shellcheck source=lib/registry.sh
# shellcheck disable=SC1091
. "${REPO_ROOT}/lib/registry.sh"

test_create_tmpdir

DEFAULT_DIR="${TEST_TMPDIR}/default[1]"
OUTSIDE_DIR="${TEST_TMPDIR}/default1"
INSIDE_DIR="${DEFAULT_DIR}/sub"
mkdir -p "${DEFAULT_DIR}" "${OUTSIDE_DIR}" "${INSIDE_DIR}"

export MCPBASH_PROJECT_ROOT="${TEST_TMPDIR}"

printf ' -> rejects refresh path that only matches via glob metacharacters\n'
export MCPBASH_REGISTRY_REFRESH_PATH="default1"
resolved="$(mcp_registry_resolve_scan_root "${DEFAULT_DIR}")"
assert_eq "${DEFAULT_DIR}" "${resolved}" "expected refresh path outside default dir to be ignored"

printf ' -> accepts refresh path under default dir (literal containment)\n'
export MCPBASH_REGISTRY_REFRESH_PATH="default[1]/sub"
resolved_inside="$(mcp_registry_resolve_scan_root "${DEFAULT_DIR}")"
assert_eq "${INSIDE_DIR}" "${resolved_inside}" "expected refresh path under default dir to be accepted"

printf 'registry refresh path glob bypass regression passed.\n'

