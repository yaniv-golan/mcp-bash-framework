#!/usr/bin/env bats
# Unit tests for SDK mcp_download_safe helper function.

load '../../node_modules/bats-support/load'
load '../../node_modules/bats-assert/load'
load '../common/fixtures'

setup() {
	# Source runtime for logging
	# shellcheck source=lib/runtime.sh
	# shellcheck disable=SC1091
	. "${MCPBASH_HOME}/lib/runtime.sh"

	mcp_runtime_detect_json_tool

	# shellcheck source=sdk/tool-sdk.sh
	# shellcheck disable=SC1091
	. "${MCPBASH_HOME}/sdk/tool-sdk.sh"
}

# -----------------------------------------------------------------------------
# Argument validation tests
# -----------------------------------------------------------------------------

@test "sdk_download_safe: rejects missing --url" {
	result=$(mcp_download_safe --out "/tmp/test.out")
	echo "$result" | jq -e '.success == false' >/dev/null
	echo "$result" | jq -e '.error.type == "invalid_url"' >/dev/null
	echo "$result" | jq -e '.error.message | test("--url is required")' >/dev/null
}

@test "sdk_download_safe: rejects missing --out" {
	result=$(mcp_download_safe --url "https://example.com/file")
	echo "$result" | jq -e '.success == false' >/dev/null
	echo "$result" | jq -e '.error.type == "invalid_params"' >/dev/null
	echo "$result" | jq -e '.error.message | test("--out is required")' >/dev/null
}

@test "sdk_download_safe: rejects http:// URLs" {
	result=$(mcp_download_safe --url "http://example.com/file" --out "/tmp/test.out")
	echo "$result" | jq -e '.success == false' >/dev/null
	echo "$result" | jq -e '.error.type == "invalid_url"' >/dev/null
	echo "$result" | jq -e '.error.message | test("URL must use https://")' >/dev/null
}

@test "sdk_download_safe: rejects empty URL" {
	result=$(mcp_download_safe --url "" --out "/tmp/test.out")
	echo "$result" | jq -e '.success == false' >/dev/null
	echo "$result" | jq -e '.error.type == "invalid_url"' >/dev/null
}

@test "sdk_download_safe: rejects unknown flags (--alow typo)" {
	result=$(mcp_download_safe --url "https://example.com/file" --out "/tmp/test.out" --alow "example.com")
	echo "$result" | jq -e '.success == false' >/dev/null
	echo "$result" | jq -e '.error.type == "invalid_params"' >/dev/null
	echo "$result" | jq -e '.error.message | test("Unknown option")' >/dev/null
}

@test "sdk_download_safe: rejects positional arguments" {
	result=$(mcp_download_safe --url "https://example.com/file" --out "/tmp/test.out" "extra_arg")
	echo "$result" | jq -e '.success == false' >/dev/null
	echo "$result" | jq -e '.error.type == "invalid_params"' >/dev/null
	echo "$result" | jq -e '.error.message | test("Unexpected argument")' >/dev/null
}

@test "sdk_download_safe: error response is valid JSON with special chars in flag" {
	# Test that special characters in unknown flag are properly JSON-escaped
	result=$(mcp_download_safe --url "https://example.com/file" --out "/tmp/test.out" --test'$flag')
	echo "$result" | jq -e '.success == false' >/dev/null
	# If we can parse it, escaping worked
}

@test "sdk_download_safe: error response is valid JSON with quotes in argument" {
	result=$(mcp_download_safe --url "https://example.com/file" --out "/tmp/test.out" 'arg"with"quotes')
	echo "$result" | jq -e '.success == false' >/dev/null
}

# -----------------------------------------------------------------------------
# Parameter validation tests
# -----------------------------------------------------------------------------

@test "sdk_download_safe: rejects non-numeric --max-bytes" {
	result=$(mcp_download_safe --url "https://example.com/file" --out "/tmp/test.out" --max-bytes "abc")
	echo "$result" | jq -e '.success == false' >/dev/null
	echo "$result" | jq -e '.error.type == "invalid_params"' >/dev/null
	echo "$result" | jq -e '.error.message | test("--max-bytes must be a positive integer")' >/dev/null
}

@test "sdk_download_safe: rejects non-numeric --timeout" {
	result=$(mcp_download_safe --url "https://example.com/file" --out "/tmp/test.out" --timeout "slow")
	echo "$result" | jq -e '.success == false' >/dev/null
	echo "$result" | jq -e '.error.type == "invalid_params"' >/dev/null
	echo "$result" | jq -e '.error.message | test("--timeout must be a positive integer")' >/dev/null
}

@test "sdk_download_safe: rejects --timeout > 60" {
	result=$(mcp_download_safe --url "https://example.com/file" --out "/tmp/test.out" --timeout "120")
	echo "$result" | jq -e '.success == false' >/dev/null
	echo "$result" | jq -e '.error.type == "invalid_params"' >/dev/null
	echo "$result" | jq -e '.error.message | test("--timeout cannot exceed 60 seconds")' >/dev/null
}

@test "sdk_download_safe: rejects non-numeric --retry" {
	result=$(mcp_download_safe --url "https://example.com/file" --out "/tmp/test.out" --retry "three")
	echo "$result" | jq -e '.success == false' >/dev/null
	echo "$result" | jq -e '.error.type == "invalid_params"' >/dev/null
	echo "$result" | jq -e '.error.message | test("--retry must be a positive integer")' >/dev/null
}

@test "sdk_download_safe: rejects --retry < 1" {
	result=$(mcp_download_safe --url "https://example.com/file" --out "/tmp/test.out" --retry "0")
	echo "$result" | jq -e '.success == false' >/dev/null
	echo "$result" | jq -e '.error.type == "invalid_params"' >/dev/null
}

@test "sdk_download_safe: rejects non-numeric --retry-delay" {
	result=$(mcp_download_safe --url "https://example.com/file" --out "/tmp/test.out" --retry-delay "slow")
	echo "$result" | jq -e '.success == false' >/dev/null
	echo "$result" | jq -e '.error.type == "invalid_params"' >/dev/null
	echo "$result" | jq -e '.error.message | test("--retry-delay must be a number")' >/dev/null
}

