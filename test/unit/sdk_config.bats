#!/usr/bin/env bats
# Unit layer: SDK mcp_config_load and mcp_config_get helpers.

load '../../node_modules/bats-support/load'
load '../../node_modules/bats-assert/load'
load '../common/fixtures'

setup() {
	# shellcheck source=lib/runtime.sh
	# shellcheck disable=SC1091
	. "${MCPBASH_HOME}/lib/runtime.sh"

	MCPBASH_FORCE_MINIMAL=false
	mcp_runtime_detect_json_tool

	# shellcheck source=sdk/tool-sdk.sh
	# shellcheck disable=SC1091
	. "${MCPBASH_HOME}/sdk/tool-sdk.sh"

	# Suppress logging during tests (enable for debugging)
	MCP_LOG_STREAM=""
	export MCP_LOG_STREAM

	# Clear config state between tests
	unset MCP_CONFIG_JSON

	# Create temp directory for test files
	TEST_TMPDIR=$(mktemp -d)
	export TEST_TMPDIR
}

teardown() {
	rm -rf "${TEST_TMPDIR:-}" 2>/dev/null || true
	unset MCP_CONFIG_JSON
}

# ============================================================================
# Test 1: Load defaults only
# ============================================================================

@test "sdk_config: load defaults only" {
	mcp_config_load --defaults '{"timeout": 30}'
	assert_equal '{"timeout": 30}' "$MCP_CONFIG_JSON"
}

# ============================================================================
# Test 2: Load config file
# ============================================================================

@test "sdk_config: load config file overrides defaults" {
	printf '{"timeout": 60}' > "${TEST_TMPDIR}/config.json"

	mcp_config_load \
		--defaults '{"timeout": 30}' \
		--file "${TEST_TMPDIR}/config.json"

	# File value should override default
	local timeout
	timeout=$(mcp_config_get '.timeout')
	assert_equal "60" "$timeout"
}

# ============================================================================
# Test 3: Load example + file
# ============================================================================

@test "sdk_config: file overrides example" {
	printf '{"timeout": 10, "retries": 3}' > "${TEST_TMPDIR}/config.example.json"
	printf '{"timeout": 60}' > "${TEST_TMPDIR}/config.json"

	mcp_config_load \
		--example "${TEST_TMPDIR}/config.example.json" \
		--file "${TEST_TMPDIR}/config.json"

	local timeout retries
	timeout=$(mcp_config_get '.timeout')
	retries=$(mcp_config_get '.retries')
	assert_equal "60" "$timeout"
	assert_equal "3" "$retries"
}

# ============================================================================
# Test 4: Load env var (JSON)
# ============================================================================

@test "sdk_config: env var JSON overrides file" {
	if [[ "${MCPBASH_MODE:-full}" == "minimal" ]]; then
		skip "Requires jq for JSON merge"
	fi

	printf '{"timeout": 60}' > "${TEST_TMPDIR}/config.json"
	export TEST_CONFIG='{"timeout": 120}'

	mcp_config_load \
		--file "${TEST_TMPDIR}/config.json" \
		--env TEST_CONFIG

	local timeout
	timeout=$(mcp_config_get '.timeout')
	assert_equal "120" "$timeout"

	unset TEST_CONFIG
}

# ============================================================================
# Test 5: Load env var (file path)
# ============================================================================

@test "sdk_config: env var file path loaded and merged" {
	if [[ "${MCPBASH_MODE:-full}" == "minimal" ]]; then
		skip "Requires jq for JSON merge"
	fi

	printf '{"timeout": 90}' > "${TEST_TMPDIR}/env-config.json"
	printf '{"timeout": 60}' > "${TEST_TMPDIR}/config.json"
	export TEST_CONFIG="${TEST_TMPDIR}/env-config.json"

	mcp_config_load \
		--file "${TEST_TMPDIR}/config.json" \
		--env TEST_CONFIG

	local timeout
	timeout=$(mcp_config_get '.timeout')
	assert_equal "90" "$timeout"

	unset TEST_CONFIG
}

