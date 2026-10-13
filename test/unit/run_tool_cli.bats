#!/usr/bin/env bats
# Unit layer: CLI run-tool wrapper.

load '../../node_modules/bats-support/load'
load '../../node_modules/bats-assert/load'
load '../common/fixtures'
load '../common/ndjson'

setup() {
	PROJECT_ROOT="${BATS_TEST_TMPDIR}/proj"
	export MCPBASH_PROJECT_ROOT="${PROJECT_ROOT}"
	mkdir -p "${PROJECT_ROOT}/tools/echo" "${PROJECT_ROOT}/tools/sideeffect" "${PROJECT_ROOT}/tools/slow" "${PROJECT_ROOT}/server.d"

	cat >"${PROJECT_ROOT}/server.d/server.meta.json" <<'EOF'
{"name":"cli-runner"}
EOF

	cat >"${PROJECT_ROOT}/tools/echo/tool.meta.json" <<'EOF'
{
  "name": "test.echo",
  "description": "Echo a provided value",
  "inputSchema": {
    "type": "object",
    "required": ["value"],
    "properties": { "value": { "type": "string" } }
  },
  "outputSchema": {
    "type": "object",
    "required": ["message"],
    "properties": { "message": { "type": "string" } }
  }
}
EOF

	cat >"${PROJECT_ROOT}/tools/echo/tool.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
source "${MCP_SDK}/tool-sdk.sh"
value="$(mcp_args_require '.value')"
mcp_result_json "$(mcp_json_obj message "${value}")"
EOF
	chmod +x "${PROJECT_ROOT}/tools/echo/tool.sh"

	side_effect_file="${PROJECT_ROOT}/.sideeffect-ran"
	cat >"${PROJECT_ROOT}/tools/sideeffect/tool.meta.json" <<'EOF'
{
  "name": "test.sideeffect",
  "description": "Side effect sentinel",
  "inputSchema": { "type": "object" }
}
EOF
	cat >"${PROJECT_ROOT}/tools/sideeffect/tool.sh" <<EOF
#!/usr/bin/env bash
set -euo pipefail
source "\${MCP_SDK}/tool-sdk.sh"
touch "${side_effect_file}"
mcp_result_json "\$(mcp_json_obj message \"ran\")"
EOF
	chmod +x "${PROJECT_ROOT}/tools/sideeffect/tool.sh"

	cat >"${PROJECT_ROOT}/tools/slow/tool.meta.json" <<'EOF'
{
  "name": "test.slow",
  "description": "Sleep to test timeout overrides",
  "timeoutSecs": 2,
  "inputSchema": { "type": "object" }
}
EOF
	cat >"${PROJECT_ROOT}/tools/slow/tool.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
source "${MCP_SDK}/tool-sdk.sh"
sleep 5
mcp_result_json "$(mcp_json_obj message "done")"
EOF
	chmod +x "${PROJECT_ROOT}/tools/slow/tool.sh"
}

@test "run_tool_cli: print-env shows wiring without executing tool" {
	env_output="$("${MCPBASH_HOME}/bin/mcp-bash" run-tool test.echo --print-env)"
	# Use realpath for comparison since macOS resolves /var -> /private/var
	local real_project_root
	real_project_root="$(cd "${PROJECT_ROOT}" && pwd -P)"
	assert_contains "MCPBASH_PROJECT_ROOT=${real_project_root}" "${env_output}"
	assert_contains "ROOTS=none" "${env_output}"
}

@test "run_tool_cli: print-env shows env policy with source, never values" {
	printf '%s\n' '{"name":"cli-runner","env":{"MCPBASH_TOOL_ENV_MODE":"allowlist","MCPBASH_TOOL_ENV_ALLOWLIST":"SENTINEL_API_KEY"}}' >"${PROJECT_ROOT}/server.d/server.meta.json"
	SENTINEL_API_KEY="sk-sentinel-secret-value" run "${MCPBASH_HOME}/bin/mcp-bash" run-tool test.echo --print-env
	assert_success
	assert_contains "tools: mode allowlist (from server.meta.json)" "${output}"
	assert_contains "providers: mode isolate (from default)" "${output}"
	assert_contains "SENTINEL_API_KEY: set" "${output}"
	# Must say what the report does not cover.
	assert_contains "--with-server-env" "${output}"
	assert_contains "server.d/policy.sh" "${output}"
	if printf '%s' "${output}" | grep -q "sk-sentinel-secret-value"; then
		printf 'secret value leaked: %s\n' "${output}" >&2
		return 1
	fi
}

