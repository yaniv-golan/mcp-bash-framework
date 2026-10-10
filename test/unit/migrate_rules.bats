#!/usr/bin/env bats
# Unit: migration rule engine and the API-2 detection rules.
# Each rule has a fixture project under test/fixtures/migrate/<id>/before and
# an "expected" file listing its findings as file:line:kind.

load '../../node_modules/bats-support/load'
load '../../node_modules/bats-assert/load'
load '../common/fixtures'

FX="${MCPBASH_HOME}/test/fixtures/migrate"

# Findings of one rule over a fixture, as sorted file:line:kind.
detect_rule() {
	local id="$1" root="$2" shell="${3:-${BASH}}"
	"${shell}" -c '. "$1/lib/migrate_rules.sh"; mcp_migrate_detect "$2" --only "$3"' _ "${MCPBASH_HOME}" "${root}" "${id}" \
		| awk -F'\t' '{ print $3 ":" $4 ":" $2 }' | LC_ALL=C sort
}

check_fixture() {
	local id="$1" shell="${2:-${BASH}}"
	local got want
	got="$(detect_rule "${id}" "${FX}/${id}/before" "${shell}")"
	want="$(LC_ALL=C sort "${FX}/${id}/expected")"
	assert_equal "${got}" "${want}"
}

@test "migrate rules: every rule file has a fixture and a matching id" {
	local f id
	for f in "${MCPBASH_HOME}"/lib/cli/migrations/*.sh; do
		id="$(basename "${f}" .sh)"
		grep -q "^MIG_ID=${id}\$" "${f}" || fail "${f}: MIG_ID does not match file name"
		[ "${id}" = "2-marker" ] && continue
		[ -f "${FX}/${id}/expected" ] || fail "no fixture for ${id}"
	done
}

@test "migrate rules: each rule finds exactly its fixture's findings" {
	local d id
	for d in "${FX}"/2-*/; do
		id="$(basename "${d}")"
		check_fixture "${id}" || fail "rule ${id}"
	done
}

@test "migrate rules: same findings under bash 3.2" {
	[ -x /bin/bash ] && /bin/bash -c '[ "${BASH_VERSINFO[0]}" -eq 3 ]' || skip "no bash 3.2 at /bin/bash"
	local d id
	for d in "${FX}"/2-*/; do
		id="$(basename "${d}")"
		check_fixture "${id}" /bin/bash || fail "rule ${id} under bash 3.2"
	done
}

@test "migrate rules: shared helper scripts are scanned; vendored runtime and node_modules never" {
	run detect_rule 2-mcp-error "${FX}/engine/before"
	assert_success
	# lib/helpers.sh is a shared helper script: scanned. .mcp-bash and
	# node_modules: never.
	assert_output "lib/helpers.sh:2:auto
tools/a/tool.sh:3:auto"
}

@test "migrate rules: --validate leaves out rules marked MIG_VALIDATE=0" {
	run "${BASH}" -c '. "$1/lib/migrate_rules.sh"; mcp_migrate_detect "$2" --validate' _ "${MCPBASH_HOME}" "${FX}/engine/before"
	assert_success
	refute_output --partial "2-marker"
	run "${BASH}" -c '. "$1/lib/migrate_rules.sh"; mcp_migrate_detect "$2"' _ "${MCPBASH_HOME}" "${FX}/engine/before"
	assert_output --partial "2-marker"
}

@test "migrate rules: a project already on API 2 has no marker finding" {
	root="${BATS_TEST_TMPDIR}/p"
	mkdir -p "${root}/server.d"
	printf '{"name":"x","mcpBash":{"apiVersion":2}}\n' >"${root}/server.d/server.meta.json"
	run detect_rule 2-marker "${root}"
	assert_success
	assert_output ""
}

@test "migrate rules: the policy rule is manual when the hook uses \$2 or the 1.x message globals" {
	root="${BATS_TEST_TMPDIR}/p"
	mkdir -p "${root}/server.d"
	printf '%s\n' '{"name":"x"}' >"${root}/server.d/server.meta.json"
	cat >"${root}/server.d/policy.sh" <<'SH'
mcp_tools_policy_check() {
	mcp_tools_policy_check_default "$@" || return 1
	_MCP_TOOLS_ERROR_MESSAGE="read-only"
	return 1
}
SH
	run detect_rule 2-policy-replace "${root}"
	assert_output "server.d/policy.sh:1:manual"
	cat >"${root}/server.d/policy.sh" <<'SH'
mcp_tools_policy_check() {
	echo "no default call here"
}
SH
	run detect_rule 2-policy-replace "${root}"
	assert_output "server.d/policy.sh:1:manual"
}