@test "sdk_download_safe: accepts --retry-delay .5 (leading decimal)" {
	# This should pass validation and proceed to host blocking (since no allowlist)
	result=$(mcp_download_safe --url "https://example.com/file" --out "/tmp/test.out" --retry-delay ".5")
	# Should fail at host blocking, not param validation
	echo "$result" | jq -e '.error.type != "invalid_params"' >/dev/null
}

@test "sdk_download_safe: accepts --timeout 60 (boundary)" {
	result=$(mcp_download_safe --url "https://example.com/file" --out "/tmp/test.out" --timeout "60")
	# Should fail at host blocking, not param validation
	echo "$result" | jq -e '.error.type != "invalid_params"' >/dev/null || \
		echo "$result" | jq -e '.error.type == "host_blocked"' >/dev/null
}

# -----------------------------------------------------------------------------
# Allow/deny list tests
# -----------------------------------------------------------------------------

@test "sdk_download_safe: blocks host not in --allow list" {
	result=$(mcp_download_safe \
		--url "https://example.com/file" \
		--out "/tmp/test.out" \
		--allow "other.com")
	echo "$result" | jq -e '.success == false' >/dev/null
	echo "$result" | jq -e '.error.type == "host_blocked"' >/dev/null
}

@test "sdk_download_safe: --deny takes precedence over --allow" {
	result=$(mcp_download_safe \
		--url "https://example.com/file" \
		--out "/tmp/test.out" \
		--allow "example.com" \
		--deny "example.com")
	echo "$result" | jq -e '.success == false' >/dev/null
	echo "$result" | jq -e '.error.type == "host_blocked"' >/dev/null
}

@test "sdk_download_safe: blocks localhost (SSRF protection)" {
	result=$(mcp_download_safe \
		--url "https://localhost/file" \
		--out "/tmp/test.out" \
		--allow "localhost")
	echo "$result" | jq -e '.success == false' >/dev/null
	echo "$result" | jq -e '.error.type == "host_blocked"' >/dev/null
}

@test "sdk_download_safe: blocks 127.0.0.1 (SSRF protection)" {
	result=$(mcp_download_safe \
		--url "https://127.0.0.1/file" \
		--out "/tmp/test.out" \
		--allow "127.0.0.1")
	echo "$result" | jq -e '.success == false' >/dev/null
	echo "$result" | jq -e '.error.type == "host_blocked"' >/dev/null
}

# -----------------------------------------------------------------------------
# Provider unavailable tests
# -----------------------------------------------------------------------------

@test "sdk_download_safe: returns provider_unavailable when provider not found" {
	# Create a mock SDK in temp dir without the provider
	mkdir -p "${BATS_TEST_TMPDIR}/mock_sdk/sdk"
	cp "${MCPBASH_HOME}/sdk/tool-sdk.sh" "${BATS_TEST_TMPDIR}/mock_sdk/sdk/"

	# Run in subshell with broken MCPBASH_HOME (no providers dir)
	result=$(
		cd "${BATS_TEST_TMPDIR}/mock_sdk"
		MCPBASH_HOME="${BATS_TEST_TMPDIR}/mock_sdk" \
		MCPBASH_JSON_TOOL_BIN="${MCPBASH_JSON_TOOL_BIN}" \
		bash -c '
			source sdk/tool-sdk.sh
			mcp_download_safe --url "https://example.com/file" --out "/tmp/test.out" --allow "example.com"
		' 2>/dev/null
	)

	echo "$result" | jq -e '.success == false' >/dev/null
	echo "$result" | jq -e '.error.type == "provider_unavailable"' >/dev/null
}

# -----------------------------------------------------------------------------
# set -e safety tests
# -----------------------------------------------------------------------------

@test "sdk_download_safe: returns exit code 0 even on error" {
	# Don't use bats run - call directly and capture exit code
	local exit_code=0
	result=$(mcp_download_safe --url "https://example.com/file" --out "/tmp/test.out") || exit_code=$?
	[ "$exit_code" -eq 0 ] || fail "Expected exit code 0, got $exit_code"
	echo "$result" | jq -e '.success == false' >/dev/null  # but success should be false
}

@test "sdk_download_safe: safe to use with set -e" {
	set -e
	result=$(mcp_download_safe --url "https://example.com/file" --out "/tmp/test.out")
	# If we get here, set -e didn't trip
	echo "$result" | jq -e '.success == false' >/dev/null
	set +e
}

# -----------------------------------------------------------------------------
# Output format tests
# -----------------------------------------------------------------------------

@test "sdk_download_safe: error response contains required fields" {
	result=$(mcp_download_safe --url "https://example.com/file" --out "/tmp/test.out")
	# Must have success field
	echo "$result" | jq -e 'has("success")' >/dev/null
	# Must have error object with type and message
	echo "$result" | jq -e 'has("error")' >/dev/null
	echo "$result" | jq -e '.error | has("type")' >/dev/null
	echo "$result" | jq -e '.error | has("message")' >/dev/null
}

@test "sdk_download_safe: output is always valid JSON" {
	# Test various error conditions produce valid JSON
	for result in \
		"$(mcp_download_safe)" \
		"$(mcp_download_safe --url)" \
		"$(mcp_download_safe --url "https://x.com" --out "/tmp/x" --unknown-flag)" \
		"$(mcp_download_safe --url "http://x.com" --out "/tmp/x")"; do
		echo "$result" | jq . >/dev/null 2>&1 || fail "Invalid JSON: $result"
	done
}

# -----------------------------------------------------------------------------
# MCPBASH_HTTPS_ALLOW_HOSTS fallback tests
# -----------------------------------------------------------------------------

