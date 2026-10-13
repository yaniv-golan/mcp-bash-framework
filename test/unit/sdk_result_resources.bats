#!/usr/bin/env bats
# Unit layer: --resource on mcp_result_text and mcp_result_json (2.0), which
# replaces mcp_result_text_with_resource.

load '../../node_modules/bats-support/load'
load '../../node_modules/bats-assert/load'
load '../common/fixtures'

setup() {
	RES="${BATS_TEST_TMPDIR}/resources.json"
	printf 'one\n' >"${BATS_TEST_TMPDIR}/a.txt"
	printf 'two\n' >"${BATS_TEST_TMPDIR}/b.txt"
}

# sdk FUNC ARGS...: run an SDK helper with a resources file.
sdk() {
	MCP_TOOL_RESOURCES_FILE="${RES}" MCPBASH_JSON_TOOL_BIN="${JQ:-jq}" "${BASH}" -c '. "${MCPBASH_HOME}/sdk/tool-sdk.sh" >/dev/null 2>&1; "$@"' _ "$@"
}

@test "result resources: mcp_result_text embeds files, output unchanged" {
	run sdk mcp_result_text "done" --resource "${BATS_TEST_TMPDIR}/a.txt" --mime text/plain
	assert_success
	assert_output '{"content":[{"type":"text","text":"done"}],"isError":false}'
	assert_equal "$(jq -c '[.[] | [(.path | split("/") | last), .mimeType, .uri]]' "${RES}")" '[["a.txt","text/plain",null]]'
}

@test "result resources: mcp_result_json takes several, --uri applies to the one before" {
	run sdk mcp_result_json '{"n":1}' --resource "${BATS_TEST_TMPDIR}/a.txt" --resource "${BATS_TEST_TMPDIR}/b.txt" --uri file:///b --max-text-bytes 100
	assert_success
	assert_equal "$(printf '%s' "${output}" | jq -c '.structuredContent')" '{"n":1}'
	assert_equal "$(jq -c '[.[] | [(.path | split("/") | last), .mimeType, .uri]]' "${RES}")" '[["a.txt",null,null],["b.txt",null,"file:///b"]]'
}

@test "result resources: an unreadable file is skipped" {
	run sdk mcp_result_text "done" --resource "${BATS_TEST_TMPDIR}/missing.txt" --resource "${BATS_TEST_TMPDIR}/a.txt"
	assert_success
	assert_equal "$(jq -c '[.[] | .path | split("/") | last]' "${RES}")" '["a.txt"]'
}

@test "result resources: no --resource leaves the resources file alone" {
	printf 'untouched' >"${RES}"
	run sdk mcp_result_text "done"
	assert_equal "$(cat "${RES}")" "untouched"
}

@test "result resources: an unknown option is ignored with a warning, not silently" {
	# A leftover 1.x --path must not vanish without a trace.
	sdk mcp_result_json '{"n":1}' --path "${BATS_TEST_TMPDIR}/a.txt" 2>"${BATS_TEST_TMPDIR}/err" >/dev/null
	grep -q 'unknown option ignored: --path' "${BATS_TEST_TMPDIR}/err" || fail "no warning: $(cat "${BATS_TEST_TMPDIR}/err")"
	sdk mcp_result_text "done" --pth x 2>"${BATS_TEST_TMPDIR}/err" >/dev/null
	grep -q 'unknown option ignored: --pth' "${BATS_TEST_TMPDIR}/err" || fail "no warning: $(cat "${BATS_TEST_TMPDIR}/err")"
	[ ! -e "${RES}" ] || fail "resources written for an unknown option"
}

@test "result resources: invalid JSON data attaches no resource" {
	run sdk mcp_result_json '{"n":' --resource "${BATS_TEST_TMPDIR}/a.txt"
	assert_success
	assert_equal "$(printf '%s' "${output}" | jq -c '[.isError, ._meta["mcpbash/error"].type]')" '[true,"internal"]'
	[ ! -e "${RES}" ] || fail "resource attached to an error result: $(cat "${RES}")"
}