# ============================================================================
# Test 6: Invalid JSON file skipped
# ============================================================================

@test "sdk_config: invalid JSON file skipped with warning" {
	printf 'not valid json' > "${TEST_TMPDIR}/invalid.json"
	printf '{"timeout": 30}' > "${TEST_TMPDIR}/valid.json"

	# Enable log capture
	local log_file
	log_file=$(mktemp)
	MCP_LOG_STREAM="$log_file"
	export MCP_LOG_STREAM

	mcp_config_load \
		--example "${TEST_TMPDIR}/invalid.json" \
		--file "${TEST_TMPDIR}/valid.json"

	local timeout
	timeout=$(mcp_config_get '.timeout')
	assert_equal "30" "$timeout"

	# Check warning was logged
	local log_content
	log_content=$(cat "$log_file")
	rm -f "$log_file"
	[[ "$log_content" == *"Invalid JSON"* ]]
}

# ============================================================================
# Test 7: Missing file skipped
# ============================================================================

@test "sdk_config: missing file skipped without error" {
	mcp_config_load \
		--file "${TEST_TMPDIR}/nonexistent.json" \
		--defaults '{"timeout": 30}'

	local timeout
	timeout=$(mcp_config_get '.timeout')
	assert_equal "30" "$timeout"
}

# ============================================================================
# Test 8: No sources returns 1
# ============================================================================

@test "sdk_config: no sources returns 1" {
	run mcp_config_load
	assert_failure
}

# ============================================================================
# Test 9: mcp_config_get simple path
# ============================================================================

@test "sdk_config: get simple path" {
	mcp_config_load --defaults '{"name": "test"}'

	local name
	name=$(mcp_config_get '.name')
	assert_equal "test" "$name"
}

# ============================================================================
# Test 10: mcp_config_get nested path
# ============================================================================

@test "sdk_config: get nested path" {
	if [[ "${MCPBASH_MODE:-full}" == "minimal" ]]; then
		skip "Nested paths not supported in minimal mode"
	fi

	mcp_config_load --defaults '{"api": {"endpoint": "https://example.com"}}'

	local endpoint
	endpoint=$(mcp_config_get '.api.endpoint')
	assert_equal "https://example.com" "$endpoint"
}

# ============================================================================
# Test 11: mcp_config_get missing path returns 1
# ============================================================================

@test "sdk_config: get missing path returns 1" {
	mcp_config_load --defaults '{"name": "test"}'

	run mcp_config_get '.missing'
	assert_failure
}

# ============================================================================
# Test 12: mcp_config_get missing + default
# ============================================================================

@test "sdk_config: get missing with default returns default" {
	mcp_config_load --defaults '{"name": "test"}'

	local result
	result=$(mcp_config_get '.missing' --default 'fallback')
	assert_equal "fallback" "$result"
}

# ============================================================================
# Test 13: mcp_config_get number value
# ============================================================================

@test "sdk_config: get number value" {
	mcp_config_load --defaults '{"timeout": 30}'

	local timeout
	timeout=$(mcp_config_get '.timeout')
	assert_equal "30" "$timeout"
}

# ============================================================================
# Test 14: mcp_config_get boolean value
# ============================================================================

@test "sdk_config: get boolean value" {
	mcp_config_load --defaults '{"enabled": true}'

	local enabled
	enabled=$(mcp_config_get '.enabled')
	assert_equal "true" "$enabled"
}

# ============================================================================
# Test 15: mcp_config_get array value
# ============================================================================

@test "sdk_config: get array value" {
	if [[ "${MCPBASH_MODE:-full}" == "minimal" ]]; then
		skip "Array values not supported in minimal mode"
	fi

	mcp_config_load --defaults '{"items": [1, 2, 3]}'

	local items
	items=$(mcp_config_get '.items')
	# jq -r returns compact array for arrays
	[[ "$items" == *"1"* ]] && [[ "$items" == *"2"* ]] && [[ "$items" == *"3"* ]]
}