@test "sdk_download_safe: falls back to MCPBASH_HTTPS_ALLOW_HOSTS env var" {
	# Create mock provider that returns success
	mkdir -p "${BATS_TEST_TMPDIR}/mock_env/providers"
	cat > "${BATS_TEST_TMPDIR}/mock_env/providers/https.sh" << 'EOF'
#!/usr/bin/env bash
echo "mock content"
exit 0
EOF
	chmod +x "${BATS_TEST_TMPDIR}/mock_env/providers/https.sh"
	cp "${MCPBASH_HOME}/sdk/tool-sdk.sh" "${BATS_TEST_TMPDIR}/mock_env/"
	cp "${MCPBASH_HOME}/VERSION" "${BATS_TEST_TMPDIR}/mock_env/"

	# Set env var allowlist (no --allow flag)
	result=$(
		cd "${BATS_TEST_TMPDIR}/mock_env"
		MCPBASH_HOME="${BATS_TEST_TMPDIR}/mock_env" \
		MCPBASH_JSON_TOOL_BIN="${MCPBASH_JSON_TOOL_BIN}" \
		MCPBASH_HTTPS_ALLOW_HOSTS="example.com" \
		bash -c '
			source tool-sdk.sh
			mcp_download_safe --url "https://example.com/file" --out "'"${BATS_TEST_TMPDIR}"'/output.txt"
		' 2>/dev/null
	)

	echo "$result" | jq -e '.success == true' >/dev/null
}

# -----------------------------------------------------------------------------
# Mock provider tests for error codes and retry
# -----------------------------------------------------------------------------

# Helper to create a mock provider with specific exit code
create_mock_provider() {
	local exit_code="$1"
	local stderr_msg="${2:-}"
	local stdout_msg="${3:-}"

	mkdir -p "${BATS_TEST_TMPDIR}/mock_provider/providers"
	cat > "${BATS_TEST_TMPDIR}/mock_provider/providers/https.sh" << EOF
#!/usr/bin/env bash
[[ -n "${stderr_msg}" ]] && echo "${stderr_msg}" >&2
[[ -n "${stdout_msg}" ]] && echo "${stdout_msg}"
exit ${exit_code}
EOF
	chmod +x "${BATS_TEST_TMPDIR}/mock_provider/providers/https.sh"
	cp "${MCPBASH_HOME}/sdk/tool-sdk.sh" "${BATS_TEST_TMPDIR}/mock_provider/"
	cp "${MCPBASH_HOME}/VERSION" "${BATS_TEST_TMPDIR}/mock_provider/"
}

run_with_mock_provider() {
	(
		cd "${BATS_TEST_TMPDIR}/mock_provider"
		MCPBASH_HOME="${BATS_TEST_TMPDIR}/mock_provider" \
		MCPBASH_JSON_TOOL_BIN="${MCPBASH_JSON_TOOL_BIN}" \
		bash -c '
			source tool-sdk.sh
			mcp_download_safe '"$*"'
		' 2>/dev/null
	)
}

@test "sdk_download_safe: returns network_error for exit code 5" {
	create_mock_provider 5 "connection refused"
	result=$(run_with_mock_provider --url "https://example.com/file" --out "${BATS_TEST_TMPDIR}/out.txt" --allow "example.com")

	echo "$result" | jq -e '.success == false' >/dev/null
	echo "$result" | jq -e '.error.type == "network_error"' >/dev/null
}

@test "sdk_download_safe: includes stderr in network_error message" {
	create_mock_provider 5 "SSL certificate problem"
	result=$(run_with_mock_provider --url "https://example.com/file" --out "${BATS_TEST_TMPDIR}/out.txt" --allow "example.com")

	echo "$result" | jq -e '.error.message | test("SSL certificate")' >/dev/null
}

@test "sdk_download_safe: returns size_exceeded for exit code 6" {
	create_mock_provider 6 "Payload exceeds limit"
	result=$(run_with_mock_provider --url "https://example.com/file" --out "${BATS_TEST_TMPDIR}/out.txt" --allow "example.com")

	echo "$result" | jq -e '.success == false' >/dev/null
	echo "$result" | jq -e '.error.type == "size_exceeded"' >/dev/null
}

@test "sdk_download_safe: returns provider_error for exit code 1" {
	create_mock_provider 1 "syntax error"
	result=$(run_with_mock_provider --url "https://example.com/file" --out "${BATS_TEST_TMPDIR}/out.txt" --allow "example.com")

	echo "$result" | jq -e '.success == false' >/dev/null
	echo "$result" | jq -e '.error.type == "provider_error"' >/dev/null
}

@test "sdk_download_safe: returns provider_error for exit code 127" {
	create_mock_provider 127 "command not found"
	result=$(run_with_mock_provider --url "https://example.com/file" --out "${BATS_TEST_TMPDIR}/out.txt" --allow "example.com")

	echo "$result" | jq -e '.success == false' >/dev/null
	echo "$result" | jq -e '.error.type == "provider_error"' >/dev/null
}

@test "sdk_download_safe: does not retry policy rejection (exit 4)" {
	# Create mock that tracks call count
	mkdir -p "${BATS_TEST_TMPDIR}/mock_retry/providers"
	cat > "${BATS_TEST_TMPDIR}/mock_retry/providers/https.sh" << 'EOF'
#!/usr/bin/env bash
echo "1" >> "${BATS_TEST_TMPDIR}/call_count"
exit 4
EOF
	chmod +x "${BATS_TEST_TMPDIR}/mock_retry/providers/https.sh"
	cp "${MCPBASH_HOME}/sdk/tool-sdk.sh" "${BATS_TEST_TMPDIR}/mock_retry/"
	cp "${MCPBASH_HOME}/VERSION" "${BATS_TEST_TMPDIR}/mock_retry/"
	rm -f "${BATS_TEST_TMPDIR}/call_count"

	(
		cd "${BATS_TEST_TMPDIR}/mock_retry"
		MCPBASH_HOME="${BATS_TEST_TMPDIR}/mock_retry" \
		MCPBASH_JSON_TOOL_BIN="${MCPBASH_JSON_TOOL_BIN}" \
		bash -c '
			source tool-sdk.sh
			mcp_download_safe --url "https://example.com/file" --out "'"${BATS_TEST_TMPDIR}"'/out.txt" --allow "example.com" --retry 3
		' 2>/dev/null
	)

	# Should only be called once (no retries for exit 4)
	call_count=$(wc -l < "${BATS_TEST_TMPDIR}/call_count" | tr -d ' ')
	[ "$call_count" -eq 1 ] || fail "Expected 1 call, got $call_count"
}

