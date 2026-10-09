#!/usr/bin/env bats
# Unit layer: declarative env policy from server.meta.json (lib/meta_env.sh).

load '../../node_modules/bats-support/load'
load '../../node_modules/bats-assert/load'
load '../common/fixtures'

setup() {
	# shellcheck source=lib/meta_env.sh
	# shellcheck disable=SC1091
	. "${MCPBASH_HOME}/lib/meta_env.sh"
	export MCPBASH_SERVER_DIR="${BATS_TEST_TMPDIR}/server.d"
	mkdir -p "${MCPBASH_SERVER_DIR}"
	export MCPBASH_JSON_TOOL="${MCPBASH_JSON_TOOL:-jq}"
	export MCPBASH_JSON_TOOL_BIN="${MCPBASH_JSON_TOOL_BIN:-$(command -v jq)}"
	unset MCPBASH_TOOL_ENV_MODE MCPBASH_TOOL_ENV_ALLOWLIST MCPBASH_PROVIDER_ENV_MODE MCPBASH_PROVIDER_ENV_ALLOWLIST MCPBASH_IGNORE_META_ENV
}

write_meta() {
	printf '%s\n' "$1" >"${MCPBASH_SERVER_DIR}/server.meta.json"
}

@test "meta_env: applies all four policy keys when the launch env is silent" {
	write_meta '{"name":"t","env":{"MCPBASH_TOOL_ENV_MODE":"allowlist","MCPBASH_TOOL_ENV_ALLOWLIST":"API_KEY, OTHER","MCPBASH_PROVIDER_ENV_MODE":"allowlist","MCPBASH_PROVIDER_ENV_ALLOWLIST":"API_KEY"}}'
	mcp_meta_env_apply
	assert_equal "${MCPBASH_TOOL_ENV_MODE}" "allowlist"
	assert_equal "${MCPBASH_TOOL_ENV_ALLOWLIST}" "API_KEY,OTHER"
	assert_equal "${MCPBASH_PROVIDER_ENV_MODE}" "allowlist"
	assert_equal "${MCPBASH_PROVIDER_ENV_ALLOWLIST}" "API_KEY"
}

@test "meta_env: launch env setting either key of a scope blocks both meta keys for that scope" {
	write_meta '{"env":{"MCPBASH_TOOL_ENV_MODE":"allowlist","MCPBASH_TOOL_ENV_ALLOWLIST":"API_KEY","MCPBASH_PROVIDER_ENV_MODE":"allowlist"}}'
	export MCPBASH_TOOL_ENV_ALLOWLIST="FOO"
	mcp_meta_env_apply
	assert_equal "${MCPBASH_TOOL_ENV_ALLOWLIST}" "FOO"
	assert_equal "${MCPBASH_TOOL_ENV_MODE:-unset}" "unset"
	assert_equal "${MCPBASH_PROVIDER_ENV_MODE}" "allowlist"
}

@test "meta_env: empty or unexpanded-placeholder launch values count as unset" {
	write_meta '{"env":{"MCPBASH_TOOL_ENV_MODE":"allowlist","MCPBASH_PROVIDER_ENV_MODE":"allowlist"}}'
	export MCPBASH_TOOL_ENV_MODE=""
	export MCPBASH_PROVIDER_ENV_MODE='${user_config.mode}'
	mcp_meta_env_apply
	assert_equal "${MCPBASH_TOOL_ENV_MODE}" "allowlist"
	assert_equal "${MCPBASH_PROVIDER_ENV_MODE}" "allowlist"
}

@test "meta_env: refuses operator opt-ins and arbitrary keys without printing values" {
	write_meta '{"env":{"MCPBASH_TOOL_ENV_INHERIT_ALLOW":"true","AFFINITY_API_KEY":"sk-sentinel-123","MCPBASH_TOOL_ENV_MODE":"allowlist"}}'
	run mcp_meta_env_apply
	assert_success
	assert_output --partial "ignoring MCPBASH_TOOL_ENV_INHERIT_ALLOW"
	assert_output --partial "ignoring AFFINITY_API_KEY"
	refute_output --partial "sk-sentinel-123"
	mcp_meta_env_apply 2>/dev/null
	assert_equal "${MCPBASH_TOOL_ENV_INHERIT_ALLOW:-unset}" "unset"
	assert_equal "${AFFINITY_API_KEY:-unset}" "unset"
	assert_equal "${MCPBASH_TOOL_ENV_MODE}" "allowlist"
}

@test "meta_env: rejects injection and reserved names in allowlists" {
	write_meta '{"env":{"MCPBASH_TOOL_ENV_ALLOWLIST":"FOO,xx[$(touch pwned)]","MCPBASH_PROVIDER_ENV_ALLOWLIST":"FOO,LD_PRELOAD"}}'
	cd "${BATS_TEST_TMPDIR}"
	run mcp_meta_env_apply
	[ ! -e "${BATS_TEST_TMPDIR}/pwned" ]
	assert_output --partial "ignoring MCPBASH_TOOL_ENV_ALLOWLIST"
	assert_output --partial "ignoring MCPBASH_PROVIDER_ENV_ALLOWLIST"
	mcp_meta_env_apply 2>/dev/null
	assert_equal "${MCPBASH_TOOL_ENV_ALLOWLIST:-unset}" "unset"
	assert_equal "${MCPBASH_PROVIDER_ENV_ALLOWLIST:-unset}" "unset"
}

