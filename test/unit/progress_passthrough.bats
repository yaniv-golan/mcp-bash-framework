#!/usr/bin/env bats
# Unit layer: SDK mcp_run_with_progress helper function.

load '../../node_modules/bats-support/load'
load '../../node_modules/bats-assert/load'
load '../common/fixtures'

setup() {
	# Source runtime for logging and JSON detection
	# shellcheck source=lib/runtime.sh
	# shellcheck disable=SC1091
	. "${MCPBASH_HOME}/lib/runtime.sh"

	mcp_runtime_detect_json_tool

	# Source SDK (includes progress-passthrough)
	# shellcheck source=sdk/tool-sdk.sh
	# shellcheck disable=SC1091
	. "${MCPBASH_HOME}/sdk/tool-sdk.sh"

	# Path to test fixtures
	FIXTURES_DIR="${MCPBASH_HOME}/test/common/fixtures"
}

@test "progress_passthrough: requires --pattern argument" {
	run mcp_run_with_progress -- echo test
	assert_failure
	assert_output --partial "--pattern is required"
}

@test "progress_passthrough: rejects invalid --extract mode" {
	run mcp_run_with_progress --pattern 'test' --extract invalid -- echo test
	assert_failure
	assert_output --partial "unknown extract mode"
}

@test "progress_passthrough: rejects non-positive --total" {
	run mcp_run_with_progress --pattern 'test' --total 0 -- echo test
	assert_failure
	assert_output --partial "--total must be positive integer"
}

@test "progress_passthrough: rejects non-numeric --total" {
	run mcp_run_with_progress --pattern 'test' --total abc -- echo test
	assert_failure
	assert_output --partial "--total must be positive integer"
}

@test "progress_passthrough: rejects zero --interval" {
	run mcp_run_with_progress --pattern 'test' --interval 0 -- echo test
	assert_failure
	assert_output --partial "--interval must be a positive number"
}

@test "progress_passthrough: json extraction with dry-run" {
	run mcp_run_with_progress \
		--pattern '^\{.*"progress"' \
		--extract json \
		--dry-run \
		--quiet \
		-- "${FIXTURES_DIR}/mock-progress.sh" --fast

	assert_success
	# stdout should have the result JSON
	assert_output --partial '"result":"success"'
}

@test "progress_passthrough: json extraction emits progress to stderr in dry-run" {
	# Capture stderr separately
	local stderr_file="${BATS_TEST_TMPDIR}/stderr"
	local stdout_file="${BATS_TEST_TMPDIR}/stdout"
	run mcp_run_with_progress \
		--pattern '^\{.*"progress"' \
		--extract json \
		--dry-run \
		--quiet \
		-- "${FIXTURES_DIR}/mock-progress.sh" --fast

	assert_success
	# stderr from dry-run goes to bats output
	assert_output --partial '"progress":0'
	assert_output --partial '"progress":100'
}

@test "progress_passthrough: match1 extraction with percentage pattern" {
	run mcp_run_with_progress \
		--pattern '([0-9]+)%' \
		--extract match1 \
		--dry-run \
		--quiet \
		-- "${FIXTURES_DIR}/mock-percent.sh" --fast

	assert_success
	# output should have progress and "Done"
	assert_output --partial "Done"
	assert_output --partial '"progress":10'
}

@test "progress_passthrough: ratio extraction with counter pattern" {
	run mcp_run_with_progress \
		--pattern '\[([0-9]+)/([0-9]+)\]' \
		--extract ratio \
		--dry-run \
		--quiet \
		-- "${FIXTURES_DIR}/mock-counter.sh" --fast --total 5

	assert_success
	# Should have 20%, 40%, 60%, 80%, 100% (1/5, 2/5, 3/5, 4/5, 5/5)
	assert_output --partial '"progress":20'
}

@test "progress_passthrough: preserves subprocess exit code" {
	run mcp_run_with_progress \
		--pattern '^\{.*"progress"' \
		--extract json \
		--dry-run \
		--quiet \
		-- "${FIXTURES_DIR}/mock-progress.sh" --fast --fail

	assert_failure
	assert_equal "$status" 1
}