@test "sdk_download_safe: does not retry size_exceeded (exit 6)" {
	mkdir -p "${BATS_TEST_TMPDIR}/mock_retry6/providers"
	cat > "${BATS_TEST_TMPDIR}/mock_retry6/providers/https.sh" << 'EOF'
#!/usr/bin/env bash
echo "1" >> "${BATS_TEST_TMPDIR}/call_count6"
exit 6
EOF
	chmod +x "${BATS_TEST_TMPDIR}/mock_retry6/providers/https.sh"
	cp "${MCPBASH_HOME}/sdk/tool-sdk.sh" "${BATS_TEST_TMPDIR}/mock_retry6/"
	cp "${MCPBASH_HOME}/VERSION" "${BATS_TEST_TMPDIR}/mock_retry6/"
	rm -f "${BATS_TEST_TMPDIR}/call_count6"

	(
		cd "${BATS_TEST_TMPDIR}/mock_retry6"
		MCPBASH_HOME="${BATS_TEST_TMPDIR}/mock_retry6" \
		MCPBASH_JSON_TOOL_BIN="${MCPBASH_JSON_TOOL_BIN}" \
		bash -c '
			source tool-sdk.sh
			mcp_download_safe --url "https://example.com/file" --out "'"${BATS_TEST_TMPDIR}"'/out.txt" --allow "example.com" --retry 3
		' 2>/dev/null
	)

	call_count=$(wc -l < "${BATS_TEST_TMPDIR}/call_count6" | tr -d ' ')
	[ "$call_count" -eq 1 ] || fail "Expected 1 call, got $call_count"
}

@test "sdk_download_safe: retries network errors (exit 5)" {
	mkdir -p "${BATS_TEST_TMPDIR}/mock_retry5/providers"
	cat > "${BATS_TEST_TMPDIR}/mock_retry5/providers/https.sh" << 'EOF'
#!/usr/bin/env bash
echo "1" >> "${BATS_TEST_TMPDIR}/call_count5"
exit 5
EOF
	chmod +x "${BATS_TEST_TMPDIR}/mock_retry5/providers/https.sh"
	cp "${MCPBASH_HOME}/sdk/tool-sdk.sh" "${BATS_TEST_TMPDIR}/mock_retry5/"
	cp "${MCPBASH_HOME}/VERSION" "${BATS_TEST_TMPDIR}/mock_retry5/"
	rm -f "${BATS_TEST_TMPDIR}/call_count5"

	(
		cd "${BATS_TEST_TMPDIR}/mock_retry5"
		MCPBASH_HOME="${BATS_TEST_TMPDIR}/mock_retry5" \
		MCPBASH_JSON_TOOL_BIN="${MCPBASH_JSON_TOOL_BIN}" \
		bash -c '
			source tool-sdk.sh
			mcp_download_safe --url "https://example.com/file" --out "'"${BATS_TEST_TMPDIR}"'/out.txt" --allow "example.com" --retry 3 --retry-delay 0.01
		' 2>/dev/null
	)

	call_count=$(wc -l < "${BATS_TEST_TMPDIR}/call_count5" | tr -d ' ')
	[ "$call_count" -eq 3 ] || fail "Expected 3 calls (retries), got $call_count"
}

# -----------------------------------------------------------------------------
# Success case tests with mock provider
# -----------------------------------------------------------------------------

@test "sdk_download_safe: writes content to --out path on success" {
	mkdir -p "${BATS_TEST_TMPDIR}/mock_success/providers"
	cat > "${BATS_TEST_TMPDIR}/mock_success/providers/https.sh" << 'EOF'
#!/usr/bin/env bash
echo "downloaded content"
exit 0
EOF
	chmod +x "${BATS_TEST_TMPDIR}/mock_success/providers/https.sh"
	cp "${MCPBASH_HOME}/sdk/tool-sdk.sh" "${BATS_TEST_TMPDIR}/mock_success/"
	cp "${MCPBASH_HOME}/VERSION" "${BATS_TEST_TMPDIR}/mock_success/"

	local out_path="${BATS_TEST_TMPDIR}/downloaded.txt"
	rm -f "$out_path"

	result=$(
		cd "${BATS_TEST_TMPDIR}/mock_success"
		MCPBASH_HOME="${BATS_TEST_TMPDIR}/mock_success" \
		MCPBASH_JSON_TOOL_BIN="${MCPBASH_JSON_TOOL_BIN}" \
		bash -c '
			source tool-sdk.sh
			mcp_download_safe --url "https://example.com/file" --out "'"$out_path"'" --allow "example.com"
		' 2>/dev/null
	)

	echo "$result" | jq -e '.success == true' >/dev/null
	[ -f "$out_path" ] || fail "Output file not created"
	[ "$(cat "$out_path")" = "downloaded content" ] || fail "Content mismatch"
}

@test "sdk_download_safe: returns byte count on success" {
	mkdir -p "${BATS_TEST_TMPDIR}/mock_bytes/providers"
	cat > "${BATS_TEST_TMPDIR}/mock_bytes/providers/https.sh" << 'EOF'
#!/usr/bin/env bash
echo -n "12345"
exit 0
EOF
	chmod +x "${BATS_TEST_TMPDIR}/mock_bytes/providers/https.sh"
	cp "${MCPBASH_HOME}/sdk/tool-sdk.sh" "${BATS_TEST_TMPDIR}/mock_bytes/"
	cp "${MCPBASH_HOME}/VERSION" "${BATS_TEST_TMPDIR}/mock_bytes/"

	result=$(
		cd "${BATS_TEST_TMPDIR}/mock_bytes"
		MCPBASH_HOME="${BATS_TEST_TMPDIR}/mock_bytes" \
		MCPBASH_JSON_TOOL_BIN="${MCPBASH_JSON_TOOL_BIN}" \
		bash -c '
			source tool-sdk.sh
			mcp_download_safe --url "https://example.com/file" --out "'"${BATS_TEST_TMPDIR}"'/bytes.txt" --allow "example.com"
		' 2>/dev/null
	)

	echo "$result" | jq -e '.bytes == 5' >/dev/null
}