# ============================================================================
# Test 16: Minimal mode: top-level string
# ============================================================================

@test "sdk_config: minimal mode top-level string" {
	# Force minimal mode
	local saved_json_tool="${MCPBASH_JSON_TOOL_BIN:-}"
	unset MCPBASH_JSON_TOOL_BIN

	MCP_CONFIG_JSON='{"name": "test"}'
	export MCP_CONFIG_JSON

	local name
	name=$(mcp_config_get '.name')
	assert_equal "test" "$name"

	# Restore
	if [[ -n "$saved_json_tool" ]]; then
		MCPBASH_JSON_TOOL_BIN="$saved_json_tool"
		export MCPBASH_JSON_TOOL_BIN
	fi
}

# ============================================================================
# Test 17: Minimal mode: top-level number
# ============================================================================

@test "sdk_config: minimal mode top-level number" {
	# Force minimal mode
	local saved_json_tool="${MCPBASH_JSON_TOOL_BIN:-}"
	unset MCPBASH_JSON_TOOL_BIN

	MCP_CONFIG_JSON='{"timeout": 30}'
	export MCP_CONFIG_JSON

	local timeout
	timeout=$(mcp_config_get '.timeout')
	assert_equal "30" "$timeout"

	# Restore
	if [[ -n "$saved_json_tool" ]]; then
		MCPBASH_JSON_TOOL_BIN="$saved_json_tool"
		export MCPBASH_JSON_TOOL_BIN
	fi
}

# ============================================================================
# Test 18: Minimal mode: nested path returns default
# ============================================================================

@test "sdk_config: minimal mode nested path returns default" {
	# Force minimal mode
	local saved_json_tool="${MCPBASH_JSON_TOOL_BIN:-}"
	unset MCPBASH_JSON_TOOL_BIN

	MCP_CONFIG_JSON='{"api": {"endpoint": "https://example.com"}}'
	export MCP_CONFIG_JSON

	local result
	result=$(mcp_config_get '.api.endpoint' --default 'fallback')
	assert_equal "fallback" "$result"

	# Restore
	if [[ -n "$saved_json_tool" ]]; then
		MCPBASH_JSON_TOOL_BIN="$saved_json_tool"
		export MCPBASH_JSON_TOOL_BIN
	fi
}

# ============================================================================
# Test 19: Empty env var ignored
# ============================================================================

@test "sdk_config: empty env var ignored falls back to file" {
	printf '{"timeout": 60}' > "${TEST_TMPDIR}/config.json"
	export TEST_CONFIG=""

	mcp_config_load \
		--file "${TEST_TMPDIR}/config.json" \
		--env TEST_CONFIG

	local timeout
	timeout=$(mcp_config_get '.timeout')
	assert_equal "60" "$timeout"

	unset TEST_CONFIG
}

# ============================================================================
# Test 20: Shallow merge verification
# ============================================================================

@test "sdk_config: shallow merge replaces top-level keys" {
	if [[ "${MCPBASH_MODE:-full}" == "minimal" ]]; then
		skip "Requires jq for JSON merge"
	fi

	printf '{"api": {"endpoint": "https://old.com", "key": "abc"}}' > "${TEST_TMPDIR}/config.example.json"
	printf '{"api": {"endpoint": "https://new.com"}}' > "${TEST_TMPDIR}/config.json"

	mcp_config_load \
		--example "${TEST_TMPDIR}/config.example.json" \
		--file "${TEST_TMPDIR}/config.json"

	# Shallow merge: entire api object is replaced
	local endpoint
	endpoint=$(mcp_config_get '.api.endpoint')
	assert_equal "https://new.com" "$endpoint"

	# The "key" field should NOT exist (shallow merge replaced entire api object)
	run mcp_config_get '.api.key'
	assert_failure
}