@test "progress_passthrough: captures stdout to file with --stdout" {
	local stdout_file="${BATS_TEST_TMPDIR}/stdout"
	run mcp_run_with_progress \
		--pattern '^\{.*"progress"' \
		--extract json \
		--dry-run \
		--quiet \
		--stdout "${stdout_file}" \
		-- "${FIXTURES_DIR}/mock-progress.sh" --fast

	assert_success
	assert [ -f "${stdout_file}" ]
	run cat "${stdout_file}"
	assert_output --partial '"result":"success"'
}

@test "progress_passthrough: match1 with --total calculates percentage" {
	# Create a mock that outputs raw values
	local mock_script="${BATS_TEST_TMPDIR}/mock-raw.sh"
	cat >"${mock_script}" <<'EOF'
#!/usr/bin/env bash
for i in 25 50 75 100; do
    echo "Progress: ${i}" >&2
done
echo "done"
EOF
	chmod +x "${mock_script}"

	run mcp_run_with_progress \
		--pattern 'Progress: ([0-9]+)' \
		--extract match1 \
		--total 100 \
		--dry-run \
		--quiet \
		-- "${mock_script}"

	assert_success
	# Should have calculated percentages
	assert_output --partial '"progress":25'
	assert_output --partial '"progress":100'
}

@test "progress_passthrough: handles empty stderr gracefully" {
	run mcp_run_with_progress \
		--pattern 'never-match' \
		--extract json \
		--dry-run \
		--quiet \
		-- echo "no progress here"

	assert_success
	assert_output "no progress here"
}

@test "progress_passthrough: handles malformed JSON gracefully" {
	local mock_script="${BATS_TEST_TMPDIR}/mock-bad-json.sh"
	cat >"${mock_script}" <<'EOF'
#!/usr/bin/env bash
echo '{"progress":50,"message":"good"}' >&2
echo 'not json at all' >&2
echo '{"progress":"invalid"}' >&2
echo '{"progress":100,"message":"done"}' >&2
echo "result"
EOF
	chmod +x "${mock_script}"

	run mcp_run_with_progress \
		--pattern '^\{' \
		--extract json \
		--dry-run \
		--quiet \
		-- "${mock_script}"

	assert_success
	# Should still capture valid progress
	assert_output --partial '"progress":50'
	assert_output --partial '"progress":100'
}

# Integration test with real ffmpeg (skipped if ffmpeg not available)
@test "progress_passthrough: ffmpeg integration with --progress-file" {
	# Skip if ffmpeg/ffprobe not available
	if ! command -v ffmpeg >/dev/null 2>&1; then
		skip "ffmpeg not installed"
	fi
	if ! command -v ffprobe >/dev/null 2>&1; then
		skip "ffprobe not installed"
	fi

	local input_file="${MCPBASH_HOME}/examples/advanced/ffmpeg-studio/media/example.mp4"
	if [[ ! -f "$input_file" ]]; then
		skip "example.mp4 not found"
	fi

	local output_file="${BATS_TEST_TMPDIR}/output.mp4"
	local progress_file="${BATS_TEST_TMPDIR}/ffprogress"

	# Get total duration in microseconds
	local total_us
	total_us=$(ffprobe -v error -show_entries format=duration \
		-of default=noprint_wrappers=1:nokey=1 "$input_file" 2>/dev/null | awk '{print int($1*1000000)}')

	[[ -n "$total_us" && "$total_us" -gt 0 ]] || skip "Could not get video duration"

	# Run ffmpeg with progress passthrough (transcode first 1 second for speed)
	run mcp_run_with_progress \
		--progress-file "$progress_file" \
		--total "$total_us" \
		--pattern '^out_time_us=([0-9]+)' \
		--extract match1 \
		--dry-run \
		--quiet \
		--interval 0.1 \
		-- ffmpeg -y -i "$input_file" -t 1 -c:v libx264 -preset ultrafast -c:a aac \
		   -progress "$progress_file" "$output_file"

	assert_success

	# Should have output file
	assert [ -f "$output_file" ]

	# Should have emitted some progress (dry-run outputs to combined stdout/stderr)
	# Progress values will be percentages based on out_time_us / total_us
	assert_output --partial '"progress":'
}

