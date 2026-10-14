#!/usr/bin/env bats
# Unit: `mcp-bash migrate` (check by default; --write applies the rewrites
# whose target is frozen, then records the API version).

load '../../node_modules/bats-support/load'
load '../../node_modules/bats-assert/load'
load '../common/fixtures'

setup() {
	command -v jq >/dev/null 2>&1 || skip "jq required"
	command -v git >/dev/null 2>&1 || skip "git required"
	PROJ="${BATS_TEST_TMPDIR}/proj"
	(cd "${BATS_TEST_TMPDIR}" && mcp-bash new proj >/dev/null 2>&1) || skip "mcp-bash new unavailable"
	rm -rf "${PROJ}/tools/hello"
	# Simulate a project created before 1.8 (new projects record API 2).
	jq 'del(.mcpBash)' "${PROJ}/server.d/server.meta.json" >"${PROJ}/meta.tmp" && mv "${PROJ}/meta.tmp" "${PROJ}/server.d/server.meta.json"
	mkdir -p "${PROJ}/tools/proj-a"
	cat >"${PROJ}/tools/proj-a/tool.meta.json" <<'JSON'
{
  "name": "proj-a",
  "description": "a",
  "inputSchema": {"type": "object", "properties": {"mode": {"type": "string"}}},
  "outputSchema": {"type": "object", "required": ["success", "result"], "properties": {"success": {"type": "boolean"}, "result": {"type": "object", "properties": {"n": {"type": "integer"}}}}}
}
JSON
	cat >"${PROJ}/tools/proj-a/tool.sh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
source "${MCP_SDK:?}/tool-sdk.sh"
mode="$(mcp_args_get '.mode')"
if [ "${mode}" = "bad" ]; then
	mcp_fail_invalid_args "mode is bad"
fi
if [ "${mode}" = "gone" ]; then
	mcp_error not_found "nothing here"
	exit 0
fi
mcp_result_success '{"n":1}'
SH
	chmod +x "${PROJ}/tools/proj-a/tool.sh"
}

git_init() {
	git -C "${PROJ}" init -q
	git -C "${PROJ}" -c user.email=t@t -c user.name=t add -A
	git -C "${PROJ}" -c user.email=t@t -c user.name=t commit -qm init
}

call_tool() {
	MCPBASH_TOOL_ALLOWLIST='*' mcp-bash run-tool proj-a --project-root "${PROJ}" --args "{\"mode\":\"$1\"}" 2>/dev/null
}

@test "migrate: check mode lists findings and changes nothing" {
	before="$(cat "${PROJ}/tools/proj-a/tool.sh")"
	run mcp-bash migrate --project-root "${PROJ}"
	assert_equal "${status}" 1
	assert_output --partial "tools/proj-a/tool.sh:6"
	assert_output --partial "2-fail-invalid-args"
	assert_equal "$(cat "${PROJ}/tools/proj-a/tool.sh")" "${before}"
}

@test "migrate: exit 2 when manual work is pending (wins over auto)" {
	printf 'mcp_result_error %s\n' "'{}'" >>"${PROJ}/tools/proj-a/tool.sh"
	run mcp-bash migrate --project-root "${PROJ}"
	assert_equal "${status}" 2
}

@test "migrate: --write rewrites to the frozen forms, sets the marker, and the tool still works" {
	git_init
	run mcp-bash migrate --project-root "${PROJ}" --write
	assert_success
	run cat "${PROJ}/tools/proj-a/tool.sh"
	assert_output --partial 'mcp_fail --type invalid_args "mode is bad"'
	assert_output --partial 'mcp_fail --type not_found "nothing here"'
	assert_output --partial "mcp_result_json '{\"n\":1}'"
	jq -e '.outputSchema == {"type":"object","properties":{"n":{"type":"integer"}}}' "${PROJ}/tools/proj-a/tool.meta.json" >/dev/null
	assert_equal "$(jq '.mcpBash.apiVersion' "${PROJ}/server.d/server.meta.json")" "2"
	assert_equal "$(call_tool ok | jq -c '.structuredContent')" '{"n":1}'
	assert_equal "$(call_tool bad | jq -r '.isError')" "true"
	assert_equal "$(call_tool gone | jq -r '._meta["mcpbash/error"].type')" "not_found"
}

