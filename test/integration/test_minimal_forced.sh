#!/usr/bin/env bash
# Integration: forced minimal mode (even when jq/gojq are available).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../common/env.sh
# shellcheck disable=SC1091
. "${SCRIPT_DIR}/../common/env.sh"
# shellcheck source=../common/assert.sh
# shellcheck disable=SC1091
. "${SCRIPT_DIR}/../common/assert.sh"

test_create_tmpdir
WORKSPACE="${TEST_TMPDIR}/minimal-forced"
test_stage_workspace "${WORKSPACE}"

cat <<'JSON' >"${WORKSPACE}/requests.ndjson"
{"jsonrpc":"2.0","id":"init","method":"initialize","params":{}}
{"jsonrpc":"2.0","method":"notifications/initialized"}
{"jsonrpc":"2.0","id":"log","method":"logging/setLevel","params":{"level":"INVALID"}}
JSON

(
	cd "${WORKSPACE}" || exit 1
	# Force minimal mode even if jq/gojq are available on PATH.
	MCPBASH_FORCE_MINIMAL=true PATH="/usr/bin:/bin" MCPBASH_PROJECT_ROOT="${WORKSPACE}" ./bin/mcp-bash <"${WORKSPACE}/requests.ndjson" >"${WORKSPACE}/responses.ndjson"
) || true

init_caps="$(jq -c 'select(.id=="init") | .result.capabilities // empty' "${WORKSPACE}/responses.ndjson")"
if [ "${init_caps}" != '{"logging":{}}' ]; then
	test_fail "expected logging-only capabilities when forced minimal, got ${init_caps}"
fi

log_code="$(jq -r 'select(.id=="log") | .error.code // empty' "${WORKSPACE}/responses.ndjson")"
if [ "${log_code}" != "-32602" ]; then
	test_fail "invalid log level should be rejected in forced minimal mode"
fi

printf 'Forced minimal mode tests passed.\n'
