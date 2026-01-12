#!/usr/bin/env bats
# Unit layer: SDK mcp_extract_cli_error helper for structured JSON CLI error extraction.

load '../../node_modules/bats-support/load'
load '../../node_modules/bats-assert/load'
load '../common/fixtures'

setup() {
	# Ensure JSON tooling is available so helper exercises the jq/gojq path.
	# shellcheck source=lib/runtime.sh
	# shellcheck disable=SC1091
	. "${MCPBASH_HOME}/lib/runtime.sh"

	MCPBASH_FORCE_MINIMAL=false
	mcp_runtime_detect_json_tool
	if [ "${MCPBASH_MODE}" = "minimal" ]; then
		skip "JSON tooling unavailable for mcp_extract_cli_error tests"
	fi

	# shellcheck source=sdk/tool-sdk.sh
	# shellcheck disable=SC1091
	. "${MCPBASH_HOME}/sdk/tool-sdk.sh"
}

@test "sdk_extract_cli_error: extracts .error.message from JSON stdout" {
	result=$(mcp_extract_cli_error '{"ok":false,"error":{"message":"Missing param"}}' "" "1")
	[ "$result" = "Missing param" ]
}

@test "sdk_extract_cli_error: extracts .error string from JSON stdout" {
	result=$(mcp_extract_cli_error '{"success":false,"error":"Rate limited"}' "" "1")
	[ "$result" = "Rate limited" ]
}

@test "sdk_extract_cli_error: extracts .message when success=false" {
	result=$(mcp_extract_cli_error '{"success":false,"message":"Not found"}' "" "1")
	[ "$result" = "Not found" ]
}

@test "sdk_extract_cli_error: extracts .message when ok=false" {
	result=$(mcp_extract_cli_error '{"ok":false,"message":"Validation failed"}' "" "1")
	[ "$result" = "Validation failed" ]
}

@test "sdk_extract_cli_error: extracts .errors[0].message (GraphQL pattern)" {
	result=$(mcp_extract_cli_error '{"errors":[{"message":"Query failed"}]}' "" "1")
	[ "$result" = "Query failed" ]
}

@test "sdk_extract_cli_error: handles null .error.message gracefully" {
	# Should fall through to stderr, not output "null"
	result=$(mcp_extract_cli_error '{"error":{"message":null}}' "stderr msg" "1")
	[ "$result" = "stderr msg" ]
}

@test "sdk_extract_cli_error: handles missing .errors array gracefully" {
	result=$(mcp_extract_cli_error '{"success":false}' "fallback" "1")
	[ "$result" = "fallback" ]
}

@test "sdk_extract_cli_error: falls back to stderr when JSON has no error fields" {
	result=$(mcp_extract_cli_error '{"data":"something","status":"ok"}' "actual error" "1")
	[ "$result" = "actual error" ]
}

@test "sdk_extract_cli_error: falls back to stderr when stdout not JSON" {
	result=$(mcp_extract_cli_error "not json" "Connection refused" "1")
	[ "$result" = "Connection refused" ]
}

@test "sdk_extract_cli_error: falls back to generic message when both empty" {
	result=$(mcp_extract_cli_error "" "" "42")
	[ "$result" = "CLI exited with code 42" ]
}

@test "sdk_extract_cli_error: prefers JSON error over stderr" {
	result=$(mcp_extract_cli_error '{"error":{"message":"API error"}}' "some stderr" "1")
	[ "$result" = "API error" ]
}

@test "sdk_extract_cli_error: ignores error fields in successful response (ok=true)" {
	# Some CLIs include null error fields in successful responses
	result=$(mcp_extract_cli_error '{"ok":true,"error":null,"data":"result"}' "stderr" "1")
	[ "$result" = "stderr" ]
}

@test "sdk_extract_cli_error: ignores .message when success=true" {
	# Should not extract .message from successful responses
	result=$(mcp_extract_cli_error '{"success":true,"message":"Operation completed"}' "fallback" "1")
	[ "$result" = "fallback" ]
}

@test "sdk_extract_cli_error: handles JSON array gracefully" {
	# Non-object JSON should fall through to stderr
	result=$(mcp_extract_cli_error '[1,2,3]' "stderr fallback" "1")
	[ "$result" = "stderr fallback" ]
}
