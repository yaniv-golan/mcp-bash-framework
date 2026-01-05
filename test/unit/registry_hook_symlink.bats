#!/usr/bin/env bats
# Unit: refuse symlinked server.d/register.sh even when hooks enabled.

load '../../node_modules/bats-support/load'
load '../../node_modules/bats-assert/load'
load '../common/fixtures'

setup() {
	# shellcheck source=lib/registry.sh
	# shellcheck disable=SC1091
	. "${MCPBASH_HOME}/lib/registry.sh"

	project="${BATS_TEST_TMPDIR}/proj"
	mkdir -p "${project}/server.d"
	chmod 700 "${project}" "${project}/server.d" 2>/dev/null || true

	export MCPBASH_PROJECT_ROOT="${project}"
	export MCPBASH_SERVER_DIR="${project}/server.d"
}

@test "registry: rejects symlinked register.sh" {
	printf '%s\n' '#!/usr/bin/env bash' >"${project}/evil.sh"
	printf '%s\n' 'echo "pwned"' >>"${project}/evil.sh"
	ln -s "../evil.sh" "${project}/server.d/register.sh"

	run mcp_registry_register_check_permissions "${project}/server.d/register.sh"
	assert_failure
}

@test "registry: accepts regular, owned, non-writable register.sh" {
	rm -f "${project}/server.d/register.sh"
	printf '%s\n' '#!/usr/bin/env bash' >"${project}/server.d/register.sh"
	chmod 700 "${project}/server.d/register.sh" 2>/dev/null || true

	run mcp_registry_register_check_permissions "${project}/server.d/register.sh"
	assert_success
}