@test "migrate: --write is idempotent" {
	git_init
	run mcp-bash migrate --project-root "${PROJ}" --write
	assert_success
	git -C "${PROJ}" -c user.email=t@t -c user.name=t commit -qam migrated
	run mcp-bash migrate --project-root "${PROJ}" --write
	assert_success
	assert_equal "$(git -C "${PROJ}" status --porcelain)" ""
	run mcp-bash migrate --project-root "${PROJ}"
	assert_success
}

@test "migrate: --write refuses a dirty git tree unless --force" {
	git_init
	echo '# local edit' >>"${PROJ}/tools/proj-a/tool.sh"
	run mcp-bash migrate --project-root "${PROJ}" --write
	assert_equal "${status}" 3
	assert_output --partial "uncommitted"
	run mcp-bash migrate --project-root "${PROJ}" --write --force
	assert_success
}

@test "migrate: outside git, --write keeps .bak copies" {
	run mcp-bash migrate --project-root "${PROJ}" --write
	assert_success
	[ -f "${PROJ}/tools/proj-a/tool.sh.bak" ]
	run grep -c mcp_result_success "${PROJ}/tools/proj-a/tool.sh.bak"
	assert_output "1"
}

@test "migrate: manual findings are left alone and keep the marker unset" {
	git_init
	printf 'mcp_result_error %s\n' "'{}'" >>"${PROJ}/tools/proj-a/tool.sh"
	git -C "${PROJ}" -c user.email=t@t -c user.name=t commit -qam more
	run mcp-bash migrate --project-root "${PROJ}" --write
	assert_equal "${status}" 2
	run grep -c "mcp_result_error" "${PROJ}/tools/proj-a/tool.sh"
	assert_output "1"
	assert_equal "$(jq '.mcpBash.apiVersion // 0' "${PROJ}/server.d/server.meta.json")" "0"
}

@test "migrate: --list, --explain and --json" {
	run mcp-bash migrate --list
	assert_success
	assert_output --partial "2-mcp-error"
	run mcp-bash migrate --explain 2-mcp-error
	assert_success
	assert_output --partial "mcp_fail --type"
	run mcp-bash migrate --explain no-such-rule
	assert_equal "${status}" 3
	run mcp-bash migrate --project-root "${PROJ}" --json
	assert_equal "${status}" 1
	assert_equal "$(printf '%s' "${output}" | jq '[.findings[] | select(.id == "2-mcp-error")] | length')" "1"
	assert_equal "$(printf '%s' "${output}" | jq -r '.pending.auto > 0')" "true"
}

@test "migrate: --only and --skip" {
	run mcp-bash migrate --project-root "${PROJ}" --only 2-mcp-error --json
	assert_equal "$(printf '%s' "${output}" | jq -r '[.findings[].id] | unique | join(",")')" "2-mcp-error"
	run mcp-bash migrate --project-root "${PROJ}" --skip 2-mcp-error --json
	assert_equal "$(printf '%s' "${output}" | jq -r '[.findings[].id] | index("2-mcp-error")')" "null"
}

@test "migrate: --write refuses when the vendored runtime predates the new helpers" {
	mkdir -p "${PROJ}/.mcp-bash/sdk"
	printf 'mcp_result_success() { :; }\n' >"${PROJ}/.mcp-bash/sdk/tool-sdk.sh"
	run mcp-bash migrate --project-root "${PROJ}"
	assert_output --partial "vendor --upgrade"
	run mcp-bash migrate --project-root "${PROJ}" --write
	assert_equal "${status}" 3
	assert_output --partial "vendor --upgrade"
	run grep -c mcp_result_success "${PROJ}/tools/proj-a/tool.sh"
	assert_output "1"
	# An up-to-date vendored runtime is fine.
	run mcp-bash vendor --upgrade --output "${PROJ}"
	assert_success
	run mcp-bash migrate --project-root "${PROJ}" --write
	assert_success
}

