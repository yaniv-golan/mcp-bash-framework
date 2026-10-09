#!/usr/bin/env bats
# Unit: curated environment scrubbing helpers (Windows E2BIG mitigation).

load '../../node_modules/bats-support/load'
load '../../node_modules/bats-assert/load'
load '../common/fixtures'

setup() {
	# shellcheck source=lib/runtime.sh
	# shellcheck disable=SC1091
	. "${MCPBASH_HOME}/lib/runtime.sh"
}

@test "env_curated: provider policy drops ambient vars but keeps framework MCP_* and baseline" {
	out="$(
		(
			export MCPBASH_PROVIDER_ENV_MODE="isolate"
			export FOO="bar"
			export MCP_FOO="m"
			export MCP_REGISTRY_TOKEN="secret"
			export MCP_PROGRESS_STREAM="p"
			export MCPBASH_FOO="b"
			export MCPBASH_HOME="/h"
			export TMP="t"
			export TEMP="t2"
			mcp_env_apply_curated_policy provider
			printf '%s|%s|%s|%s|%s|%s|%s|%s' "${FOO-}" "${MCP_FOO-}" "${MCP_REGISTRY_TOKEN-}" "${MCP_PROGRESS_STREAM-}" "${MCPBASH_FOO-}" "${MCPBASH_HOME-}" "${TMP-}" "${TEMP-}"
		)
	)"
	assert_equal "${out}" "|||p||/h|t|t2"
}

@test "env_curated: provider allowlist passes an allowlisted non-framework MCP_* name" {
	out="$(
		(
			export MCPBASH_PROVIDER_ENV_MODE="allowlist"
			export MCPBASH_PROVIDER_ENV_ALLOWLIST="MCP_REGISTRY_TOKEN"
			export MCP_REGISTRY_TOKEN="secret"
			export MCP_OTHER="x"
			mcp_env_apply_curated_policy provider
			printf '%s|%s' "${MCP_REGISTRY_TOKEN-}" "${MCP_OTHER-}"
		)
	)"
	assert_equal "${out}" "secret|"
}

@test "env_curated: provider allowlist preserves explicitly allowlisted vars" {
	out="$(
		(
			export MCPBASH_PROVIDER_ENV_MODE="allowlist"
			export MCPBASH_PROVIDER_ENV_ALLOWLIST="KEEP_ME"
			export KEEP_ME="ok"
			export DROP_ME="no"
			mcp_env_apply_curated_policy provider
			printf '%s|%s' "${KEEP_ME-}" "${DROP_ME-}"
		)
	)"
	assert_equal "ok|" "${out}"
}

@test "env_curated: provider inherit is gated by MCPBASH_PROVIDER_ENV_INHERIT_ALLOW" {
	out="$(
		(
			export MCPBASH_PROVIDER_ENV_MODE="inherit"
			export MCPBASH_PROVIDER_ENV_INHERIT_ALLOW="false"
			export FOO="bar"
			mcp_env_apply_curated_policy provider
			printf '%s' "${FOO-}"
		)
	)"
	assert_equal "" "${out}"

	out="$(
		(
			export MCPBASH_PROVIDER_ENV_MODE="inherit"
			export MCPBASH_PROVIDER_ENV_INHERIT_ALLOW="true"
			export FOO="bar"
			mcp_env_apply_curated_policy provider
			printf '%s' "${FOO-}"
		)
	)"
	assert_equal "bar" "${out}"
}

@test "env_curated: prompt-subst policy emulates env -i and forces minimal PATH/locale" {
	out="$(
		(
			export PATH="/x:/y"
			export LANG="POSIX"
			export LC_ALL="POSIX"
			export FOO="bar"
			mcp_env_apply_curated_policy prompt-subst
			printf '%s|%s|%s|%s' "${PATH-}" "${LANG-}" "${LC_ALL-}" "${FOO-}"
		)
	)"
	assert_equal "/usr/bin:/bin|C|C|" "${out}"
}

@test "env_curated: provider env never keeps MCPBASH_REMOTE_TOKEN*, even when allowlisted" {
	local mode
	for mode in isolate allowlist; do
		out="$(
			(
				export MCPBASH_PROVIDER_ENV_MODE="${mode}"
				export MCPBASH_PROVIDER_ENV_ALLOWLIST="MCPBASH_REMOTE_TOKEN,MCPBASH_REMOTE_TOKEN_KEY,MCPBASH_REMOTE_TOKEN_FALLBACK_KEY"
				export MCPBASH_REMOTE_TOKEN="dummy-test-token-0123456789abcdef"
				export MCPBASH_REMOTE_TOKEN_KEY="custom/tok"
				export MCPBASH_REMOTE_TOKEN_FALLBACK_KEY="legacy"
				mcp_env_apply_curated_policy provider
				printf '%s|%s|%s' "${MCPBASH_REMOTE_TOKEN+set}" "${MCPBASH_REMOTE_TOKEN_KEY+set}" "${MCPBASH_REMOTE_TOKEN_FALLBACK_KEY+set}"
			)
		)"
		assert_equal "||" "${out}"
	done
}

@test "env_curated: mcp_env_run_curated injects vars and execs target" {
	out="$(mcp_env_run_curated provider "FOO=bar" -- bash -c 'printf "%s" "${FOO-}"')"
	assert_equal "bar" "${out}"
}