@test "run_tool_cli: print-env policy source is launch env when the operator sets it" {
	MCPBASH_TOOL_ENV_MODE=inherit run "${MCPBASH_HOME}/bin/mcp-bash" run-tool test.echo --print-env
	assert_success
	assert_contains "tools: mode inherit (from launch env)" "${output}"
}

@test "run_tool_cli: dry-run does not execute tool" {
	run "${MCPBASH_HOME}/bin/mcp-bash" run-tool test.sideeffect --dry-run
	assert_success
	[ ! -e "${PROJECT_ROOT}/.sideeffect-ran" ]
}

@test "run_tool_cli: happy path returns structured content" {
	echo_output="$("${MCPBASH_HOME}/bin/mcp-bash" run-tool test.echo --args '{"value":"ok"}')"
	echo_message="$(printf '%s\n' "${echo_output}" | jq -r 'select(.name=="test.echo") | .structuredContent.message')"
	assert_equal "ok" "${echo_message}"
}

@test "run_tool_cli: tool not found surfaces error" {
	run "${MCPBASH_HOME}/bin/mcp-bash" run-tool test.missing
	assert_failure
	assert_output --partial "tool not found"
}

@test "run_tool_cli: finds a tool added after the registry was cached" {
	run "${MCPBASH_HOME}/bin/mcp-bash" run-tool test.echo --args '{"value":"ok"}'
	assert_success
	[ -f "${PROJECT_ROOT}/.registry/tools.json" ]

	mkdir -p "${PROJECT_ROOT}/tools/added"
	cat >"${PROJECT_ROOT}/tools/added/tool.meta.json" <<'EOF'
{"name": "test.added", "description": "Added after the first run", "inputSchema": {"type": "object"}}
EOF
	cat >"${PROJECT_ROOT}/tools/added/tool.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
source "${MCP_SDK}/tool-sdk.sh"
mcp_result_json "$(mcp_json_obj message "added")"
EOF
	chmod +x "${PROJECT_ROOT}/tools/added/tool.sh"

	run "${MCPBASH_HOME}/bin/mcp-bash" run-tool test.added
	assert_success
	assert_output --partial 'added'
	refute_output --partial 'tool not found'
}

@test "run_tool_cli: reuses an old cache when nothing under tools/ is newer" {
	run "${MCPBASH_HOME}/bin/mcp-bash" run-tool test.echo --args '{"value":"ok"}'
	assert_success
	local cache="${PROJECT_ROOT}/.registry/tools.json"
	[ -f "${cache}" ]

	# An old cache over an older, unchanged tools/ tree: run-tool's own
	# newer-file check says it is current, so it must not rescan (and rewrite)
	# it just because it is older than the TTL.
	find "${PROJECT_ROOT}/tools" -exec touch -t 202501010000 {} +
	touch -t 202601010000 "${cache}"
	touch -t 202601010001 "${BATS_TEST_TMPDIR}/after-cache"

	run "${MCPBASH_HOME}/bin/mcp-bash" run-tool test.echo --args '{"value":"ok"}'
	assert_success
	run find "${cache}" -newer "${BATS_TEST_TMPDIR}/after-cache"
	assert_output ""
}