@test "migrate: --write maps numeric mcp_fail codes to the types the runtime uses" {
	mkdir -p "${PROJ}/tools/proj-n"
	printf '{"name":"proj-n","description":"n","inputSchema":{"type":"object"}}\n' >"${PROJ}/tools/proj-n/tool.meta.json"
	cat >"${PROJ}/tools/proj-n/tool.sh" <<'SH'
#!/usr/bin/env bash
source "${MCP_SDK:?}/tool-sdk.sh"
[ -n "${A:-}" ] || mcp_fail -32602 "bad"
mcp_fail -32603 "boom"
SH
	run mcp-bash migrate --project-root "${PROJ}" --write
	grep -q 'mcp_fail --type invalid_args "bad"' "${PROJ}/tools/proj-n/tool.sh"
	grep -q 'mcp_fail --type tool_failed "boom"' "${PROJ}/tools/proj-n/tool.sh" || {
		cat "${PROJ}/tools/proj-n/tool.sh" >&2
		return 1
	}
}

@test "migrate: --write moves mcp_result_text_with_resource, mcp_result_with_ui and the envelope schema" {
	mkdir -p "${PROJ}/tools/proj-r"
	cat >"${PROJ}/tools/proj-r/tool.meta.json" <<'JSON'
{"name": "proj-r", "description": "r", "inputSchema": {"type": "object"},
 "outputSchema": {"type": "object", "required": ["success", "result"], "properties": {"success": {"type": "boolean"},
  "result": {"type": "object", "description": "Result data (present when success=true)", "properties": {"m": {"type": "string"}}}}}}
JSON
	cat >"${PROJ}/tools/proj-r/tool.sh" <<'SH'
#!/usr/bin/env bash
source "${MCP_SDK:?}/tool-sdk.sh"
mcp_result_with_ui "" "Ready" '{"n":1}'
mcp_result_text_with_resource '{"m":"x"}' \
	--path /etc/hosts --mime text/plain
SH
	run mcp-bash migrate --project-root "${PROJ}" --write --only 2-ui-resource-uri,2-text-with-resource,2-envelope-schema
	grep -q "^mcp_result_ui \"Ready\" '{\"n\":1}'$" "${PROJ}/tools/proj-r/tool.sh" || { cat "${PROJ}/tools/proj-r/tool.sh" >&2; return 1; }
	grep -q "^mcp_result_json '{\"m\":\"x\"}' \\\\$" "${PROJ}/tools/proj-r/tool.sh" || { cat "${PROJ}/tools/proj-r/tool.sh" >&2; return 1; }
	grep -q '^	--resource /etc/hosts --mime text/plain$' "${PROJ}/tools/proj-r/tool.sh" || { cat "${PROJ}/tools/proj-r/tool.sh" >&2; return 1; }
	assert_equal "$(jq -c '[.outputSchema.type, (.outputSchema | has("description")), (.outputSchema.properties | keys)]' "${PROJ}/tools/proj-r/tool.meta.json")" '["object",false,["m"]]'
}

@test "migrate: an advisory finding is listed but doesn't keep the marker unset" {
	mkdir -p "${PROJ}/scripts"
	printf '%s\n' '#!/usr/bin/env bash' 'out="$(mcp-bash run-tool proj-a)"' "printf '%s' \"\${out}\" | jq 'select(.name == \"proj-a\")'" >"${PROJ}/scripts/check.sh"
	git_init
	run mcp-bash migrate --project-root "${PROJ}" --write
	assert_success
	run mcp-bash migrate --project-root "${PROJ}"
	assert_success
	assert_output --partial "[advisory] scripts/check.sh:3"
	assert_equal "$(jq '.mcpBash.apiVersion // 0' "${PROJ}/server.d/server.meta.json")" "2"
}
