#!/usr/bin/env bash
# Integration: auto minimal fallback when jq/gojq unavailable.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../common/env.sh
# shellcheck disable=SC1091
. "${SCRIPT_DIR}/../common/env.sh"
# shellcheck source=../common/assert.sh
# shellcheck disable=SC1091
. "${SCRIPT_DIR}/../common/assert.sh"

test_create_tmpdir
WORKSPACE="${TEST_TMPDIR}/minimal-auto"
test_stage_workspace "${WORKSPACE}"

if command -v gojq >/dev/null 2>&1 || command -v jq >/dev/null 2>&1; then
	printf 'SKIP: jq/gojq available on PATH; auto-minimal fallback not triggered.\n'
	exit 0
fi

cat <<'JSON' >"${WORKSPACE}/requests.ndjson"
{"jsonrpc":"2.0","id":"init","method":"initialize","params":{}}
{"jsonrpc":"2.0","id":"log","method":"logging/setLevel","params":{"level":"DEBUG"}}
JSON

(
	cd "${WORKSPACE}" || exit 1
	PATH="/usr/bin:/bin" MCPBASH_PROJECT_ROOT="${WORKSPACE}" ./bin/mcp-bash <"${WORKSPACE}/requests.ndjson" >"${WORKSPACE}/responses.ndjson"
) || true

init_caps="$(jq -c 'select(.id=="init") | .result.capabilities // empty' "${WORKSPACE}/responses.ndjson")"
if [ "${init_caps}" != '{"logging":{}}' ]; then
	test_fail "expected logging-only capabilities when jq/gojq missing, got ${init_caps}"
fi

log_code="$(jq -r 'select(.id=="log") | .error.code // empty' "${WORKSPACE}/responses.ndjson")"
if [ "${log_code}" != "-32602" ]; then
	test_fail "invalid log level should be rejected in minimal auto mode"
fi

printf 'Minimal auto-detection tests passed.\n'
