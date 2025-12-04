#!/usr/bin/env bash
# Integration: init/scaffold edge cases.
# shellcheck disable=SC2034  # Used by test runner for reporting.
TEST_DESC="CLI init and scaffold server handle edge cases."

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

printf ' -> init --no-hello does not create hello tool\n'
NO_HELLO_ROOT="${TEST_TMPDIR}/no-hello"
mkdir -p "${NO_HELLO_ROOT}"
(
	cd "${NO_HELLO_ROOT}" || exit 1
	"${MCPBASH_TEST_ROOT}/bin/mcp-bash" init --name no-hello --no-hello >/dev/null
)

assert_file_exists "${NO_HELLO_ROOT}/server.d/server.meta.json"
assert_file_exists "${NO_HELLO_ROOT}/.gitignore"
if [ -d "${NO_HELLO_ROOT}/tools/hello" ]; then
	test_fail "init --no-hello should not create tools/hello"
fi

printf ' -> init in partially-initialized directory preserves server meta and updates gitignore\n'
PARTIAL_ROOT="${TEST_TMPDIR}/partial"
mkdir -p "${PARTIAL_ROOT}/server.d"
cat >"${PARTIAL_ROOT}/server.d/server.meta.json" <<'META'
{
  "name": "existing-server",
  "title": "Existing Server"
}
META

cat >"${PARTIAL_ROOT}/.gitignore" <<'EOF'
# Existing entries
node_modules/
.registry/
EOF

(
	cd "${PARTIAL_ROOT}" || exit 1
	"${MCPBASH_TEST_ROOT}/bin/mcp-bash" init >/dev/null
)

if ! jq -e '.name == "existing-server"' "${PARTIAL_ROOT}/server.d/server.meta.json" >/dev/null; then
	test_fail "init overwrote existing server.meta.json"
fi

gitignore="${PARTIAL_ROOT}/.gitignore"
count_registry="$(grep -c '\.registry/' "${gitignore}")"
count_logs="$(grep -c '\*\.log' "${gitignore}")"
count_dsstore="$(grep -c '\.DS_Store' "${gitignore}")"
count_thumbs="$(grep -c 'Thumbs\.db' "${gitignore}")"

assert_eq "1" "${count_registry}" ".gitignore should contain .registry/ once"
assert_eq "1" "${count_logs}" ".gitignore should contain *.log once"
assert_eq "1" "${count_dsstore}" ".gitignore should contain .DS_Store once"
assert_eq "1" "${count_thumbs}" ".gitignore should contain Thumbs.db once"

printf ' -> scaffold server <name> creates project skeleton\n'
SERVER_PARENT="${TEST_TMPDIR}/servers"
mkdir -p "${SERVER_PARENT}"
(
	cd "${SERVER_PARENT}" || exit 1
	"${MCPBASH_TEST_ROOT}/bin/mcp-bash" scaffold server demo >/dev/null
)

DEMO_ROOT="${SERVER_PARENT}/demo"
assert_file_exists "${DEMO_ROOT}/server.d/server.meta.json"
assert_file_exists "${DEMO_ROOT}/.gitignore"
assert_file_exists "${DEMO_ROOT}/tools/hello/tool.sh"

if ! jq -e '.name == "demo"' "${DEMO_ROOT}/server.d/server.meta.json" >/dev/null; then
	test_fail "scaffold server did not set expected server name"
fi

printf ' -> scaffold server fails when target exists\n'
mkdir -p "${SERVER_PARENT}/existing"
set +e
existing_output="$(
	cd "${SERVER_PARENT}" && "${MCPBASH_TEST_ROOT}/bin/mcp-bash" scaffold server existing 2>&1
)"
status=$?
set -e

if [ "${status}" -eq 0 ]; then
	test_fail "scaffold server succeeded despite existing target directory"
fi
assert_contains "already exists" "${existing_output}" "scaffold server did not report existing target"
printf 'CLI init/scaffold server test passed.\n'
