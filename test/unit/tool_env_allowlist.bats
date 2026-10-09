#!/usr/bin/env bats
# Unit layer: MCPBASH_TOOL_ENV_ALLOWLIST name validation.

load '../../node_modules/bats-support/load'
load '../../node_modules/bats-assert/load'
load '../common/fixtures'

# run --separate-stderr needs bats >= 1.5.0.
bats_require_minimum_version 1.5.0

setup() {
	PROJECT_ROOT="${BATS_TEST_TMPDIR}/proj"
	export MCPBASH_PROJECT_ROOT="${PROJECT_ROOT}"
	mkdir -p "${PROJECT_ROOT}/tools/echo-env" "${PROJECT_ROOT}/server.d"

	cat >"${PROJECT_ROOT}/server.d/server.meta.json" <<'EOF2'
{"name":"allowlist-test"}
EOF2

	cat >"${PROJECT_ROOT}/tools/echo-env/tool.meta.json" <<'EOF2'
{
  "name": "echo-env",
  "description": "Echo allowlisted variables",
  "inputSchema": { "type": "object" }
}
EOF2

	cat >"${PROJECT_ROOT}/tools/echo-env/tool.sh" <<'EOF2'
#!/usr/bin/env bash
set -euo pipefail
source "${MCP_SDK}/tool-sdk.sh"
mcp_emit_json "$(mcp_json_obj message "FOO=${FOO:-blocked} X=${X:-blocked}")"
EOF2
	chmod +x "${PROJECT_ROOT}/tools/echo-env/tool.sh"
}

@test "tool_env_allowlist: names with array subscripts are not evaluated" {
	local marker="${BATS_TEST_TMPDIR}/pwned"
	FOO="ok" MCPBASH_TOOL_ENV_MODE="allowlist" \
		MCPBASH_TOOL_ENV_ALLOWLIST="FOO,xx[\$(touch\${IFS}${marker})]" \
		run "${MCPBASH_HOME}/bin/mcp-bash" run-tool echo-env --allow-self
	assert_success
	assert_output --partial "FOO=ok"
	[ ! -e "${marker}" ]
}

@test "tool_env_allowlist: one-letter names pass through" {
	X="single" MCPBASH_TOOL_ENV_MODE="allowlist" MCPBASH_TOOL_ENV_ALLOWLIST="X" \
		run "${MCPBASH_HOME}/bin/mcp-bash" run-tool echo-env --allow-self
	assert_success
	assert_output --partial "X=single"
}

@test "tool_env_allowlist: inherit set by policy.sh still requires INHERIT_ALLOW" {
	cat >"${PROJECT_ROOT}/server.d/policy.sh" <<'EOF2'
export MCPBASH_TOOL_ENV_MODE=inherit
EOF2
	FOO="host-secret" run "${MCPBASH_HOME}/bin/mcp-bash" run-tool echo-env --allow-self
	assert_failure
	refute_output --partial "FOO=host-secret"
	assert_output --partial "requires MCPBASH_TOOL_ENV_INHERIT_ALLOW=true"
}

@test "tool_env_allowlist: inherit set by policy.sh works when the operator allows it" {
	cat >"${PROJECT_ROOT}/server.d/policy.sh" <<'EOF2'
export MCPBASH_TOOL_ENV_MODE=inherit
EOF2
	FOO="host-secret" MCPBASH_TOOL_ENV_INHERIT_ALLOW=true \
		run "${MCPBASH_HOME}/bin/mcp-bash" run-tool echo-env --allow-self
	assert_success
	assert_output --partial "FOO=host-secret"
}

@test "tool_env_allowlist: run-tool applies the server.meta.json env policy" {
	cat >"${PROJECT_ROOT}/server.d/server.meta.json" <<'EOF2'
{"name":"allowlist-test","env":{"MCPBASH_TOOL_ENV_MODE":"allowlist","MCPBASH_TOOL_ENV_ALLOWLIST":"FOO"}}
EOF2
	FOO="via-meta" run "${MCPBASH_HOME}/bin/mcp-bash" run-tool echo-env --allow-self
	assert_success
	assert_output --partial "FOO=via-meta"

	FOO="via-meta" MCPBASH_IGNORE_META_ENV=true run "${MCPBASH_HOME}/bin/mcp-bash" run-tool echo-env --allow-self
	assert_success
	assert_output --partial "FOO=blocked"
}