@test "meta_env: rejects mode values that are not valid for the key" {
	write_meta '{"env":{"MCPBASH_TOOL_ENV_MODE":"isolate","MCPBASH_PROVIDER_ENV_MODE":"Allowlist","MCPBASH_TOOL_ENV_ALLOWLIST":7}}'
	run mcp_meta_env_apply
	assert_output --partial "ignoring MCPBASH_TOOL_ENV_MODE: mode must be one of: minimal, allowlist, inherit"
	assert_output --partial "ignoring MCPBASH_PROVIDER_ENV_MODE"
	assert_output --partial "ignoring MCPBASH_TOOL_ENV_ALLOWLIST: value must be a string"
}

@test "meta_env: key names with control characters are sanitised in warnings" {
	write_meta '{"env":{"BAD\u001b[31mKEY\nX":"v"}}'
	run mcp_meta_env_apply
	assert_output --partial "ignoring BAD??31mKEY?X"
	refute_output --partial $'\e'
}

@test "meta_env: non-object env and invalid JSON warn without failing" {
	write_meta '{"env":"MCPBASH_TOOL_ENV_MODE=allowlist"}'
	run mcp_meta_env_apply
	assert_success
	assert_output --partial "env must be an object"
	write_meta '{not json'
	run mcp_meta_env_apply
	assert_success
	assert_output --partial "not valid JSON"
}

@test "meta_env: MCPBASH_IGNORE_META_ENV skips the section" {
	write_meta '{"env":{"MCPBASH_TOOL_ENV_MODE":"allowlist"}}'
	MCPBASH_IGNORE_META_ENV=true mcp_meta_env_apply
	assert_equal "${MCPBASH_TOOL_ENV_MODE:-unset}" "unset"
}

@test "meta_env: no-op without JSON tooling or without the file" {
	write_meta '{"env":{"MCPBASH_TOOL_ENV_MODE":"allowlist"}}'
	MCPBASH_JSON_TOOL=none mcp_meta_env_apply
	assert_equal "${MCPBASH_TOOL_ENV_MODE:-unset}" "unset"
	rm -f "${MCPBASH_SERVER_DIR}/server.meta.json"
	run mcp_meta_env_apply
	assert_success
	assert_output ""
}

@test "meta_env: report shows sources and name states without values" {
	write_meta '{"env":{"MCPBASH_TOOL_ENV_MODE":"allowlist","MCPBASH_TOOL_ENV_ALLOWLIST":"API_KEY,MISSING,EMPTYV,PH"}}'
	API_KEY="sk-sentinel-1" EMPTYV="" PH='${user_config.ph}' run mcp_meta_env_report
	assert_success
	assert_line --partial $'policy\tTOOL\tallowlist\tserver.meta.json'
	assert_line --partial $'name\tTOOL\tAPI_KEY\tset'
	assert_line --partial $'name\tTOOL\tMISSING\tnot set'
	assert_line --partial $'name\tTOOL\tEMPTYV\tempty'
	assert_line --partial $'name\tTOOL\tPH\tplaceholder'
	assert_line --partial $'policy\tPROVIDER\tisolate\tdefault'
	refute_output --partial "sk-sentinel-1"
}

@test "meta_env: report never evaluates invalid launch-env allowlist names" {
	write_meta '{"name":"t"}'
	local marker="${BATS_TEST_TMPDIR}/pwned"
	MCPBASH_TOOL_ENV_MODE=allowlist MCPBASH_TOOL_ENV_ALLOWLIST="OK,xx[\$(touch ${marker})]" run mcp_meta_env_report
	assert_success
	assert_line --partial $'policy\tTOOL\tallowlist\tlaunch env'
	assert_line --partial $'badname\tTOOL\txx'
	[ ! -e "${marker}" ]
}

@test "meta_env: report flags inherit without the operator opt-in" {
	write_meta '{"env":{"MCPBASH_PROVIDER_ENV_MODE":"inherit"}}'
	run mcp_meta_env_report
	assert_line $'inherit\tPROVIDER'
	MCPBASH_PROVIDER_ENV_INHERIT_ALLOW=true run mcp_meta_env_report
	refute_line $'inherit\tPROVIDER'
}

