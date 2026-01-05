#!/usr/bin/env bats
# Unit layer: SDK JSON helpers fallback paths (no gojq/jq in PATH).

load '../../node_modules/bats-support/load'
load '../../node_modules/bats-assert/load'
load '../common/fixtures'

setup() {
	# shellcheck source=sdk/tool-sdk.sh
	# shellcheck disable=SC1091
	. "${MCPBASH_HOME}/sdk/tool-sdk.sh"

	REAL_JQ_BIN="${TEST_JSON_TOOL_BIN}"
}

run_in_minimal_json_env() {
	local script="$1"
	bash -c '
set -euo pipefail
REPO_ROOT="$1"
REAL_JQ_BIN="$2"

export PATH="/usr/bin:/bin:/usr/sbin:/sbin"
unset MCPBASH_JSON_TOOL MCPBASH_JSON_TOOL_BIN

. "${REPO_ROOT}/sdk/tool-sdk.sh"

case "'"${script}"'" in
escape)
	out="$(mcp_json_escape "value \"with\" emoji 😄 and
newlines")"
	;;
obj)
	out="$(mcp_json_obj message "Hello \"World\"" empty "" unicode "snowman ☃")"
	;;
arr)
	out="$(mcp_json_arr "one" "two" "three" "" "emoji 😄")"
	;;
esac

printf "%s\n" "${out}"
' _ "${MCPBASH_HOME}" "${REAL_JQ_BIN}"
}

@test "sdk_json_fallback: escape produces valid JSON" {
	escaped="$(run_in_minimal_json_env escape)"
	run printf '%s\n' "${escaped}"
	run bash -c "printf '%s\n' '${escaped}' | ${REAL_JQ_BIN} -e '.'"
	assert_success
}

@test "sdk_json_fallback: obj produces valid JSON" {
	obj="$(run_in_minimal_json_env obj)"
	run bash -c "printf '%s\n' '${obj}' | ${REAL_JQ_BIN} -e '.'"
	assert_success
}

@test "sdk_json_fallback: arr produces valid JSON" {
	arr="$(run_in_minimal_json_env arr)"
	run bash -c "printf '%s\n' '${arr}' | ${REAL_JQ_BIN} -e '.'"
	assert_success
}

@test "sdk_json_fallback: escape uses jq fallback when MCPBASH_JSON_TOOL_BIN is unset" {
	unset MCPBASH_JSON_TOOL_BIN
	escaped_jq="$(mcp_json_escape 'via jq fallback')"
	run bash -c "printf '%s\n' '${escaped_jq}' | ${REAL_JQ_BIN} -e '.'"
	assert_success
}