@test "tool_env_allowlist: Windows system variables reach tools in minimal mode" {
	cat >"${PROJECT_ROOT}/tools/echo-env/tool.sh" <<'EOF2'
#!/usr/bin/env bash
set -euo pipefail
source "${MCP_SDK}/tool-sdk.sh"
mcp_emit_json "$(mcp_json_obj message "SYSTEMROOT=${SYSTEMROOT:-missing} USERPROFILE=${USERPROFILE:-missing} TMP=${TMP:-missing} OTHER=${OTHER:-blocked}")"
EOF2
	SYSTEMROOT='C:\Windows' USERPROFILE='C:\Users\u' TMP='C:\t' OTHER="x" MCPBASH_TOOL_ENV_MODE=minimal \
		run "${MCPBASH_HOME}/bin/mcp-bash" run-tool echo-env --allow-self
	assert_success
	assert_output --partial 'SYSTEMROOT=C:\\Windows'
	assert_output --partial 'USERPROFILE=C:\\Users\\u'
	assert_output --partial 'TMP=C:\\t'
	assert_output --partial "OTHER=blocked"
}

@test "tool_env_allowlist: server.meta.json env warnings stay off run-tool stdout" {
	cat >"${PROJECT_ROOT}/server.d/server.meta.json" <<'EOF2'
{"name":"allowlist-test","env":{"API_KEY":"sk-sentinel-out","MCPBASH_TOOL_ENV_MODE":"bogus"}}
EOF2
	run --separate-stderr "${MCPBASH_HOME}/bin/mcp-bash" run-tool echo-env --allow-self
	assert_success
	# The warnings must go to stderr, never stdout (which carries the result).
	[[ "${output}" != *"ignoring"* ]]
	[[ "${output}" == *'"structuredContent"'* ]]
	[[ "${stderr}" == *"ignoring API_KEY"* ]]
	[[ "${output}${stderr}" != *"sk-sentinel-out"* ]]
}

@test "tool_env_allowlist: run-tool treats --with-server-env as launch env (no mixing)" {
	cat >"${PROJECT_ROOT}/server.d/server.meta.json" <<'EOF2'
{"name":"allowlist-test","env":{"MCPBASH_TOOL_ENV_MODE":"allowlist","MCPBASH_TOOL_ENV_ALLOWLIST":"X"}}
EOF2
	cat >"${PROJECT_ROOT}/server.d/env.sh" <<'EOF2'
export MCPBASH_TOOL_ENV_ALLOWLIST="FOO"
EOF2
	# env.sh sets the tool allowlist, so the whole tool scope is the operator's:
	# the meta MODE must not be combined with env.sh's allowlist.
	FOO="mixed" run "${MCPBASH_HOME}/bin/mcp-bash" run-tool echo-env --allow-self --with-server-env
	assert_success
	assert_output --partial "FOO=blocked"
}

# One probe list drives all three places that encode the framework-owned MCP_*
# families (lib/tools.sh tool env, lib/runtime.sh provider env, lib/meta_env.sh
# reserved names), so they cannot drift apart silently.
MCP_FRAMEWORK_PROBES="MCP_SDK MCP_TOOL_PROBE MCP_ELICIT_PROBE MCP_PROGRESS_PROBE MCP_LOG_STREAM MCP_CANCEL_FILE MCP_ROOTS_PROBE MCP_RESOURCES_ROOTS MCP_COMPLETION_PROBE MCP_PROMPT_PROBE MCP_RESOURCE_PROBE MCP_CONFIG_JSON MCP_TRANSPORT MCP_PATH_DEBUG"
MCP_USER_PROBES="MCP_REGISTRY_TOKEN MCP_SDKX MCP_TOOLS_PROBE MCP_RESOURCES_PROBE MCP_PROMPTS_PROBE MCP_UI_PROBE MCP_ROOTS MCP_TRANSPORT_X"

print_probe_states() {
	local n
	for n in ${MCP_FRAMEWORK_PROBES} ${MCP_USER_PROBES}; do
		printf '%s=%s;' "${n}" "${!n+1}"
	done
}

