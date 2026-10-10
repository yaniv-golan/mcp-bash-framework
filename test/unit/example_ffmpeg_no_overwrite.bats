#!/usr/bin/env bats
# Unit: the ffmpeg-studio example stops after an early error result.
# An error result does not end a tool by itself. The tool used to fall through
# to ffprobe/ffmpeg -y after refusing to overwrite an existing output (or after
# an invalid preset / missing input), so a refusal could still touch the file.
# Fake ffmpeg/ffprobe on PATH record any invocation.

load '../../node_modules/bats-support/load'
load '../../node_modules/bats-assert/load'
load '../common/fixtures'

setup() {
	command -v jq >/dev/null 2>&1 || skip "jq not available"
	PROJ="${BATS_TEST_TMPDIR}/ffmpeg-studio"
	cp -R "${MCPBASH_HOME}/examples/advanced/ffmpeg-studio" "${PROJ}"
	cp "${PROJ}/media/example.mp4" "${PROJ}/media/in.mp4"
	printf 'keep-me' >"${PROJ}/media/out.mp4"
	FAKEBIN="${BATS_TEST_TMPDIR}/bin"
	CALLS="${BATS_TEST_TMPDIR}/calls"
	mkdir -p "${FAKEBIN}"
	local b
	for b in ffmpeg ffprobe; do
		printf '#!/bin/sh\necho %s >>"%s"\nexit 1\n' "${b}" "${CALLS}" >"${FAKEBIN}/${b}"
		chmod +x "${FAKEBIN}/${b}"
	done
}

run_tool() {
	run env PATH="${FAKEBIN}:${PATH}" MCPBASH_TOOL_ALLOWLIST='*' \
		"${MCPBASH_HOME}/bin/mcp-bash" run-tool "$1" --project-root "${PROJ}" --args "$2"
}

# The tool's own refusal must arrive as one isError result, not a protocol
# error (outputSchema validation is skipped for isError results).
assert_single_error_result() {
	assert_equal "$(printf '%s' "${output}" | jq -s 'length' 2>/dev/null)" "1"
	assert_equal "$(printf '%s' "${output}" | jq -r '._mcpToolError // false')" "false"
	assert_equal "$(printf '%s' "${output}" | jq -r '.isError')" "true"
}

@test "example ffmpeg: existing output without elicitation is refused, nothing runs, file intact" {
	run_tool transcode '{"input":"in.mp4","output":"out.mp4","preset":"720p"}'
	assert_single_error_result
	[ ! -e "${CALLS}" ]
	assert_equal "$(cat "${PROJ}/media/out.mp4")" "keep-me"
}

@test "example ffmpeg: an invalid preset stops before ffprobe/ffmpeg" {
	run_tool transcode '{"input":"in.mp4","output":"new.mp4","preset":"bogus"}'
	assert_single_error_result
	[ ! -e "${CALLS}" ]
}

@test "example ffmpeg: a missing input stops before ffprobe" {
	run_tool inspect_media '{"path":"nope.mp4"}'
	# A missing path is rejected by the example's path resolver with mcp_fail,
	# which is a protocol error in 1.x (it becomes isError in 2.0).
	assert_equal "$(printf '%s' "${output}" | jq -s 'length' 2>/dev/null)" "1"
	assert_equal "$(printf '%s' "${output}" | jq -r '(.isError // false) or (._mcpToolError // false)')" "true"
	[ ! -e "${CALLS}" ]
}
