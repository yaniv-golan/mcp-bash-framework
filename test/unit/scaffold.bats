#!/usr/bin/env bash
# Unit layer: scaffold outputs canonical tool files.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

# shellcheck source=test/common/env.sh
# shellcheck disable=SC1091
. "${REPO_ROOT}/test/common/env.sh"
# shellcheck source=test/common/assert.sh
# shellcheck disable=SC1091
. "${REPO_ROOT}/test/common/assert.sh"

test_require_command jq

test_create_tmpdir
PROJECT_ROOT="${TEST_TMPDIR}/proj"
mkdir -p "${PROJECT_ROOT}"
export MCPBASH_PROJECT_ROOT="${PROJECT_ROOT}"

printf ' -> scaffold tool\n'
"${REPO_ROOT}/bin/mcp-bash" scaffold tool hello >/dev/null
assert_file_exists "${PROJECT_ROOT}/tools/hello/tool.sh"
assert_file_exists "${PROJECT_ROOT}/tools/hello/tool.meta.json"
assert_file_exists "${PROJECT_ROOT}/tools/hello/README.md"

if ! jq -e '.name == "hello"' "${PROJECT_ROOT}/tools/hello/tool.meta.json" >/dev/null; then
	test_fail "tool.meta.json does not contain expected tool name"
fi

printf ' -> scaffold prompt\n'
"${REPO_ROOT}/bin/mcp-bash" scaffold prompt welcome >/dev/null
assert_file_exists "${PROJECT_ROOT}/prompts/welcome/welcome.txt"
assert_file_exists "${PROJECT_ROOT}/prompts/welcome/welcome.meta.json"
assert_file_exists "${PROJECT_ROOT}/prompts/welcome/README.md"

if ! jq -e '.name == "prompt.welcome"' "${PROJECT_ROOT}/prompts/welcome/welcome.meta.json" >/dev/null; then
	test_fail "prompt.meta.json does not contain expected prompt name"
fi

printf ' -> scaffold resource\n'
"${REPO_ROOT}/bin/mcp-bash" scaffold resource sample >/dev/null
assert_file_exists "${PROJECT_ROOT}/resources/sample/sample.txt"
assert_file_exists "${PROJECT_ROOT}/resources/sample/sample.meta.json"
assert_file_exists "${PROJECT_ROOT}/resources/sample/README.md"

if ! jq -e '.name == "resource.sample"' "${PROJECT_ROOT}/resources/sample/sample.meta.json" >/dev/null; then
	test_fail "resource.meta.json does not contain expected resource name"
fi
resource_uri="$(jq -r '.uri // ""' "${PROJECT_ROOT}/resources/sample/sample.meta.json")"
case "${resource_uri}" in
file://*)
	;;
*)
	test_fail "resource URI not file:// prefixed: ${resource_uri}"
	;;
esac

printf 'Scaffold test passed.\n'
