#!/usr/bin/env bats
# Unit: `mcp-bash validate` reports uses of APIs that change in 2.0 as
# deprecations: counted separately from warnings, so --strict does not start
# failing on a minor upgrade; --deprecations-as-errors opts in.

load '../../node_modules/bats-support/load'
load '../../node_modules/bats-assert/load'
load '../common/fixtures'

setup() {
	command -v jq >/dev/null 2>&1 || skip "jq required"
	PROJ="${BATS_TEST_TMPDIR}/proj"
	(cd "${BATS_TEST_TMPDIR}" && mcp-bash new proj >/dev/null 2>&1) || skip "mcp-bash new unavailable"
	mkdir -p "${PROJ}/tools/proj-old"
	cat >"${PROJ}/tools/proj-old/tool.meta.json" <<'JSON'
{"name":"proj-old","description":"uses 1.x helpers","inputSchema":{"type":"object","properties":{}}}
JSON
	cat >"${PROJ}/tools/proj-old/tool.sh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
source "${MCP_SDK:?}/tool-sdk.sh"
mcp_error not_found "gone"
exit 0
SH
	chmod +x "${PROJ}/tools/proj-old/tool.sh"
	# Keep the scaffolded hello tool out of the counts.
	rm -rf "${PROJ}/tools/hello"
}

@test "validate: a deprecated call is reported with file, line, rule and fix" {
	run mcp-bash validate --project-root "${PROJ}"
	assert_success
	assert_output --partial "tools/proj-old/tool.sh:4"
	assert_output --partial "[2-mcp-error]"
	assert_output --partial "mcp_fail --type"
	assert_output --partial "1 deprecation(s)"
}

@test "validate: deprecations don't fail --strict" {
	run mcp-bash validate --project-root "${PROJ}" --strict
	assert_success
}

@test "validate: --deprecations-as-errors fails on a deprecation" {
	run mcp-bash validate --project-root "${PROJ}" --deprecations-as-errors
	assert_failure
}

@test "validate: --json counts deprecations separately and lists them" {
	run mcp-bash validate --project-root "${PROJ}" --json
	assert_success
	assert_equal "$(printf '%s' "${output}" | jq '.deprecations')" "1"
	assert_equal "$(printf '%s' "${output}" | jq -c '[.messages[] | select(.section == "deprecations") | {file, id, kind, level, line}]')" \
		'[{"file":"tools/proj-old/tool.sh","id":"2-mcp-error","kind":"auto","level":"deprecation","line":4}]'
}

@test "validate: a project with no deprecated calls reports none" {
	cat >"${PROJ}/tools/proj-old/tool.sh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
source "${MCP_SDK:?}/tool-sdk.sh"
mcp_fail --type not_found "gone"
SH
	run mcp-bash validate --project-root "${PROJ}" --json
	assert_success
	assert_equal "$(printf '%s' "${output}" | jq '.deprecations')" "0"
	run mcp-bash validate --project-root "${PROJ}"
	refute_output --partial "deprecation"
}
