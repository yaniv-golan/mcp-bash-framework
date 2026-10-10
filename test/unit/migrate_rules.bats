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
	assert_output "lib/helpers.sh:2:manual
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

resolved() {
	"${BASH}" -c '. "$1/lib/migrate_rules.sh"; mcp_migrate_detect_resolved "$2"' _ "${MCPBASH_HOME}" "$1" \
		| awk -F'\t' '$1 ~ /result-success|envelope|text-with-resource/ { print $3 ":" $4 ":" $2 }' | LC_ALL=C sort
}

envelope_tool() {
	local root="$1" name="$2" ui="$3"
	mkdir -p "${root}/tools/${name}/ui" "${root}/server.d"
	printf '{"name":"x"}\n' >"${root}/server.d/server.meta.json"
	printf '%s\n' '#!/usr/bin/env bash' 'mcp_result_success "{}"' >"${root}/tools/${name}/tool.sh"
	printf '%s\n' '{' '"name": "t",' '"outputSchema": {"type":"object","required":["success"],"properties":{"success":{"type":"boolean"},"result":{"type":"object"}}}' '}' >"${root}/tools/${name}/tool.meta.json"
	[ "${ui}" = "ui" ] && printf '%s\n' 'const d = r.structuredContent.result;' >"${root}/tools/${name}/ui/index.html"
	return 0
}

@test "migrate sets: a tool's result call and outputSchema are auto together" {
	root="${BATS_TEST_TMPDIR}/p"
	envelope_tool "${root}" a no
	run resolved "${root}"
	assert_output "tools/a/tool.meta.json:3:auto
tools/a/tool.sh:2:auto"
}

@test "migrate sets: a manual UI read makes the whole tool manual, other tools unaffected" {
	root="${BATS_TEST_TMPDIR}/p"
	envelope_tool "${root}" a ui
	envelope_tool "${root}" b no
	run resolved "${root}"
	assert_output "tools/a/tool.meta.json:3:manual
tools/a/tool.sh:2:manual
tools/a/ui/index.html:1:manual
tools/b/tool.meta.json:3:auto
tools/b/tool.sh:2:auto"
}

@test "migrate sets: results returned from a shared script make every envelope change manual when schemas need changing" {
	root="${BATS_TEST_TMPDIR}/p"
	envelope_tool "${root}" a no
	mkdir -p "${root}/lib"
	printf '%s\n' 'reply() {' '	mcp_result_success "$1"' '}' >"${root}/lib/common.sh"
	run resolved "${root}"
	assert_output "lib/common.sh:2:manual
tools/a/tool.meta.json:3:manual
tools/a/tool.sh:2:manual"
}

@test "migrate sets: a tool using mcp_result_text_with_resource keeps its envelope schema" {
	root="${BATS_TEST_TMPDIR}/p"
	envelope_tool "${root}" a no
	printf '%s\n' 'mcp_result_text_with_resource "{}" --path /etc/hosts --mime text/plain' >>"${root}/tools/a/tool.sh"
	run resolved "${root}"
	assert_output "tools/a/tool.meta.json:3:manual
tools/a/tool.sh:2:manual
tools/a/tool.sh:3:manual"
}
