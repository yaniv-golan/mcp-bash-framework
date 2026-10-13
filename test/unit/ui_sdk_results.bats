#!/usr/bin/env bats
# Unit: UI result helpers against the real tool SDK (no mcp_result_success stub).

load '../../node_modules/bats-support/load'
load '../../node_modules/bats-assert/load'
load '../common/fixtures'

setup() {
	export MCPBASH_JSON_TOOL="${MCPBASH_JSON_TOOL:-jq}"
	export MCPBASH_JSON_TOOL_BIN="${MCPBASH_JSON_TOOL_BIN:-$(command -v jq)}"
	export MCPBASH_MODE=full
	export MCPBASH_STATE_DIR="${BATS_TEST_TMPDIR}"
	# shellcheck disable=SC1091
	. "${MCPBASH_HOME}/sdk/tool-sdk.sh"
	# shellcheck disable=SC1091
	. "${MCPBASH_HOME}/sdk/ui-sdk.sh"
}

no_ui() {
	MCPBASH_CLIENT_SUPPORTS_UI=0
	rm -f "${MCPBASH_STATE_DIR}/extensions.ui.support"
}

@test "ui_sdk_results: mcp_result_with_ui falls back to a plain-text success without UI" {
	no_ui
	result="$(mcp_result_with_ui "" "Dashboard ready" '{"items":42}')"
	assert_equal "$(jq -r '.isError' <<<"${result}")" "false"
	assert_equal "$(jq -r '.content[0].type' <<<"${result}")" "text"
	assert_equal "$(jq -r '.content[0].text' <<<"${result}")" "Dashboard ready"
}

@test "ui_sdk_results: mcp_result_with_ui_data falls back to a plain-text success without UI" {
	no_ui
	result="$(mcp_result_with_ui_data "" "Query returned 10 rows" '{"rows":[1,2]}')"
	assert_equal "$(jq -r '.isError' <<<"${result}")" "false"
	assert_equal "$(jq -r '.content[0].text' <<<"${result}")" "Query returned 10 rows"
}

@test "ui_sdk_results: fallback text with quotes and newlines stays intact" {
	no_ui
	text=$'line "one"\nline two'
	result="$(mcp_result_with_ui "" "${text}")"
	assert_equal "$(jq -r '.isError' <<<"${result}")" "false"
	assert_equal "$(jq -r '.content[0].text' <<<"${result}")" "${text}"
}

@test "ui_sdk_results: without data, the UI result omits structuredContent instead of sending null" {
	MCPBASH_CLIENT_SUPPORTS_UI=1
	result="$(mcp_result_with_ui "" "Text only")"
	assert_equal "$(jq -r 'has("structuredContent")' <<<"${result}")" "false"
	assert_equal "$(jq -r '.content[0].text' <<<"${result}")" "Text only"
}

@test "ui_sdk_results: mcp_result_ui sends the data to a UI client" {
	MCPBASH_CLIENT_SUPPORTS_UI=1
	result="$(mcp_result_ui "Dashboard ready" '{"items":42}')"
	assert_equal "$(jq -c '[.isError, .content[0].text, .structuredContent.items]' <<<"${result}")" '[false,"Dashboard ready",42]'
}

@test "ui_sdk_results: mcp_result_ui sends text only to other clients, or without data" {
	no_ui
	result="$(mcp_result_ui "Dashboard ready" '{"items":42}')"
	assert_equal "$(jq -c '[.isError, .content[0].text, has("structuredContent")]' <<<"${result}")" '[false,"Dashboard ready",false]'
	MCPBASH_CLIENT_SUPPORTS_UI=1
	result="$(mcp_result_ui "Just text")"
	assert_equal "$(jq -c '[.content[0].text, has("structuredContent")]' <<<"${result}")" '["Just text",false]'
}