# ============================================================================
# Test 21: mcp_config_get empty string value
# ============================================================================

@test "sdk_config: get empty string returns empty (not default)" {
	if [[ "${MCPBASH_MODE:-full}" == "minimal" ]]; then
		skip "Empty string detection tested separately in minimal mode (test 24)"
	fi

	mcp_config_load --defaults '{"name": ""}'

	local name
	name=$(mcp_config_get '.name' --default 'fallback')
	assert_equal "" "$name"
}

# ============================================================================
# Test 22: Invalid --defaults JSON
# ============================================================================

@test "sdk_config: invalid defaults JSON logs warning uses empty" {
	# Enable log capture
	local log_file
	log_file=$(mktemp)
	MCP_LOG_STREAM="$log_file"
	export MCP_LOG_STREAM

	printf '{"timeout": 30}' > "${TEST_TMPDIR}/config.json"

	mcp_config_load \
		--defaults 'not valid json' \
		--file "${TEST_TMPDIR}/config.json"

	# Should still work with file
	local timeout
	timeout=$(mcp_config_get '.timeout')
	assert_equal "30" "$timeout"

	# Check warning was logged
	local log_content
	log_content=$(cat "$log_file")
	rm -f "$log_file"
	[[ "$log_content" == *"Invalid JSON in --defaults"* ]]
}

# ============================================================================
# Test 23: mcp_config_get with JSON null value
# ============================================================================

@test "sdk_config: get null value returns default" {
	if [[ "${MCPBASH_MODE:-full}" == "minimal" ]]; then
		skip "Requires jq for null handling"
	fi

	mcp_config_load --defaults '{"value": null}'

	local result
	result=$(mcp_config_get '.value' --default 'fallback')
	assert_equal "fallback" "$result"
}

# ============================================================================
# Test 24: Minimal mode: empty string value
# ============================================================================

@test "sdk_config: minimal mode empty string returns empty" {
	# Force minimal mode
	local saved_json_tool="${MCPBASH_JSON_TOOL_BIN:-}"
	unset MCPBASH_JSON_TOOL_BIN

	MCP_CONFIG_JSON='{"name": ""}'
	export MCP_CONFIG_JSON

	local name
	name=$(mcp_config_get '.name' --default 'fallback')
	assert_equal "" "$name"

	# Restore
	if [[ -n "$saved_json_tool" ]]; then
		MCPBASH_JSON_TOOL_BIN="$saved_json_tool"
		export MCPBASH_JSON_TOOL_BIN
	fi
}

# ============================================================================
# Test 25: Minimal mode: float value
# ============================================================================

@test "sdk_config: minimal mode float value" {
	# Force minimal mode
	local saved_json_tool="${MCPBASH_JSON_TOOL_BIN:-}"
	unset MCPBASH_JSON_TOOL_BIN

	MCP_CONFIG_JSON='{"value": 30.5}'
	export MCP_CONFIG_JSON

	local value
	value=$(mcp_config_get '.value')
	assert_equal "30.5" "$value"

	# Restore
	if [[ -n "$saved_json_tool" ]]; then
		MCPBASH_JSON_TOOL_BIN="$saved_json_tool"
		export MCPBASH_JSON_TOOL_BIN
	fi
}

# ============================================================================
# Test 26: Minimal mode: negative number
# ============================================================================

@test "sdk_config: minimal mode negative number" {
	# Force minimal mode
	local saved_json_tool="${MCPBASH_JSON_TOOL_BIN:-}"
	unset MCPBASH_JSON_TOOL_BIN

	MCP_CONFIG_JSON='{"value": -10}'
	export MCP_CONFIG_JSON

	local value
	value=$(mcp_config_get '.value')
	assert_equal "-10" "$value"

	# Restore
	if [[ -n "$saved_json_tool" ]]; then
		MCPBASH_JSON_TOOL_BIN="$saved_json_tool"
		export MCPBASH_JSON_TOOL_BIN
	fi
}