@test "sdk_download_safe: JSON-escapes path with special chars" {
	mkdir -p "${BATS_TEST_TMPDIR}/mock_path/providers"
	cat > "${BATS_TEST_TMPDIR}/mock_path/providers/https.sh" << 'EOF'
#!/usr/bin/env bash
echo "content"
exit 0
EOF
	chmod +x "${BATS_TEST_TMPDIR}/mock_path/providers/https.sh"
	cp "${MCPBASH_HOME}/sdk/tool-sdk.sh" "${BATS_TEST_TMPDIR}/mock_path/"
	cp "${MCPBASH_HOME}/VERSION" "${BATS_TEST_TMPDIR}/mock_path/"

	# Create a path with special chars
	local special_dir="${BATS_TEST_TMPDIR}/dir with spaces"
	mkdir -p "$special_dir"
	local out_path="${special_dir}/file.txt"

	result=$(
		cd "${BATS_TEST_TMPDIR}/mock_path"
		MCPBASH_HOME="${BATS_TEST_TMPDIR}/mock_path" \
		MCPBASH_JSON_TOOL_BIN="${MCPBASH_JSON_TOOL_BIN}" \
		bash -c '
			source tool-sdk.sh
			mcp_download_safe --url "https://example.com/file" --out "'"$out_path"'" --allow "example.com"
		' 2>/dev/null
	)

	# Should be valid JSON and path should be properly escaped
	echo "$result" | jq -e '.success == true' >/dev/null
	echo "$result" | jq -e '.path | test("dir with spaces")' >/dev/null
}

# -----------------------------------------------------------------------------
# Default User-Agent test
# -----------------------------------------------------------------------------

@test "sdk_download_safe: sets default User-Agent from VERSION file" {
	# Create mock provider that captures the User-Agent env var
	mkdir -p "${BATS_TEST_TMPDIR}/mock_ua/providers"
	cat > "${BATS_TEST_TMPDIR}/mock_ua/providers/https.sh" << 'EOF'
#!/usr/bin/env bash
echo "${MCPBASH_HTTPS_USER_AGENT}" > "${BATS_TEST_TMPDIR}/captured_ua"
echo "content"
exit 0
EOF
	chmod +x "${BATS_TEST_TMPDIR}/mock_ua/providers/https.sh"
	cp "${MCPBASH_HOME}/sdk/tool-sdk.sh" "${BATS_TEST_TMPDIR}/mock_ua/"
	echo "1.2.3" > "${BATS_TEST_TMPDIR}/mock_ua/VERSION"

	(
		cd "${BATS_TEST_TMPDIR}/mock_ua"
		MCPBASH_HOME="${BATS_TEST_TMPDIR}/mock_ua" \
		MCPBASH_JSON_TOOL_BIN="${MCPBASH_JSON_TOOL_BIN}" \
		bash -c '
			source tool-sdk.sh
			mcp_download_safe --url "https://example.com/file" --out "'"${BATS_TEST_TMPDIR}"'/ua_out.txt" --allow "example.com"
		' 2>/dev/null
	)

	captured_ua=$(cat "${BATS_TEST_TMPDIR}/captured_ua")
	[ "$captured_ua" = "mcpbash/1.2.3 (tool-sdk)" ] || fail "Expected 'mcpbash/1.2.3 (tool-sdk)', got '$captured_ua'"
}

@test "sdk_download_safe: custom --user-agent overrides default" {
	mkdir -p "${BATS_TEST_TMPDIR}/mock_ua2/providers"
	cat > "${BATS_TEST_TMPDIR}/mock_ua2/providers/https.sh" << 'EOF'
#!/usr/bin/env bash
echo "${MCPBASH_HTTPS_USER_AGENT}" > "${BATS_TEST_TMPDIR}/captured_ua2"
echo "content"
exit 0
EOF
	chmod +x "${BATS_TEST_TMPDIR}/mock_ua2/providers/https.sh"
	cp "${MCPBASH_HOME}/sdk/tool-sdk.sh" "${BATS_TEST_TMPDIR}/mock_ua2/"
	cp "${MCPBASH_HOME}/VERSION" "${BATS_TEST_TMPDIR}/mock_ua2/"

	(
		cd "${BATS_TEST_TMPDIR}/mock_ua2"
		MCPBASH_HOME="${BATS_TEST_TMPDIR}/mock_ua2" \
		MCPBASH_JSON_TOOL_BIN="${MCPBASH_JSON_TOOL_BIN}" \
		bash -c '
			source tool-sdk.sh
			mcp_download_safe --url "https://example.com/file" --out "'"${BATS_TEST_TMPDIR}"'/ua_out2.txt" --allow "example.com" --user-agent "CustomBot/1.0"
		' 2>/dev/null
	)

	captured_ua=$(cat "${BATS_TEST_TMPDIR}/captured_ua2")
	[ "$captured_ua" = "CustomBot/1.0" ] || fail "Expected 'CustomBot/1.0', got '$captured_ua'"
}

# -----------------------------------------------------------------------------
# Allow/deny list behavior tests
# -----------------------------------------------------------------------------

@test "sdk_download_safe: multiple --allow hosts work" {
	# Create mock provider that captures the allow list
	mkdir -p "${BATS_TEST_TMPDIR}/mock_multi/providers"
	cat > "${BATS_TEST_TMPDIR}/mock_multi/providers/https.sh" << 'EOF'
#!/usr/bin/env bash
echo "${MCPBASH_HTTPS_ALLOW_HOSTS}" > "${BATS_TEST_TMPDIR}/captured_allow"
echo "content"
exit 0
EOF
	chmod +x "${BATS_TEST_TMPDIR}/mock_multi/providers/https.sh"
	cp "${MCPBASH_HOME}/sdk/tool-sdk.sh" "${BATS_TEST_TMPDIR}/mock_multi/"
	cp "${MCPBASH_HOME}/VERSION" "${BATS_TEST_TMPDIR}/mock_multi/"

	result=$(
		cd "${BATS_TEST_TMPDIR}/mock_multi"
		MCPBASH_HOME="${BATS_TEST_TMPDIR}/mock_multi" \
		MCPBASH_JSON_TOOL_BIN="${MCPBASH_JSON_TOOL_BIN}" \
		bash -c '
			source tool-sdk.sh
			mcp_download_safe --url "https://api.example.com/file" --out "'"${BATS_TEST_TMPDIR}"'/multi_out.txt" --allow "api.example.com" --allow "cdn.example.com" --allow "static.example.com"
		' 2>/dev/null
	)

	echo "$result" | jq -e '.success == true' >/dev/null
	captured_allow=$(cat "${BATS_TEST_TMPDIR}/captured_allow")
	# Should be comma-separated
	[[ "$captured_allow" == "api.example.com,cdn.example.com,static.example.com" ]] || fail "Expected comma-separated hosts, got '$captured_allow'"
}

