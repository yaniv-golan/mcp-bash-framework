#!/usr/bin/env bats
# Unit: test/lint-api-usage.sh keeps the skill, scaffold and docs off APIs that
# change in the next major version. Strict paths (plugins/**/SKILL.md,
# scaffold/**) fail; the rest is reported only.

load '../../node_modules/bats-support/load'
load '../../node_modules/bats-assert/load'
load '../common/fixtures'

setup() {
	ROOT="${BATS_TEST_TMPDIR}/repo"
	mkdir -p "${ROOT}/plugins/p/skills/s" "${ROOT}/scaffold/tool" "${ROOT}/docs" "${ROOT}/sdk" "${ROOT}/lib"
	# Minimal SDK so the name check has something to resolve against.
	printf 'mcp_result_json() { :; }\nmcp_fail() { :; }\n' >"${ROOT}/sdk/tool-sdk.sh"
	printf 'mcp_tools_policy_check_default() { :; }\n' >"${ROOT}/lib/tools_policy.sh"
	LINT="${MCPBASH_HOME}/test/lint-api-usage.sh"
}

skill() { printf '%s\n' "$@" >"${ROOT}/plugins/p/skills/s/SKILL.md"; }

@test "lint-api-usage: clean tree passes" {
	skill '# Skill' '```bash' 'mcp_result_json "{}"' '```'
	run "${LINT}" --root "${ROOT}"
	assert_success
}

@test "lint-api-usage: a deprecated call in SKILL.md fails" {
	skill '```bash' 'mcp_error not_found "x"' 'exit 0' '```'
	run "${LINT}" --root "${ROOT}"
	assert_failure
	assert_output --partial "plugins/p/skills/s/SKILL.md:2"
	assert_output --partial "2-mcp-error"
}

@test "lint-api-usage: a deprecated call in scaffold fails" {
	skill 'nothing here'
	printf '#!/usr/bin/env bash\nmcp_result_success "{}"\n' >"${ROOT}/scaffold/tool/tool.sh"
	run "${LINT}" --root "${ROOT}"
	assert_failure
	assert_output --partial "scaffold/tool/tool.sh:2"
}

@test "lint-api-usage: docs are reported but don't fail" {
	skill 'nothing here'
	printf 'Use mcp_result_success for now.\n' >"${ROOT}/docs/GUIDE.md"
	run "${LINT}" --root "${ROOT}"
	assert_success
	assert_output --partial "docs/GUIDE.md:1"
}

@test "lint-api-usage: a line marked 'lint-api-usage: allow' is skipped" {
	skill 'In 1.x this was `mcp_error` <!-- lint-api-usage: allow -->'
	run "${LINT}" --root "${ROOT}"
	assert_success
}

@test "lint-api-usage: SKILL.md bash blocks must parse" {
	skill '```bash' 'if true; then' '```'
	run "${LINT}" --root "${ROOT}"
	assert_failure
	assert_output --partial "bash block"
}

@test "lint-api-usage: SKILL.md may only name functions that exist" {
	skill 'Call `mcp_result_json` or `mcp_tools_policy_check_default`, and define `mcp_tools_policy_project`.' 'Never call `mcp_made_up_helper`.'
	run "${LINT}" --root "${ROOT}"
	assert_failure
	assert_output --partial "mcp_made_up_helper"
	refute_output --partial "mcp_tools_policy_project"
	refute_output --partial "mcp_result_json:"
}

@test "lint-api-usage: --strict-all makes docs fail too" {
	skill 'nothing here'
	printf 'Use mcp_result_success for now.\n' >"${ROOT}/docs/GUIDE.md"
	run "${LINT}" --root "${ROOT}" --strict-all
	assert_failure
}

@test "lint-api-usage: a rule with no 1.x replacement yet is reported, not failed, in SKILL.md" {
	skill '```bash' 'resp="$(mcp_elicit_confirm "Sure?")" || true' '```'
	printf 'mcp_elicit_confirm() { :; }\n' >>"${ROOT}/sdk/tool-sdk.sh"
	run "${LINT}" --root "${ROOT}"
	assert_success
	assert_output --partial "2-elicit-capture"
}

@test "lint-api-usage: recipes defined in examples/ count as existing names" {
	mkdir -p "${ROOT}/examples/x/lib"
	printf 'mcp_detect_cli() { :; }\n' >"${ROOT}/examples/x/lib/d.sh"
	skill 'Use `mcp_detect_cli` from the examples.'
	run "${LINT}" --root "${ROOT}"
	assert_success
}
