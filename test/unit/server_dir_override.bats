#!/usr/bin/env bats
# Unit layer: doctor, run-tool and validate honour MCPBASH_SERVER_DIR (the
# runtime already does). Labels in output stay relative to the project.

load '../../node_modules/bats-support/load'
load '../../node_modules/bats-assert/load'
load '../common/fixtures'
load '../common/ndjson'

setup() {
	[ -n "${TEST_JSON_TOOL_BIN:-}" ] || skip "jq/gojq required"
	PROJECT_ROOT="${BATS_TEST_TMPDIR}/proj"
	CUSTOM_DIR="${PROJECT_ROOT}/config.d"
	mkdir -p "${PROJECT_ROOT}/tools/echo-env" "${CUSTOM_DIR}"
	export MCPBASH_PROJECT_ROOT="${PROJECT_ROOT}"
	export MCPBASH_SERVER_DIR="${CUSTOM_DIR}"

	printf '%s\n' '{"name":"custom-dir","env":{"MCPBASH_TOOL_ENV_MODE":"allowlist","MCPBASH_TOOL_ENV_ALLOWLIST":"SENTINEL_KEY"}}' >"${CUSTOM_DIR}/server.meta.json"
	printf '%s\n' 'export MCPBASH_TEST_FROM_SERVER_ENV="from-custom-dir"' >"${CUSTOM_DIR}/env.sh"

	printf '%s\n' '{"name":"echo-env","description":"Echo env","inputSchema":{"type":"object"}}' >"${PROJECT_ROOT}/tools/echo-env/tool.meta.json"
	cat >"${PROJECT_ROOT}/tools/echo-env/tool.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
source "${MCP_SDK}/tool-sdk.sh"
mcp_emit_json "$(mcp_json_obj message "FROM=${MCPBASH_TEST_FROM_SERVER_ENV:-not-set}")"
EOF
	chmod +x "${PROJECT_ROOT}/tools/echo-env/tool.sh"
}

@test "server dir: doctor finds server.meta.json and the env policy in a custom dir" {
	cd "${PROJECT_ROOT}"
	SENTINEL_KEY="sk-sentinel-secret-value" run "${MCPBASH_HOME}/bin/mcp-bash" doctor
	assert_contains "config.d/server.meta.json: valid" "${output}"
	assert_contains "SENTINEL_KEY: set" "${output}"
	assert_contains "(from server.meta.json)" "${output}"
	if printf '%s' "${output}" | grep -q "server.d/server.meta.json"; then
		printf 'doctor still reports server.d: %s\n' "${output}" >&2
		return 1
	fi
	if printf '%s' "${output}" | grep -q "sk-sentinel-secret-value"; then
		return 1
	fi
}

@test "server dir: doctor --json reports the custom dir's meta as valid" {
	cd "${PROJECT_ROOT}"
	run "${MCPBASH_HOME}/bin/mcp-bash" doctor --json
	printf '%s' "${output}" | jq -e '.project.serverMetaValid == true' >/dev/null
}

@test "server dir: run-tool --with-server-env sources env.sh from the custom dir" {
	run "${MCPBASH_HOME}/bin/mcp-bash" run-tool echo-env --with-server-env
	assert_success
	assert_output --partial "FROM=from-custom-dir"
}

@test "server dir: run-tool --print-env names the custom env.sh" {
	run "${MCPBASH_HOME}/bin/mcp-bash" run-tool echo-env --with-server-env --print-env
	assert_success
	assert_output --partial "WILL_SOURCE_SERVER_ENV="
	assert_output --partial "config.d/env.sh"
	refute_output --partial "not found"
}

@test "server dir: validate validates the custom dir with relative labels" {
	run "${MCPBASH_HOME}/bin/mcp-bash" validate
	assert_output --partial "config.d/server.meta.json - valid"
	refute_output --partial "server.d/server.meta.json"
}

@test "server dir: validate reports an invalid server.meta.json in the custom dir" {
	printf '%s\n' '{not json' >"${CUSTOM_DIR}/server.meta.json"
	run "${MCPBASH_HOME}/bin/mcp-bash" validate
	assert_failure
	assert_output --partial "config.d/server.meta.json - invalid JSON"
}