@test "run_tool_cli: an error result has no structuredContent when the tool declares an outputSchema" {
	# Clients that validate structuredContent against outputSchema on error
	# results too (the TypeScript SDK client, used by Claude Desktop) reject
	# a {success:false, error} envelope (what 1.x's mcp_error and
	# mcp_result_error sent; some tools build it themselves). With an
	# outputSchema it is dropped and its error moves to _meta["mcpbash/error"].
	mkdir -p "${PROJECT_ROOT}/tools/oops" "${PROJECT_ROOT}/tools/oops-plain"
	cat >"${PROJECT_ROOT}/tools/oops/tool.meta.json" <<'EOF'
{"name": "test.oops", "description": "Fails with a hand-built envelope", "inputSchema": {"type": "object"},
 "outputSchema": {"type": "object", "required": ["message"], "properties": {"message": {"type": "string"}}}}
EOF
	cat >"${PROJECT_ROOT}/tools/oops/tool.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
source "${MCP_SDK}/tool-sdk.sh"
printf '%s\n' '{"content":[{"type":"text","text":"No such item"}],"structuredContent":{"success":false,"error":{"type":"not_found","message":"No such item","hint":"List the items first","data":{"id":7}}},"isError":true}'
EOF
	# Same failure without an outputSchema: unchanged (envelope kept).
	cat >"${PROJECT_ROOT}/tools/oops-plain/tool.meta.json" <<'EOF'
{"name": "test.oops-plain", "description": "Fails with a hand-built envelope", "inputSchema": {"type": "object"}}
EOF
	cp "${PROJECT_ROOT}/tools/oops/tool.sh" "${PROJECT_ROOT}/tools/oops-plain/tool.sh"
	chmod +x "${PROJECT_ROOT}/tools/oops/tool.sh" "${PROJECT_ROOT}/tools/oops-plain/tool.sh"

	run "${MCPBASH_HOME}/bin/mcp-bash" run-tool test.oops
	local result
	result="$(printf '%s\n' "${output}" | jq -c 'select(.name == "test.oops")')"
	[ -n "${result}" ] || fail "no result: ${output}"
	run jq -e '.isError == true and (has("structuredContent") | not)' <<<"${result}"
	assert_success
	run jq -e '._meta["mcpbash/error"] == {type: "not_found", message: "No such item", hint: "List the items first", data: {id: 7}}' <<<"${result}"
	assert_success
	run jq -r '.content[0].text' <<<"${result}"
	assert_output --partial "No such item"

	run "${MCPBASH_HOME}/bin/mcp-bash" run-tool test.oops-plain
	result="$(printf '%s\n' "${output}" | jq -c 'select(.name == "test.oops-plain")')"
	run jq -e '.isError == true and .structuredContent.success == false and .structuredContent.error.type == "not_found"' <<<"${result}"
	assert_success
}

@test "run_tool_cli: keeps a newer-file match when find is cut off by SIGPIPE" {
	run "${MCPBASH_HOME}/bin/mcp-bash" run-tool test.echo --args '{"value":"ok"}'
	assert_success

	mkdir -p "${PROJECT_ROOT}/tools/added"
	cat >"${PROJECT_ROOT}/tools/added/tool.meta.json" <<'EOF'
{"name": "test.added", "description": "Added after the first run", "inputSchema": {"type": "object"}}
EOF
	cat >"${PROJECT_ROOT}/tools/added/tool.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
source "${MCP_SDK}/tool-sdk.sh"
mcp_result_json "$(mcp_json_obj message "added")"
EOF
	chmod +x "${PROJECT_ROOT}/tools/added/tool.sh"

	# The stale-cache checks pipe find into a reader that stops at the first
	# match. When the reader exits first, find dies of SIGPIPE (141); the
	# stub makes that happen every time, after find has printed its output.
	local stub_bin="${BATS_TEST_TMPDIR}/stub-bin" real_find
	real_find="$(command -v find)"
	mkdir -p "${stub_bin}"
	cat >"${stub_bin}/find" <<EOF
#!/bin/sh
"${real_find}" "\$@"
rc=\$?
case " \$* " in
*" -newer "* | *" stat "*) exit 141 ;;
esac
exit "\${rc}"
EOF
	chmod +x "${stub_bin}/find"

	PATH="${stub_bin}:${PATH}" run "${MCPBASH_HOME}/bin/mcp-bash" run-tool test.added
	assert_success
	assert_output --partial 'added'
}

@test "run_tool_cli: invalid args must be rejected" {
	run "${MCPBASH_HOME}/bin/mcp-bash" run-tool test.echo --args '"not-an-object"'
	assert_failure
	assert_output --partial "JSON object"
}

@test "run_tool_cli: --no-refresh fails loudly on corrupt cache" {
	mkdir -p "${PROJECT_ROOT}/.registry"
	printf '%s\n' '{"not":"a-tools-registry"' >"${PROJECT_ROOT}/.registry/tools.json"

	run "${MCPBASH_HOME}/bin/mcp-bash" run-tool test.echo --no-refresh --args '{"value":"ok"}'
	assert_failure
	assert_output --partial "invalid tools registry cache"
}

