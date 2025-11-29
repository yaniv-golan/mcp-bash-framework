#!/usr/bin/env bash
# Integration: resource provider safety and allowlist enforcement.
TEST_DESC="Resource provider allowlist denies outside roots."

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
WORKSPACE="${TEST_TMPDIR}/resources-providers"
test_stage_workspace "${WORKSPACE}"

# Create a file outside the workspace to trigger allowlist denial.
OUTSIDE_FILE="$(mktemp /tmp/mcpbash.outside.XXXXXX)"
echo "outside" >"${OUTSIDE_FILE}"
OUTSIDE_URI="file://${OUTSIDE_FILE}"

# Create a resource that points outside allowed roots to trigger denial.
mkdir -p "${WORKSPACE}/resources"
cat <<EOF_META >"${WORKSPACE}/resources/outside.meta.json"
{"name": "bad.outside", "description": "Outside project", "uri": "${OUTSIDE_URI}", "mimeType": "text/plain"}
EOF_META

cat <<'JSON' >"${WORKSPACE}/requests.ndjson"
{"jsonrpc":"2.0","id":"init","method":"initialize","params":{}}
{"jsonrpc":"2.0","method":"notifications/initialized"}
{"jsonrpc":"2.0","id":"read","method":"resources/read","params":{"name":"","uri":"__OUTSIDE__"}}
{"jsonrpc":"2.0","id":"shutdown","method":"shutdown"}
{"jsonrpc":"2.0","id":"exit","method":"exit"}
JSON
OUTSIDE_ESC="${OUTSIDE_URI//\//\\/}"
sed "s|__OUTSIDE__|${OUTSIDE_ESC}|" "${WORKSPACE}/requests.ndjson" >"${WORKSPACE}/requests.subst.ndjson"
mv "${WORKSPACE}/requests.subst.ndjson" "${WORKSPACE}/requests.ndjson"

test_run_mcp "${WORKSPACE}" "${WORKSPACE}/requests.ndjson" "${WORKSPACE}/responses.ndjson"
assert_json_lines "${WORKSPACE}/responses.ndjson"
cp "${WORKSPACE}/responses.ndjson" /tmp/resources-providers-debug.ndjson 2>/dev/null || true

code="$(jq -r 'select(.id=="read") | .error.code // empty' "${WORKSPACE}/responses.ndjson")"
message="$(jq -r 'select(.id=="read") | .error.message // empty' "${WORKSPACE}/responses.ndjson")"
test_assert_eq "${code}" "-32603"
if [ -z "${message}" ]; then
	test_fail "expected error message for outside resource"
fi

printf 'Resource provider safety tests passed.\n'