@test "progress_passthrough: --stderr-file captures non-progress lines" {
	local stderr_out="${BATS_TEST_TMPDIR}/stderr"

	# Create mock script
	local mock_script="${BATS_TEST_TMPDIR}/mock.sh"
	cat >"${mock_script}" <<'EOF'
#!/usr/bin/env bash
echo '{"type":"progress","progress":50,"message":"Working"}' >&2
echo "Warning: something happened" >&2
echo "Error: validation failed" >&2
echo '{"result":"ok"}'
EOF

	# Use 'bash' to invoke (execute bits unreliable on Windows per windows-compatibility.mdc)
	run mcp_run_with_progress \
		--pattern '^\{.*"type".*"progress"' \
		--extract json \
		--stderr-file "$stderr_out" \
		--dry-run \
		--quiet \
		-- bash "${mock_script}"

	assert_success
	assert [ -f "$stderr_out" ]

	# Verify non-progress lines captured
	run grep "Warning: something happened" "$stderr_out"
	assert_success
	run grep "Error: validation failed" "$stderr_out"
	assert_success

	# Verify progress lines NOT captured (they go to mcp_progress)
	run grep "progress" "$stderr_out"
	assert_failure
}

@test "progress_passthrough: --stderr-file creates empty file when no non-progress output" {
	local stderr_out="${BATS_TEST_TMPDIR}/stderr"

	# Mock CLI with only progress output
	local mock_script="${BATS_TEST_TMPDIR}/mock.sh"
	cat >"${mock_script}" <<'EOF'
#!/usr/bin/env bash
echo '{"type":"progress","progress":100,"message":"Done"}' >&2
echo '{"result":"ok"}'
EOF

	run mcp_run_with_progress \
		--pattern '^\{.*"type".*"progress"' \
		--extract json \
		--stderr-file "$stderr_out" \
		--dry-run \
		--quiet \
		-- bash "${mock_script}"

	assert_success
	# File should exist but be empty
	assert [ -f "$stderr_out" ]
	assert [ ! -s "$stderr_out" ]
}

@test "progress_passthrough: --stderr-file works with --quiet" {
	local stderr_out="${BATS_TEST_TMPDIR}/stderr"

	run mcp_run_with_progress \
		--pattern '^\{.*"progress"' \
		--extract json \
		--stderr-file "$stderr_out" \
		--quiet \
		--dry-run \
		-- bash -c 'echo "Error message" >&2; echo "{}"'

	assert_success
	run grep "Error message" "$stderr_out"
	assert_success
}

@test "progress_passthrough: --stderr-file handles interleaved progress and errors" {
	local stderr_out="${BATS_TEST_TMPDIR}/stderr"

	local mock_script="${BATS_TEST_TMPDIR}/mock.sh"
	cat >"${mock_script}" <<'EOF'
#!/usr/bin/env bash
echo '{"type":"progress","progress":25,"message":"Step 1"}' >&2
echo "Info: processing batch 1" >&2
echo '{"type":"progress","progress":50,"message":"Step 2"}' >&2
echo "Warning: slow response" >&2
echo '{"type":"progress","progress":100,"message":"Done"}' >&2
echo '{"result":"ok"}'
EOF

	run mcp_run_with_progress \
		--pattern '^\{.*"type".*"progress"' \
		--extract json \
		--stderr-file "$stderr_out" \
		--dry-run \
		--quiet \
		-- bash "${mock_script}"

	assert_success

	# Check both lines captured
	run grep "Info: processing batch 1" "$stderr_out"
	assert_success
	run grep "Warning: slow response" "$stderr_out"
	assert_success
}

@test "progress_passthrough: --stderr-file warns on unwritable path" {
	run mcp_run_with_progress \
		--pattern '^\{.*"progress"' \
		--stderr-file "/nonexistent/path/file" \
		--dry-run \
		--quiet \
		-- bash -c 'echo "{}" >&2; echo "ok"'

	# Should succeed despite warning (doesn't break progress forwarding)
	assert_success
}
