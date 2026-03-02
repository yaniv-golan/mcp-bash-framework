#!/usr/bin/env bash
# shellcheck disable=SC2034  # Used by test runner for reporting.
TEST_DESC="Initialize response includes instructions for 2025-03-26+ only."
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../common/env.sh
# shellcheck disable=SC1091
. "${SCRIPT_DIR}/../common/env.sh"
# shellcheck source=../common/assert.sh
# shellcheck disable=SC1091
. "${SCRIPT_DIR}/../common/assert.sh"

test_create_tmpdir
WORKSPACE="${TEST_TMPDIR}/workspace"
test_stage_workspace "${WORKSPACE}"

mkdir -p "${WORKSPACE}/tools/hello"
cp -a "${MCPBASH_HOME}/examples/00-hello-tool/server.d/server.meta.json" "${WORKSPACE}/server.d/server.meta.json"
cp -a "${MCPBASH_HOME}/examples/00-hello-tool/tools/hello/tool.meta.json" "${WORKSPACE}/tools/hello/tool.meta.json"
cp -a "${MCPBASH_HOME}/examples/00-hello-tool/tools/hello/tool.sh" "${WORKSPACE}/tools/hello/tool.sh"
chmod +x "${WORKSPACE}/tools/hello/tool.sh"

cat >"${WORKSPACE}/server.d/server.instructions.md" <<'EOF'
Always prefer the hello tool for basic connectivity checks.
If a user asks for diagnostics, run tools/list first.
EOF

run_server() {
	local workdir="$1"
	local request_file="$2"
	local response_file="$3"
	(
		cd "${workdir}" || exit 1
		MCPBASH_PROJECT_ROOT="${workdir}" ./bin/mcp-bash <"${request_file}" >"${response_file}"
	)
}

cat >"${WORKSPACE}/requests-default.ndjson" <<'JSON'
{"jsonrpc":"2.0","id":"init-default","method":"initialize","params":{}}
{"jsonrpc":"2.0","method":"notifications/initialized"}
JSON
run_server "${WORKSPACE}" "${WORKSPACE}/requests-default.ndjson" "${WORKSPACE}/responses-default.ndjson"

if ! jq -e '
	select(.id=="init-default") |
	(.result.protocolVersion == "2025-11-25") and
	(.result.instructions | type == "string") and
	(.result.instructions | contains("Always prefer the hello tool"))
' "${WORKSPACE}/responses-default.ndjson" >/dev/null; then
	test_fail "default initialize must include instructions for latest protocol"
fi

cat >"${WORKSPACE}/requests-20250326.ndjson" <<'JSON'
{"jsonrpc":"2.0","id":"init-20250326","method":"initialize","params":{"protocolVersion":"2025-03-26"}}
{"jsonrpc":"2.0","method":"notifications/initialized"}
JSON
run_server "${WORKSPACE}" "${WORKSPACE}/requests-20250326.ndjson" "${WORKSPACE}/responses-20250326.ndjson"

if ! jq -e '
	select(.id=="init-20250326") |
	(.result.protocolVersion == "2025-03-26") and
	(.result.instructions | type == "string")
' "${WORKSPACE}/responses-20250326.ndjson" >/dev/null; then
	test_fail "initialize must include instructions for protocol 2025-03-26"
fi

cat >"${WORKSPACE}/requests-20241105.ndjson" <<'JSON'
{"jsonrpc":"2.0","id":"init-20241105","method":"initialize","params":{"protocolVersion":"2024-11-05"}}
{"jsonrpc":"2.0","method":"notifications/initialized"}
JSON
run_server "${WORKSPACE}" "${WORKSPACE}/requests-20241105.ndjson" "${WORKSPACE}/responses-20241105.ndjson"

if ! jq -e '
	select(.id=="init-20241105") |
	(.result.protocolVersion == "2024-11-05") and
	(.result | has("instructions") | not)
' "${WORKSPACE}/responses-20241105.ndjson" >/dev/null; then
	test_fail "initialize must omit instructions for protocol 2024-11-05"
fi