# -----------------------------------------------------------------------------
# Temp file cleanup and edge case tests
# -----------------------------------------------------------------------------

@test "sdk_download_safe: cleans up temp file on failure" {
	# Create mock provider that fails
	mkdir -p "${BATS_TEST_TMPDIR}/mock_cleanup/providers"
	cat > "${BATS_TEST_TMPDIR}/mock_cleanup/providers/https.sh" << 'EOF'
#!/usr/bin/env bash
exit 5
EOF
	chmod +x "${BATS_TEST_TMPDIR}/mock_cleanup/providers/https.sh"
	cp "${MCPBASH_HOME}/sdk/tool-sdk.sh" "${BATS_TEST_TMPDIR}/mock_cleanup/"
	cp "${MCPBASH_HOME}/VERSION" "${BATS_TEST_TMPDIR}/mock_cleanup/"

	local out_path="${BATS_TEST_TMPDIR}/cleanup_out.txt"
	rm -f "$out_path"

	result=$(
		cd "${BATS_TEST_TMPDIR}/mock_cleanup"
		MCPBASH_HOME="${BATS_TEST_TMPDIR}/mock_cleanup" \
		MCPBASH_JSON_TOOL_BIN="${MCPBASH_JSON_TOOL_BIN}" \
		bash -c '
			source tool-sdk.sh
			mcp_download_safe --url "https://example.com/file" --out "'"$out_path"'" --allow "example.com"
		' 2>/dev/null
	)

	# On failure, output file should NOT be created (temp file cleaned up)
	echo "$result" | jq -e '.success == false' >/dev/null
	[ ! -f "$out_path" ] || fail "Output file should not exist on failure"
}

@test "sdk_download_safe: handles write failure gracefully" {
	# Create mock provider that succeeds
	mkdir -p "${BATS_TEST_TMPDIR}/mock_write/providers"
	cat > "${BATS_TEST_TMPDIR}/mock_write/providers/https.sh" << 'EOF'
#!/usr/bin/env bash
echo "content"
exit 0
EOF
	chmod +x "${BATS_TEST_TMPDIR}/mock_write/providers/https.sh"
	cp "${MCPBASH_HOME}/sdk/tool-sdk.sh" "${BATS_TEST_TMPDIR}/mock_write/"
	cp "${MCPBASH_HOME}/VERSION" "${BATS_TEST_TMPDIR}/mock_write/"

	# Try to write to a non-existent directory
	result=$(
		cd "${BATS_TEST_TMPDIR}/mock_write"
		MCPBASH_HOME="${BATS_TEST_TMPDIR}/mock_write" \
		MCPBASH_JSON_TOOL_BIN="${MCPBASH_JSON_TOOL_BIN}" \
		bash -c '
			source tool-sdk.sh
			mcp_download_safe --url "https://example.com/file" --out "/nonexistent/dir/file.txt" --allow "example.com"
		' 2>/dev/null
	)

	echo "$result" | jq -e '.success == false' >/dev/null
	echo "$result" | jq -e '.error.type == "write_error"' >/dev/null
}

