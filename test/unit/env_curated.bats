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

@test "env_curated: provider policy drops ambient vars but keeps MCP_* and baseline" {
	out="$(
		(
			export MCPBASH_PROVIDER_ENV_MODE="isolate"
			export FOO="bar"
			export MCP_FOO="m"
			export MCPBASH_FOO="b"
			export MCPBASH_HOME="/h"
			export TMP="t"
			export TEMP="t2"
			mcp_env_apply_curated_policy provider
			printf '%s|%s|%s|%s|%s|%s' "${FOO-}" "${MCP_FOO-}" "${MCPBASH_FOO-}" "${MCPBASH_HOME-}" "${TMP-}" "${TEMP-}"
		)
	)"
	assert_equal "|m||/h|t|t2" "${out}"
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

@test "env_curated: mcp_env_run_curated injects vars and execs target" {
	out="$(mcp_env_run_curated provider "FOO=bar" -- bash -c 'printf "%s" "${FOO-}"')"
	assert_equal "bar" "${out}"
}