@test "run_tool_cli: timeout override permits slow tool" {
	# Without override, tool should timeout (an isError result, so exit 1)
	run "${MCPBASH_HOME}/bin/mcp-bash" run-tool test.slow
	assert_failure 1
	timeout_output="${output}"
	timeout_is_error="$(printf '%s\n' "${timeout_output}" | jq -r '.isError')"
	assert_equal "true" "${timeout_is_error}"
	# Verify it's a timeout error
	timeout_type="$(printf '%s\n' "${timeout_output}" | jq -r '._meta["mcpbash/error"].type')"
	assert_equal "timeout" "${timeout_type}"

	# With override, tool should complete successfully
	slow_override_output="$("${MCPBASH_HOME}/bin/mcp-bash" run-tool test.slow --timeout 8)"
	slow_message="$(printf '%s\n' "${slow_override_output}" | jq -r 'select(.name=="test.slow") | .structuredContent.message')"
	assert_equal "done" "${slow_message}"
}

# run_tool_cli_add_tool NAME BODY: a tool that runs BODY with the SDK loaded.
run_tool_cli_add_tool() {
	mkdir -p "${PROJECT_ROOT}/tools/$1"
	printf '{"name":"%s","description":"t","inputSchema":{"type":"object"}}\n' "$1" >"${PROJECT_ROOT}/tools/$1/tool.meta.json"
	# shellcheck disable=SC2016  # Literal for the generated tool script
	printf '#!/usr/bin/env bash\nset -euo pipefail\nsource "${MCP_SDK}/tool-sdk.sh"\n%s\n' "$2" >"${PROJECT_ROOT}/tools/$1/tool.sh"
	chmod +x "${PROJECT_ROOT}/tools/$1/tool.sh"
}

@test "run_tool_cli: exits 1 for every isError result, 0 otherwise" {
	run_tool_cli_add_tool err.exit 'echo plain; exit 3'
	run_tool_cli_add_tool err.typed 'mcp_fail --type not_found "nope"'
	run_tool_cli_add_tool err.message 'mcp_fail "one arg"'
	run_tool_cli_add_tool err.legacy 'mcp_error not_found "legacy"; exit 0'
	run_tool_cli_add_tool err.stderr 'echo "to stderr" >&2; exit 3'
	run_tool_cli_add_tool err.stdoutcode 'echo "{\"code\":-32001,\"message\":\"custom\"}"; exit 1'
	run_tool_cli_add_tool err.numeric 'mcp_fail -32602 "bad"'
	run_tool_cli_add_tool err.invalid 'mcp_fail_invalid_args "bad"'
	run_tool_cli_add_tool err.result 'mcp_result_error "{\"type\":\"oops\",\"message\":\"m\"}"'
	run_tool_cli_add_tool ok.text 'mcp_result_text "fine"'
	local t
	for t in err.exit err.typed err.message err.legacy err.stderr err.stdoutcode err.numeric err.invalid err.result; do
		run "${MCPBASH_HOME}/bin/mcp-bash" run-tool "${t}"
		[ "${status}" -eq 1 ] || {
			printf '%s: expected exit 1, got %s: %s\n' "${t}" "${status}" "${output}" >&2
			return 1
		}
		printf '%s\n' "${output}" | jq -e 'select(.isError == true)' >/dev/null || {
			printf '%s: no isError result in output: %s\n' "${t}" "${output}" >&2
			return 1
		}
	done
	run "${MCPBASH_HOME}/bin/mcp-bash" run-tool ok.text
	assert_success
}

@test "run_tool_cli: a resource outside the roots adds no block (no log line, no roots list)" {
	mkdir -p "${PROJECT_ROOT}/tools/res" "${BATS_TEST_TMPDIR}/outside"
	printf 'secret\n' >"${BATS_TEST_TMPDIR}/outside/f.txt"
	printf '{"name":"test.res","description":"r","inputSchema":{"type":"object"}}\n' >"${PROJECT_ROOT}/tools/res/tool.meta.json"
	printf '#!/usr/bin/env bash\nsource "${MCP_SDK}/tool-sdk.sh"\nmcp_result_text "done" --resource "%s"\n' "${BATS_TEST_TMPDIR}/outside/f.txt" >"${PROJECT_ROOT}/tools/res/tool.sh"
	chmod +x "${PROJECT_ROOT}/tools/res/tool.sh"
	run "${MCPBASH_HOME}/bin/mcp-bash" run-tool test.res --roots "${PROJECT_ROOT}" --allow-self 2>/dev/null
	assert_success
	assert_equal "$(printf '%s' "${output}" | jq -c '[.content[].type]')" '["text"]'
	refute_output --partial 'notifications/message'
}