@test "tool_env_allowlist: framework MCP_* families agree across tool env, provider env and meta_env" {
	local n want=""
	for n in ${MCP_FRAMEWORK_PROBES}; do want="${want}${n}=1;"; done
	for n in ${MCP_USER_PROBES}; do want="${want}${n}=;"; done
	# "stdio" keeps MCP_TRANSPORT valid and MCP_PATH_DEBUG off.
	for n in ${MCP_FRAMEWORK_PROBES} ${MCP_USER_PROBES}; do
		export "${n}=stdio"
	done

	# Tool env (minimal).
	cat >"${PROJECT_ROOT}/tools/echo-env/tool.sh" <<EOF2
#!/usr/bin/env bash
for n in ${MCP_FRAMEWORK_PROBES} ${MCP_USER_PROBES}; do
	printf '%s=%s;' "\${n}" "\${!n+1}"
done
EOF2
	MCPBASH_TOOL_ENV_MODE=minimal run "${MCPBASH_HOME}/bin/mcp-bash" run-tool echo-env --allow-self
	assert_success
	assert_output --partial "${want}"

	# Provider curated env (isolate).
	run bash -c "$(declare -f print_probe_states)
		MCP_FRAMEWORK_PROBES='${MCP_FRAMEWORK_PROBES}' MCP_USER_PROBES='${MCP_USER_PROBES}'
		. '${MCPBASH_HOME}/lib/runtime.sh'
		export MCPBASH_PROVIDER_ENV_MODE=isolate
		mcp_env_apply_curated_policy provider
		print_probe_states"
	assert_success
	assert_output "${want}"

	# server.meta.json allowlists: framework names refused, user names allowed.
	. "${MCPBASH_HOME}/lib/meta_env.sh"
	export MCPBASH_SERVER_DIR="${PROJECT_ROOT}/server.d"
	export MCPBASH_JSON_TOOL="${MCPBASH_JSON_TOOL:-jq}"
	export MCPBASH_JSON_TOOL_BIN="${MCPBASH_JSON_TOOL_BIN:-$(command -v jq)}"
	for n in ${MCP_FRAMEWORK_PROBES}; do
		printf '{"env":{"MCPBASH_TOOL_ENV_ALLOWLIST":"%s"}}\n' "${n}" >"${MCPBASH_SERVER_DIR}/server.meta.json"
		run mcp_meta_env_check
		assert_output --partial $'invalid\tMCPBASH_TOOL_ENV_ALLOWLIST'
	done
	for n in ${MCP_USER_PROBES}; do
		printf '{"env":{"MCPBASH_TOOL_ENV_ALLOWLIST":"%s"}}\n' "${n}" >"${MCPBASH_SERVER_DIR}/server.meta.json"
		run mcp_meta_env_check
		assert_output $'apply\tMCPBASH_TOOL_ENV_ALLOWLIST\t'"${n}"
	done
}

@test "tool_env_allowlist: policy.sh can layer rules on top of the default policy" {
	cat >"${PROJECT_ROOT}/server.d/policy.sh" <<'EOF2'
mcp_tools_policy_check() {
	mcp_tools_policy_check_default "$@" || return 1
	if [ "${READ_ONLY:-0}" = "1" ]; then
		mcp_tools_error -32602 "Read-only mode: $1 disabled"
		return 1
	fi
	return 0
}
EOF2
	# No allowlist and no --allow-self: the default deny still applies.
	unset MCPBASH_TOOL_ALLOWLIST
	run "${MCPBASH_HOME}/bin/mcp-bash" run-tool echo-env
	assert_failure
	assert_output --partial "blocked by policy"
	# Allowlisted: the project's own rule applies on top.
	MCPBASH_TOOL_ALLOWLIST="echo-env" READ_ONLY=1 run "${MCPBASH_HOME}/bin/mcp-bash" run-tool echo-env
	assert_failure
	assert_output --partial "Read-only mode"
	MCPBASH_TOOL_ALLOWLIST="echo-env" run "${MCPBASH_HOME}/bin/mcp-bash" run-tool echo-env
	assert_success
}

@test "tool_env_allowlist: validate and doctor warn when policy.sh replaces the default policy" {
	cat >"${PROJECT_ROOT}/server.d/policy.sh" <<'EOF2'
mcp_tools_policy_check() {
	return 0
}
EOF2
	cd "${PROJECT_ROOT}"
	run "${MCPBASH_HOME}/bin/mcp-bash" validate
	assert_output --partial "policy.sh replaces the default tool policy"
	run "${MCPBASH_HOME}/bin/mcp-bash" doctor
	assert_output --partial "policy.sh replaces the default tool policy"
	run "${MCPBASH_HOME}/bin/mcp-bash" doctor --json
	assert_output --partial "project.policy_hook_replaces_default"

	cat >"${PROJECT_ROOT}/server.d/policy.sh" <<'EOF2'
mcp_tools_policy_check() {
	mcp_tools_policy_check_default "$@" || return 1
	return 0
}
EOF2
	run "${MCPBASH_HOME}/bin/mcp-bash" validate
	refute_output --partial "policy.sh replaces the default tool policy"
	run "${MCPBASH_HOME}/bin/mcp-bash" doctor
	refute_output --partial "policy.sh replaces the default tool policy"
}
