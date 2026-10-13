#!/usr/bin/env bats
# Unit layer: the per-call check for SDK helpers removed in 2.0. It must
# block only a likely call in the tool's own shell script.

load '../../node_modules/bats-support/load'
load '../../node_modules/bats-assert/load'
load '../common/fixtures'

setup() {
	MCPBASH_JSON_TOOL_BIN="jq"
	# shellcheck source=lib/tools.sh
	# shellcheck disable=SC1091
	. "${MCPBASH_HOME}/lib/tools.sh"
	TOOL_DIR="${BATS_TEST_TMPDIR}/tools/t"
	mkdir -p "${TOOL_DIR}"
}

# tool BODY [NAME]: write a bash tool script and print its path.
tool() {
	local path="${TOOL_DIR}/${2:-tool.sh}"
	printf '#!/usr/bin/env bash\n%s\n' "$1" >"${path}"
	printf '%s' "${path}"
}

check() {
	run mcp_tools_removed_api_use "$1"
	assert_success
}

@test "removed api: a plain call is found" {
	check "$(tool 'mcp_error not_found "x"')"
	assert_output "mcp_error"
}

@test "removed api: calls after then, &&, ||, !, { and in a case arm are found" {
	check "$(tool 'if true; then mcp_error a b; fi')"
	assert_output "mcp_error"
	check "$(tool '[ -n "$x" ] && mcp_result_error "{}"')"
	assert_output "mcp_result_error"
	check "$(tool 'false || mcp_fail_invalid_args x')"
	assert_output "mcp_fail_invalid_args"
	check "$(tool '! mcp_emit_text x')"
	assert_output "mcp_emit_text"
	check "$(tool '{ mcp_emit_json "{}"; exit 0; }')"
	assert_output "mcp_emit_json"
	check "$(tool "$(printf 'case "$1" in\n a) mcp_error x y ;;\nesac')")"
	assert_output "mcp_error"
}

@test "removed api: calls in \$(...), backticks and after an assignment prefix are found" {
	check "$(tool 'out="$(mcp_result_success "$x")"')"
	assert_output "mcp_result_success"
	check "$(tool 'out=`mcp_result_success x`')"
	assert_output "mcp_result_success"
	check "$(tool 'X=1 mcp_result_with_ui "" t')"
	assert_output "mcp_result_with_ui"
}

@test "removed api: a call after a heredoc and a continued line is found" {
	check "$(tool "$(printf 'cat <<EOF\nmcp_error x\nEOF\nmcp_result_text_with_resource x')")"
	assert_output "mcp_result_text_with_resource"
	check "$(tool "$(printf 'mcp_result_text \\\n  "a"\nmcp_result_with_ui_data "" t "{}"')")"
	assert_output "mcp_result_with_ui_data"
}

@test "removed api: a name in a string, heredoc, comment or argument is not a call" {
	check "$(tool 'mcp_result_text "mcp_error was removed in 2.0"')"
	assert_output ""
	check "$(tool "echo 'mcp_error a b'")"
	assert_output ""
	check "$(tool "$(printf 'cat <<EOF\nmcp_result_success x\nEOF\nmcp_result_text ok')")"
	assert_output ""
	check "$(tool "$(printf "cat <<-'EOF'\n\tmcp_result_success x\n\tEOF")")"
	assert_output ""
	check "$(tool 'mcp_result_text ok # was mcp_error before')"
	assert_output ""
	check "$(tool '# mcp_error')"
	assert_output ""
	check "$(tool 'echo mcp_error >&2')"
	assert_output ""
	check "$(tool "$(printf 'echo "multi\nmcp_error line"')")"
	assert_output ""
	check "$(tool 'cat <<< "mcp_error"')"
	assert_output ""
}

@test "removed api: a variable, a longer name or a function of the same name is not a call" {
	check "$(tool 'mcp_error=1')"
	assert_output ""
	check "$(tool 'my_mcp_error_count=3; my_mcp_error_count')"
	assert_output ""
	check "$(tool "$(printf 'mcp_error() { mcp_fail --type "$1" "$2"; }\nmcp_error a b')")"
	assert_output ""
	check "$(tool "$(printf 'function mcp_error {\n  :\n}\nmcp_error a b')")"
	assert_output ""
}

@test "removed api: only the tool's own script is read" {
	# Another tool in the same directory, a nested tool and an unsourced
	# script don't block this one.
	tool 'mcp_error not_found x' bad.sh >/dev/null
	mkdir -p "${TOOL_DIR}/child" "${TOOL_DIR}/tests"
	printf '#!/usr/bin/env bash\nmcp_result_success x\n' >"${TOOL_DIR}/child/tool.sh"
	printf '#!/usr/bin/env bash\nmcp_error x y\n' >"${TOOL_DIR}/tests/old_test.sh"
	check "$(tool 'mcp_result_text ok' ok.sh)"
	assert_output ""
	# A register.json tool at the top of tools/ (the scan root used to be
	# tools/ itself).
	printf '#!/usr/bin/env bash\nmcp_result_text ok\n' >"${BATS_TEST_TMPDIR}/tools/top.sh"
	check "${BATS_TEST_TMPDIR}/tools/top.sh"
	assert_output ""
}

@test "removed api: a non-shell tool is not read" {
	printf '#!/usr/bin/env python3\nprint("mcp_error")\nmcp_error\n' >"${TOOL_DIR}/tool.py"
	check "${TOOL_DIR}/tool.py"
	assert_output ""
	printf 'mcp_error x\n' >"${TOOL_DIR}/tool"
	check "${TOOL_DIR}/tool"
	assert_output ""
	printf '#!/bin/sh\nmcp_error x\n' >"${TOOL_DIR}/run"
	check "${TOOL_DIR}/run"
	assert_output "mcp_error"
}

@test "removed api: the result is cached per script until the script changes" {
	MCPBASH_STATE_DIR="${BATS_TEST_TMPDIR}/state"
	mkdir -p "${MCPBASH_STATE_DIR}"
	local path
	path="$(tool 'mcp_error not_found x')"
	touch -t 202001010000 "${path}"
	mcp_tools_removed_api_check "${path}"
	assert_equal "${MCP_TOOLS_REMOVED_API_HIT}" "mcp_error"
	# A cache hit doesn't run awk: a broken program doesn't change the answer.
	local saved="${MCP_TOOLS_REMOVED_API_AWK}"
	MCP_TOOLS_REMOVED_API_AWK='BEGIN { print "wrong"; exit }'
	mcp_tools_removed_api_check "${path}"
	assert_equal "${MCP_TOOLS_REMOVED_API_HIT}" "mcp_error"
	MCP_TOOLS_REMOVED_API_AWK="${saved}"
	# Edited in place (newer than the cache): read again.
	printf '#!/usr/bin/env bash\nmcp_result_text ok\n' >"${path}"
	touch -t 203001010000 "${path}"
	mcp_tools_removed_api_check "${path}"
	assert_equal "${MCP_TOOLS_REMOVED_API_HIT}" ""
}
