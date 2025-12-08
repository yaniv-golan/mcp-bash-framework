#!/usr/bin/env bash
# Unit layer: path normalization helpers (lib/path.sh).

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

# shellcheck source=test/common/env.sh
# shellcheck disable=SC1091
. "${REPO_ROOT}/test/common/env.sh"
# shellcheck source=test/common/assert.sh
# shellcheck disable=SC1091
. "${REPO_ROOT}/test/common/assert.sh"

# shellcheck source=lib/path.sh
# shellcheck disable=SC1091
. "${REPO_ROOT}/lib/path.sh"

test_create_tmpdir
cd "${TEST_TMPDIR}"
mkdir -p base/dir

printf ' -> collapses relative with dot-dot relative to PWD\n'
cd "${TEST_TMPDIR}/base/dir"
collapsed="$(mcp_path_collapse '../../..')"
expected_collapse="$(cd ../../.. && pwd)"
assert_eq "${expected_collapse}" "${collapsed}" "expected collapse to follow PWD"

printf ' -> normalize relative dot-dot to absolute path\n'
normalized="$(mcp_path_normalize "../dir")"
expected_norm="$(cd . && pwd -P)"
assert_eq "${expected_norm}" "${normalized}" "expected normalize to resolve relative path"

printf ' -> squashes multiple slashes\n'
raw_path="${TEST_TMPDIR}//base///dir//"
normalized_slash="$(mcp_path_normalize "${raw_path}")"
expected_slash="$(cd "${TEST_TMPDIR}/base/dir" && pwd -P)"
assert_eq "${expected_slash}" "${normalized_slash}" "expected multiple slashes to collapse"

printf ' -> collapses parent traversal components\n'
parent_path="${TEST_TMPDIR}/base/dir/../other"
normalized_parent="$(mcp_path_collapse "${parent_path}")"
expected_parent="${TEST_TMPDIR}/base/other"
assert_eq "${expected_parent}" "${normalized_parent}" "expected parent traversal to remove previous segment"

printf ' -> empty normalize resolves to PWD when resolver exists\n'
empty_norm="$(mcp_path_normalize '')"
assert_eq "$(pwd -P)" "${empty_norm}" "empty path should normalize to PWD"

printf ' -> normalizes msys-style drive letters to uppercase\n'
msys_path="/c/Users/Test"
normalized_drive="$(mcp_path_normalize "${msys_path}")"
assert_eq "/C/Users/Test" "${normalized_drive}" "expected drive letter to uppercase"

printf 'path normalization tests passed.\n'
