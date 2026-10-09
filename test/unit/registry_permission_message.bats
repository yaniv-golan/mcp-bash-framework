#!/usr/bin/env bats
# Unit: register.json/register.sh permission refusals name the path and the fix.

load '../../node_modules/bats-support/load'
load '../../node_modules/bats-assert/load'
load '../common/fixtures'

setup() {
	# shellcheck source=lib/registry.sh
	# shellcheck disable=SC1091
	. "${MCPBASH_HOME}/lib/registry.sh"
	project="${BATS_TEST_TMPDIR}/proj"
	mkdir -p "${project}/server.d"
	chmod 700 "${project}" "${project}/server.d"
	printf '%s\n' '{"version":1}' >"${project}/server.d/register.json"
	chmod 600 "${project}/server.d/register.json"
	export MCPBASH_PROJECT_ROOT="${project}"
	export MCPBASH_SERVER_DIR="${project}/server.d"
}

@test "registry_permission_message: names a group-writable server.d and the fix" {
	chmod 770 "${project}/server.d"
	run mcp_registry_register_check_permissions "${project}/server.d/register.json"
	assert_failure
	mcp_registry_register_check_permissions "${project}/server.d/register.json" || true
	run mcp_registry_register_permission_message "register.json"
	assert_output "register.json refused: server.d is group- or world-writable (fix: chmod g-w,o-w server.d)"
}

@test "registry_permission_message: names the file itself and the project root" {
	chmod 660 "${project}/server.d/register.json"
	mcp_registry_register_check_permissions "${project}/server.d/register.json" || true
	run mcp_registry_register_permission_message "register.json"
	assert_output --partial "server.d/register.json is group- or world-writable"
	chmod 600 "${project}/server.d/register.json"
	chmod 770 "${project}"
	mcp_registry_register_check_permissions "${project}/server.d/register.json" || true
	run mcp_registry_register_permission_message "register.json"
	assert_output --partial "the project root is group- or world-writable (fix: chmod g-w,o-w"
	refute_output --partial "${BATS_TEST_TMPDIR}"
}

@test "registry_permission_message: symlinks are explained" {
	mv "${project}/server.d/register.json" "${project}/real.json"
	ln -s ../real.json "${project}/server.d/register.json"
	mcp_registry_register_check_permissions "${project}/server.d/register.json" || true
	run mcp_registry_register_permission_message "register.json"
	assert_output "register.json refused: server.d/register.json is a symlink (replace it with a regular file)"
}

@test "registry_permission_message: doctor reports a refused register.json in text and --json" {
	printf '%s\n' '{"name":"p"}' >"${project}/server.d/server.meta.json"
	chmod 770 "${project}/server.d"
	cd "${project}"
	run "${MCPBASH_HOME}/bin/mcp-bash" doctor
	assert_output --partial "server.d/register.json refused: server.d is group- or world-writable (fix: chmod g-w,o-w server.d)"
	run "${MCPBASH_HOME}/bin/mcp-bash" doctor --json
	run "${TEST_JSON_TOOL_BIN:-jq}" -r '[.findings[] | select(.id == "project.register_permissions") | .message][0]' <<<"${output}"
	assert_output --partial "server.d is group- or world-writable"
}

@test "registry_permission_message: doctor ignores register.sh the server would not use" {
	printf '%s\n' '{"name":"p"}' >"${project}/server.d/server.meta.json"
	rm -f "${project}/server.d/register.json"
	printf '#!/usr/bin/env bash\n' >"${project}/server.d/register.sh"
	chmod 775 "${project}/server.d/register.sh"
	cd "${project}"
	# Hooks disabled (the product default; the test fixtures enable them): the
	# server never sources register.sh.
	MCPBASH_ALLOW_PROJECT_HOOKS=false run "${MCPBASH_HOME}/bin/mcp-bash" doctor
	refute_output --partial "register.sh refused"
	# Hooks enabled: now it matters.
	MCPBASH_ALLOW_PROJECT_HOOKS=true run "${MCPBASH_HOME}/bin/mcp-bash" doctor
	assert_output --partial "server.d/register.sh refused: server.d/register.sh is group- or world-writable"
}

@test "registry_permission_message: dangling symlinks and directories are named, not '?'" {
	ln -s missing.json "${project}/server.d/reg-link.json"
	mcp_registry_register_check_permissions "${project}/server.d/reg-link.json" || true
	run mcp_registry_register_permission_message "x"
	assert_output "x refused: server.d/reg-link.json is a symlink (replace it with a regular file)"
	mkdir "${project}/server.d/dir.json"
	mcp_registry_register_check_permissions "${project}/server.d/dir.json" || true
	run mcp_registry_register_permission_message "x"
	assert_output "x refused: server.d/dir.json is not a regular file"
}
