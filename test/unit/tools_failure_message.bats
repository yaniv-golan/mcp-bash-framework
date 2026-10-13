#!/usr/bin/env bats
# Unit layer: the text of a failed tool's error result (mcp_tools_failure_message).

load '../../node_modules/bats-support/load'
load '../../node_modules/bats-assert/load'
load '../common/fixtures'

# failure_message STDOUT_FILE STDERR_TAIL [LIMIT]
failure_message() {
	MCPBASH_JSON_TOOL_BIN="${JQ:-jq}" "${BASH}" -c '. "${MCPBASH_HOME}/lib/tools.sh"; mcp_tools_failure_message "$1" "$2" true "${3:-4096}"' _ "$@"
}

@test "failure message: a huge 1.x error message is capped, quickly" {
	local f="${BATS_TEST_TMPDIR}/big.json"
	{
		printf '{"code":5,"message":"'
		head -c 3000000 /dev/zero | tr '\0' 'x'
		printf '"}\n'
	} >"${f}"
	local start=${SECONDS}
	run failure_message "${f}" ""
	assert_success
	assert_equal "${#output}" "4096"
	# Expanding the whole 3 MB string took ~11 s under bash 3.2.
	[ $((SECONDS - start)) -lt 5 ] || fail "took $((SECONDS - start)) s"
}

@test "failure message: only a single 1.x error object gives the message" {
	local f="${BATS_TEST_TMPDIR}/two.json"
	printf '%s\n%s\n' '{"code":1,"message":"a"}' '{"code":1,"message":"b"}' >"${f}"
	run failure_message "${f}" "the real error"
	assert_output "the real error"
}

@test "failure message: an object without a numeric code is not an error message" {
	local f="${BATS_TEST_TMPDIR}/payload.json"
	printf '%s\n' '{"message":"a commit message"}' >"${f}"
	run failure_message "${f}" "the real error"
	assert_output "the real error"
	printf '%s\n' '{"code":1,"message":"from stdout"}' >"${f}"
	run failure_message "${f}" "the real error"
	assert_output "from stdout"
}

@test "failure message: falls back to the end of stdout, then to nothing" {
	local f="${BATS_TEST_TMPDIR}/plain.txt"
	printf 'line one\nlast words\n' >"${f}"
	run failure_message "${f}" "  "
	assert_output $'line one\nlast words'
	: >"${f}"
	run failure_message "${f}" ""
	assert_output ""
}
