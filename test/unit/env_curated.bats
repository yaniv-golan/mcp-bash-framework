#!/usr/bin/env bash
# Unit: curated environment scrubbing helpers (Windows E2BIG mitigation).

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

# shellcheck source=test/common/env.sh
# shellcheck disable=SC1091
. "${REPO_ROOT}/test/common/env.sh"
# shellcheck source=test/common/assert.sh
# shellcheck disable=SC1091
. "${REPO_ROOT}/test/common/assert.sh"

# shellcheck source=lib/runtime.sh
# shellcheck disable=SC1091
. "${REPO_ROOT}/lib/runtime.sh"

test_create_tmpdir

printf ' -> provider policy drops ambient vars but keeps MCP_* and baseline\n'
out="$(
	(
		export MCPBASH_PROVIDER_ENV_MODE="isolate"
		export FOO="bar"
		export MCP_FOO="m"
		export MCPBASH_FOO="b"
		export TMP="t"
		export TEMP="t2"
		mcp_env_apply_curated_policy provider
		printf '%s|%s|%s|%s|%s' "${FOO-}" "${MCP_FOO-}" "${MCPBASH_FOO-}" "${TMP-}" "${TEMP-}"
	)
)"
assert_eq "|m|b|t|t2" "${out}" "expected ambient vars to be scrubbed in provider policy"

printf ' -> provider allowlist preserves explicitly allowlisted vars\n'
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
assert_eq "ok|" "${out}" "expected allowlisted var to remain and others to be removed"

printf ' -> provider inherit is gated by MCPBASH_PROVIDER_ENV_INHERIT_ALLOW\n'
out="$(
	(
		export MCPBASH_PROVIDER_ENV_MODE="inherit"
		export MCPBASH_PROVIDER_ENV_INHERIT_ALLOW="false"
		export FOO="bar"
		mcp_env_apply_curated_policy provider
		printf '%s' "${FOO-}"
	)
)"
assert_eq "" "${out}" "expected inherit to be rejected when inherit allow is false"

out="$(
	(
		export MCPBASH_PROVIDER_ENV_MODE="inherit"
		export MCPBASH_PROVIDER_ENV_INHERIT_ALLOW="true"
		export FOO="bar"
		mcp_env_apply_curated_policy provider
		printf '%s' "${FOO-}"
	)
)"
assert_eq "bar" "${out}" "expected inherit to preserve vars when inherit allow is true"

printf ' -> prompt-subst policy emulates env -i and forces minimal PATH/locale\n'
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
assert_eq "/usr/bin:/bin|C|C|" "${out}" "expected strict scrub for prompt substitution policy"

printf ' -> mcp_env_run_curated injects vars and execs target\n'
out="$(mcp_env_run_curated provider "FOO=bar" -- bash -c 'printf "%s" "${FOO-}"')"
assert_eq "bar" "${out}" "expected injected env var to be visible in target"

printf 'curated env helper tests passed.\n'