@test "meta_env: doctor text and --json show the policy and never print values" {
	local proj="${BATS_TEST_TMPDIR}/proj"
	mkdir -p "${proj}/server.d"
	printf '%s\n' '{"name":"d","env":{"MCPBASH_TOOL_ENV_MODE":"allowlist","MCPBASH_TOOL_ENV_ALLOWLIST":"API_KEY","LEAK":"sk-sentinel-meta"}}' >"${proj}/server.d/server.meta.json"
	cd "${proj}"
	# setup() points MCPBASH_SERVER_DIR elsewhere; doctor now honours it.
	unset MCPBASH_SERVER_DIR
	API_KEY="sk-sentinel-env" run "${MCPBASH_HOME}/bin/mcp-bash" doctor
	assert_output --partial "tools: mode allowlist (from server.meta.json)"
	assert_output --partial "API_KEY: set"
	assert_output --partial "env.LEAK is ignored"
	refute_output --partial "sk-sentinel"
	API_KEY="sk-sentinel-env" run "${MCPBASH_HOME}/bin/mcp-bash" doctor --json
	refute_output --partial "sk-sentinel"
	run "${TEST_JSON_TOOL_BIN:-jq}" -r '.envPolicy.tool.source + " " + .envPolicy.refusedKeys[0]' <<<"${output}"
	assert_output "server.meta.json LEAK"
}

@test "meta_env: control characters in values are rejected (jq and gojq agree)" {
	write_meta '{"env":{"MCPBASH_TOOL_ENV_ALLOWLIST":"A\n","MCPBASH_PROVIDER_ENV_ALLOWLIST":"B\tC"}}'
	run mcp_meta_env_apply
	assert_output --partial "ignoring MCPBASH_TOOL_ENV_ALLOWLIST: value contains control characters"
	assert_output --partial "ignoring MCPBASH_PROVIDER_ENV_ALLOWLIST: value contains control characters"
}

@test "meta_env: a file with more than one JSON document applies nothing" {
	write_meta '{"env":{"MCPBASH_TOOL_ENV_MODE":"inherit"}} {"env":{"MCPBASH_TOOL_ENV_MODE":"allowlist"}}'
	run mcp_meta_env_apply
	assert_output --partial "exactly one JSON document"
	mcp_meta_env_apply 2>/dev/null
	assert_equal "${MCPBASH_TOOL_ENV_MODE:-unset}" "unset"
	write_meta '{"env":{"MCPBASH_TOOL_ENV_MODE":"allowlist"}} garbage'
	mcp_meta_env_apply 2>/dev/null
	assert_equal "${MCPBASH_TOOL_ENV_MODE:-unset}" "unset"
}

@test "meta_env: report does not glob-expand a '*' allowlist" {
	write_meta '{"name":"t"}'
	cd "${BATS_TEST_TMPDIR}"
	touch SOMEFILE
	MCPBASH_TOOL_ENV_MODE=allowlist MCPBASH_TOOL_ENV_ALLOWLIST='*' run mcp_meta_env_report
	refute_output --partial "SOMEFILE"
	assert_line --partial $'badname\tTOOL'
}

@test "meta_env: allowlists may name non-framework MCP_* variables" {
	write_meta '{"env":{"MCPBASH_TOOL_ENV_ALLOWLIST":"MCP_REGISTRY_TOKEN,MCP_CUSTOM","MCPBASH_PROVIDER_ENV_ALLOWLIST":"MCP_REGISTRY_TOKEN"}}'
	run mcp_meta_env_apply
	assert_success
	assert_output ""
	mcp_meta_env_apply
	assert_equal "${MCPBASH_TOOL_ENV_ALLOWLIST}" "MCP_REGISTRY_TOKEN,MCP_CUSTOM"
	assert_equal "${MCPBASH_PROVIDER_ENV_ALLOWLIST}" "MCP_REGISTRY_TOKEN"
}

@test "meta_env: framework MCP_* families, MCPBASH_* and _MCP* stay reserved in allowlists" {
	local name
	for name in MCP_SDK MCP_TOOL_ARGS_JSON MCP_TOOL_META_JSON MCP_ELICIT_SUPPORTED MCP_PROGRESS_TOKEN \
		MCP_LOG_STREAM MCP_CANCEL_FILE MCP_ROOTS_JSON MCP_RESOURCES_ROOTS MCP_COMPLETION_ARGS_JSON \
		MCP_PROMPT_PATH MCP_RESOURCE_URI MCP_CONFIG_JSON MCP_TRANSPORT MCP_PATH_DEBUG \
		MCPBASH_REMOTE_TOKEN _MCP_TOOLS_RESULT; do
		write_meta "{\"env\":{\"MCPBASH_TOOL_ENV_ALLOWLIST\":\"FOO,${name}\"}}"
		run mcp_meta_env_check
		assert_output $'invalid\tMCPBASH_TOOL_ENV_ALLOWLIST\tlists a reserved or shell-control variable name'
	done
	# Near-misses of the framework families are user-owned names.
	for name in MCP_SDKX MCP_TOOLS_TTL MCP_RESOURCES_TOKEN MCP_PROMPTS_X MCP_UI_X MCP_ROOTS MCP_TRANSPORT_X; do
		write_meta "{\"env\":{\"MCPBASH_TOOL_ENV_ALLOWLIST\":\"${name}\"}}"
		run mcp_meta_env_check
		assert_output $'apply\tMCPBASH_TOOL_ENV_ALLOWLIST\t'"${name}"
	done
}
