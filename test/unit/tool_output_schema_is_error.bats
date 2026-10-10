#!/usr/bin/env bats
# Unit layer: outputSchema validation skips error results (isError: true).

load '../../node_modules/bats-support/load'
load '../../node_modules/bats-assert/load'
load '../common/fixtures'

setup() {
	PROJECT_ROOT="${BATS_TEST_TMPDIR}/proj"
	export MCPBASH_PROJECT_ROOT="${PROJECT_ROOT}"
	mkdir -p "${PROJECT_ROOT}/tools/refuse" "${PROJECT_ROOT}/tools/badok" "${PROJECT_ROOT}/server.d"
	printf '%s\n' '{"name":"schema-iserror"}' >"${PROJECT_ROOT}/server.d/server.meta.json"

	local schema='"outputSchema":{"type":"object","required":["path"],"properties":{"path":{"type":"string"}}}'
	printf '{"name":"refuse","description":"d","inputSchema":{"type":"object"},%s}\n' "${schema}" >"${PROJECT_ROOT}/tools/refuse/tool.meta.json"
	cat >"${PROJECT_ROOT}/tools/refuse/tool.sh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
source "${MCP_SDK}/tool-sdk.sh"
mcp_result_error "$(mcp_json_obj type "refused" message "Output file exists")"
SH
	printf '{"name":"badok","description":"d","inputSchema":{"type":"object"},%s}\n' "${schema}" >"${PROJECT_ROOT}/tools/badok/tool.meta.json"
	cat >"${PROJECT_ROOT}/tools/badok/tool.sh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
source "${MCP_SDK}/tool-sdk.sh"
mcp_emit_json '{"other":1}'
SH
	chmod +x "${PROJECT_ROOT}/tools/refuse/tool.sh" "${PROJECT_ROOT}/tools/badok/tool.sh"
}

@test "output_schema: an isError result is returned as is, not checked against outputSchema" {
	run "${MCPBASH_HOME}/bin/mcp-bash" run-tool refuse --allow-self
	assert_output --partial '"isError":true'
	assert_output --partial 'Output file exists'
	refute_output --partial 'does not satisfy outputSchema'
}

@test "output_schema: a successful result that breaks outputSchema is still refused" {
	run "${MCPBASH_HOME}/bin/mcp-bash" run-tool badok --allow-self
	assert_output --partial 'does not satisfy outputSchema'
}