@test "sdk_download_safe: retry uses exponential backoff with jitter" {
	# Create mock provider that tracks timing between calls
	mkdir -p "${BATS_TEST_TMPDIR}/mock_jitter/providers"
	cat > "${BATS_TEST_TMPDIR}/mock_jitter/providers/https.sh" << 'EOF'
#!/usr/bin/env bash
# Record timestamp in milliseconds
if command -v gdate >/dev/null 2>&1; then
	gdate +%s%3N >> "${BATS_TEST_TMPDIR}/jitter_times"
else
	date +%s%3N >> "${BATS_TEST_TMPDIR}/jitter_times" 2>/dev/null || date +%s >> "${BATS_TEST_TMPDIR}/jitter_times"
fi
exit 5
EOF
	chmod +x "${BATS_TEST_TMPDIR}/mock_jitter/providers/https.sh"
	cp "${MCPBASH_HOME}/sdk/tool-sdk.sh" "${BATS_TEST_TMPDIR}/mock_jitter/"
	cp "${MCPBASH_HOME}/VERSION" "${BATS_TEST_TMPDIR}/mock_jitter/"
	rm -f "${BATS_TEST_TMPDIR}/jitter_times"

	(
		cd "${BATS_TEST_TMPDIR}/mock_jitter"
		MCPBASH_HOME="${BATS_TEST_TMPDIR}/mock_jitter" \
		MCPBASH_JSON_TOOL_BIN="${MCPBASH_JSON_TOOL_BIN}" \
		bash -c '
			source tool-sdk.sh
			mcp_download_safe --url "https://example.com/file" --out "'"${BATS_TEST_TMPDIR}"'/jitter_out.txt" --allow "example.com" --retry 3 --retry-delay 0.1
		' 2>/dev/null
	)

	# Should have 3 timestamps (3 attempts)
	line_count=$(wc -l < "${BATS_TEST_TMPDIR}/jitter_times" | tr -d ' ')
	[ "$line_count" -eq 3 ] || fail "Expected 3 attempts, got $line_count"

	# Verify delays are present (not instant retries) and have some variance (jitter)
	# With base delay 0.1s and jitter 0-50%, delays should be 0.1-0.15s and 0.2-0.3s
	# We just verify that retries aren't instant (>50ms apart)
	times=($(cat "${BATS_TEST_TMPDIR}/jitter_times"))
	if [[ ${#times[@]} -ge 2 ]]; then
		# Check timestamps are reasonable (if we got milliseconds)
		if [[ ${times[0]} -gt 1000000000000 ]]; then
			delay1=$((${times[1]} - ${times[0]}))
			[ "$delay1" -gt 50 ] || fail "First retry delay too short: ${delay1}ms"
		fi
	fi
}

# -----------------------------------------------------------------------------
# Redirect detection tests (v2 feature)
# -----------------------------------------------------------------------------

# Helper to create mock provider that returns redirect
create_redirect_mock() {
	local location="$1"
	mkdir -p "${BATS_TEST_TMPDIR}/mock_redirect/providers"
	cat > "${BATS_TEST_TMPDIR}/mock_redirect/providers/https.sh" << EOF
#!/usr/bin/env bash
echo "redirect:${location}" >&2
exit 7
EOF
	chmod +x "${BATS_TEST_TMPDIR}/mock_redirect/providers/https.sh"
	cp "${MCPBASH_HOME}/sdk/tool-sdk.sh" "${BATS_TEST_TMPDIR}/mock_redirect/"
	cp "${MCPBASH_HOME}/VERSION" "${BATS_TEST_TMPDIR}/mock_redirect/"
}

run_redirect_mock() {
	(
		cd "${BATS_TEST_TMPDIR}/mock_redirect"
		MCPBASH_HOME="${BATS_TEST_TMPDIR}/mock_redirect" \
		MCPBASH_JSON_TOOL_BIN="${MCPBASH_JSON_TOOL_BIN}" \
		bash -c 'source tool-sdk.sh; mcp_download_safe '"$*"'' 2>/dev/null
	)
}

@test "sdk_download_safe: returns redirect error with location" {
	create_redirect_mock "https://www.example.com/canonical"
	result=$(run_redirect_mock --url "https://example.com/page" \
		--out "${BATS_TEST_TMPDIR}/out.txt" --allow "example.com")

	echo "$result" | jq -e '.success == false' >/dev/null
	echo "$result" | jq -e '.error.type == "redirect"' >/dev/null
	echo "$result" | jq -e '.error.location == "https://www.example.com/canonical"' >/dev/null
}

@test "sdk_download_safe: does not retry redirects" {
	mkdir -p "${BATS_TEST_TMPDIR}/mock_redirect_count/providers"
	cat > "${BATS_TEST_TMPDIR}/mock_redirect_count/providers/https.sh" << 'EOF'
#!/usr/bin/env bash
echo "1" >> "${BATS_TEST_TMPDIR}/redirect_call_count"
echo "redirect:https://www.example.com/" >&2
exit 7
EOF
	chmod +x "${BATS_TEST_TMPDIR}/mock_redirect_count/providers/https.sh"
	cp "${MCPBASH_HOME}/sdk/tool-sdk.sh" "${BATS_TEST_TMPDIR}/mock_redirect_count/"
	cp "${MCPBASH_HOME}/VERSION" "${BATS_TEST_TMPDIR}/mock_redirect_count/"
	rm -f "${BATS_TEST_TMPDIR}/redirect_call_count"

	(
		cd "${BATS_TEST_TMPDIR}/mock_redirect_count"
		MCPBASH_HOME="${BATS_TEST_TMPDIR}/mock_redirect_count" \
		MCPBASH_JSON_TOOL_BIN="${MCPBASH_JSON_TOOL_BIN}" \
		bash -c 'source tool-sdk.sh; mcp_download_safe --url "https://example.com/" \
			--out "'"${BATS_TEST_TMPDIR}"'/out.txt" --allow "example.com" --retry 3' 2>/dev/null
	)

	call_count=$(wc -l < "${BATS_TEST_TMPDIR}/redirect_call_count" | tr -d ' ')
	[ "$call_count" -eq 1 ] || fail "Expected 1 call (no retries), got $call_count"
}

@test "sdk_download_safe: handles special characters in redirect location" {
	# Test with URL containing query params, unicode, and special chars
	create_redirect_mock 'https://example.com/path?foo=bar&baz=qux#anchor'
	result=$(run_redirect_mock --url "https://example.com/page" \
		--out "${BATS_TEST_TMPDIR}/out.txt" --allow "example.com")

	echo "$result" | jq -e '.error.type == "redirect"' >/dev/null
	echo "$result" | jq -e '.error.location == "https://example.com/path?foo=bar&baz=qux#anchor"' >/dev/null
}

@test "sdk_download_safe: strips CRLF line endings from redirect location" {
	# Test that Windows-style \r\n line endings are properly stripped
	mkdir -p "${BATS_TEST_TMPDIR}/mock_crlf/providers"
	cat > "${BATS_TEST_TMPDIR}/mock_crlf/providers/https.sh" << 'EOF'
#!/usr/bin/env bash
# Simulate redirect with CRLF line ending (as some Windows/IIS servers send)
printf 'redirect:https://www.example.com/crlf\r\n' >&2
exit 7
EOF
	chmod +x "${BATS_TEST_TMPDIR}/mock_crlf/providers/https.sh"
	cp "${MCPBASH_HOME}/sdk/tool-sdk.sh" "${BATS_TEST_TMPDIR}/mock_crlf/"
	cp "${MCPBASH_HOME}/VERSION" "${BATS_TEST_TMPDIR}/mock_crlf/"

	result=$(
		cd "${BATS_TEST_TMPDIR}/mock_crlf"
		MCPBASH_HOME="${BATS_TEST_TMPDIR}/mock_crlf" \
		MCPBASH_JSON_TOOL_BIN="${MCPBASH_JSON_TOOL_BIN}" \
		bash -c 'source tool-sdk.sh; mcp_download_safe --url "https://example.com/page" \
			--out "'"${BATS_TEST_TMPDIR}"'/out.txt" --allow "example.com"' 2>/dev/null
	)

	echo "$result" | jq -e '.error.type == "redirect"' >/dev/null
	# Verify the location has NO trailing \r or \n
	echo "$result" | jq -e '.error.location == "https://www.example.com/crlf"' >/dev/null
}

@test "sdk_download_safe: handles redirect with empty Location header" {
	# Create mock that returns redirect but no location
	mkdir -p "${BATS_TEST_TMPDIR}/mock_empty_loc/providers"
	cat > "${BATS_TEST_TMPDIR}/mock_empty_loc/providers/https.sh" << 'EOF'
#!/usr/bin/env bash
echo "redirect:" >&2
exit 7
EOF
	chmod +x "${BATS_TEST_TMPDIR}/mock_empty_loc/providers/https.sh"
	cp "${MCPBASH_HOME}/sdk/tool-sdk.sh" "${BATS_TEST_TMPDIR}/mock_empty_loc/"
	cp "${MCPBASH_HOME}/VERSION" "${BATS_TEST_TMPDIR}/mock_empty_loc/"

	result=$(
		cd "${BATS_TEST_TMPDIR}/mock_empty_loc"
		MCPBASH_HOME="${BATS_TEST_TMPDIR}/mock_empty_loc" \
		MCPBASH_JSON_TOOL_BIN="${MCPBASH_JSON_TOOL_BIN}" \
		bash -c 'source tool-sdk.sh; mcp_download_safe --url "https://example.com/page" \
			--out "'"${BATS_TEST_TMPDIR}"'/out.txt" --allow "example.com"' 2>/dev/null
	)

	# Should still report redirect error, but location unavailable
	echo "$result" | jq -e '.success == false' >/dev/null
	echo "$result" | jq -e '.error.type == "redirect"' >/dev/null
	echo "$result" | jq -e '(.error.location // null) == null' >/dev/null
	echo "$result" | jq -e '.error.message | test("location unavailable")' >/dev/null
}

# -----------------------------------------------------------------------------
# Fail-fast wrapper tests (v2 feature)
# -----------------------------------------------------------------------------

@test "sdk_download_safe_or_fail: returns path on success" {
	mkdir -p "${BATS_TEST_TMPDIR}/mock_ff_success/providers"
	cat > "${BATS_TEST_TMPDIR}/mock_ff_success/providers/https.sh" << 'EOF'
#!/usr/bin/env bash
echo "content"
exit 0
EOF
	chmod +x "${BATS_TEST_TMPDIR}/mock_ff_success/providers/https.sh"
	cp "${MCPBASH_HOME}/sdk/tool-sdk.sh" "${BATS_TEST_TMPDIR}/mock_ff_success/"
	cp "${MCPBASH_HOME}/VERSION" "${BATS_TEST_TMPDIR}/mock_ff_success/"

	path=$(
		cd "${BATS_TEST_TMPDIR}/mock_ff_success"
		MCPBASH_HOME="${BATS_TEST_TMPDIR}/mock_ff_success" \
		MCPBASH_JSON_TOOL_BIN="${MCPBASH_JSON_TOOL_BIN}" \
		bash -c 'source tool-sdk.sh; mcp_download_safe_or_fail --url "https://example.com/file" \
			--out "'"${BATS_TEST_TMPDIR}"'/ff_out.txt" --allow "example.com"' 2>/dev/null
	)

	[ "$path" = "${BATS_TEST_TMPDIR}/ff_out.txt" ] || fail "Expected path '${BATS_TEST_TMPDIR}/ff_out.txt', got '$path'"
}

@test "sdk_download_safe_or_fail: emits -32602 error on failure" {
	create_mock_provider 5 "connection refused"

	# Capture the MCP error output
	output=$(
		cd "${BATS_TEST_TMPDIR}/mock_provider"
		MCPBASH_HOME="${BATS_TEST_TMPDIR}/mock_provider" \
		MCPBASH_JSON_TOOL_BIN="${MCPBASH_JSON_TOOL_BIN}" \
		bash -c 'source tool-sdk.sh; mcp_download_safe_or_fail --url "https://example.com/file" \
			--out "/tmp/out.txt" --allow "example.com"' 2>/dev/null || true
	)

	# mcp_fail_invalid_args outputs: {"code":-32602,"message":"...","data":null}
	echo "$output" | jq -e '.code == -32602' >/dev/null
}

@test "sdk_download_safe_or_fail: works in minimal mode" {
	mkdir -p "${BATS_TEST_TMPDIR}/mock_ff_minimal/providers"
	cat > "${BATS_TEST_TMPDIR}/mock_ff_minimal/providers/https.sh" << 'EOF'
#!/usr/bin/env bash
echo "content"
exit 0
EOF
	chmod +x "${BATS_TEST_TMPDIR}/mock_ff_minimal/providers/https.sh"
	cp "${MCPBASH_HOME}/sdk/tool-sdk.sh" "${BATS_TEST_TMPDIR}/mock_ff_minimal/"
	cp "${MCPBASH_HOME}/VERSION" "${BATS_TEST_TMPDIR}/mock_ff_minimal/"

	path=$(
		cd "${BATS_TEST_TMPDIR}/mock_ff_minimal"
		MCPBASH_HOME="${BATS_TEST_TMPDIR}/mock_ff_minimal" \
		MCPBASH_MODE="minimal" \
		MCPBASH_JSON_TOOL_BIN="" \
		bash -c 'source tool-sdk.sh; mcp_download_safe_or_fail --url "https://example.com/file" \
			--out "'"${BATS_TEST_TMPDIR}"'/ff_minimal_out.txt" --allow "example.com"' 2>/dev/null
	)

	[ "$path" = "${BATS_TEST_TMPDIR}/ff_minimal_out.txt" ] || fail "Expected path in minimal mode, got '$path'"
}

@test "sdk_download_safe_or_fail: includes error type in failure message" {
	create_redirect_mock "https://www.example.com/target"

	output=$(
		cd "${BATS_TEST_TMPDIR}/mock_redirect"
		MCPBASH_HOME="${BATS_TEST_TMPDIR}/mock_redirect" \
		MCPBASH_JSON_TOOL_BIN="${MCPBASH_JSON_TOOL_BIN}" \
		bash -c 'source tool-sdk.sh; mcp_download_safe_or_fail --url "https://example.com/file" \
			--out "/tmp/out.txt" --allow "example.com"' 2>/dev/null || true
	)

	# Should include "redirect" in the error message
	echo "$output" | jq -e '.message | test("redirect")' >/dev/null
}
