#!/usr/bin/env bats
# Unit layer: scaffold outputs canonical tool files.

load '../../node_modules/bats-support/load'
load '../../node_modules/bats-assert/load'
load '../../node_modules/bats-file/load'
load '../common/fixtures'

setup() {
	PROJECT_ROOT="${BATS_TEST_TMPDIR}/proj"
	mkdir -p "${PROJECT_ROOT}"
	export MCPBASH_PROJECT_ROOT="${PROJECT_ROOT}"
}

@test "scaffold: creates tool files" {
	run "${MCPBASH_HOME}/bin/mcp-bash" scaffold tool hello
	assert_success

	assert_file_exist "${PROJECT_ROOT}/tools/hello/tool.sh"
	assert_file_exist "${PROJECT_ROOT}/tools/hello/tool.meta.json"
	assert_file_exist "${PROJECT_ROOT}/tools/hello/README.md"

	run jq -e '.name == "hello"' "${PROJECT_ROOT}/tools/hello/tool.meta.json"
	assert_success
}

@test "scaffold: creates prompt files" {
	run "${MCPBASH_HOME}/bin/mcp-bash" scaffold prompt welcome
	assert_success

	assert_file_exist "${PROJECT_ROOT}/prompts/welcome/welcome.txt"
	assert_file_exist "${PROJECT_ROOT}/prompts/welcome/welcome.meta.json"
	assert_file_exist "${PROJECT_ROOT}/prompts/welcome/README.md"

	run jq -e '.name == "prompt.welcome"' "${PROJECT_ROOT}/prompts/welcome/welcome.meta.json"
	assert_success
}

@test "scaffold: creates resource files with file:// URI" {
	run "${MCPBASH_HOME}/bin/mcp-bash" scaffold resource sample
	assert_success

	assert_file_exist "${PROJECT_ROOT}/resources/sample/sample.txt"
	assert_file_exist "${PROJECT_ROOT}/resources/sample/sample.meta.json"
	assert_file_exist "${PROJECT_ROOT}/resources/sample/README.md"

	run jq -e '.name == "resource.sample"' "${PROJECT_ROOT}/resources/sample/sample.meta.json"
	assert_success

	resource_uri="$(jq -r '.uri // ""' "${PROJECT_ROOT}/resources/sample/sample.meta.json")"
	[[ "${resource_uri}" == file://* ]]
}

@test "scaffold: creates ui directory for standalone UI" {
	run "${MCPBASH_HOME}/bin/mcp-bash" scaffold ui dashboard
	assert_success

	assert_file_exist "${PROJECT_ROOT}/ui/dashboard/index.html"
	assert_file_exist "${PROJECT_ROOT}/ui/dashboard/ui.meta.json"
	assert_file_exist "${PROJECT_ROOT}/ui/dashboard/README.md"
}

@test "scaffold: tool --ui creates tool with ui subdirectory" {
	run "${MCPBASH_HOME}/bin/mcp-bash" scaffold tool weather --ui
	assert_success

	assert_file_exist "${PROJECT_ROOT}/tools/weather/tool.sh"
	assert_file_exist "${PROJECT_ROOT}/tools/weather/tool.meta.json"
	assert_file_exist "${PROJECT_ROOT}/tools/weather/ui/index.html"
	assert_file_exist "${PROJECT_ROOT}/tools/weather/ui/ui.meta.json"
}

@test "scaffold: ui --tool creates ui in tool directory" {
	mkdir -p "${PROJECT_ROOT}/tools/existing-tool"
	run "${MCPBASH_HOME}/bin/mcp-bash" scaffold ui my-ui --tool existing-tool
	assert_success

	assert_file_exist "${PROJECT_ROOT}/tools/existing-tool/ui/index.html"
	assert_file_exist "${PROJECT_ROOT}/tools/existing-tool/ui/ui.meta.json"
}

@test "scaffold: ui --tool defaults name to tool name" {
	mkdir -p "${PROJECT_ROOT}/tools/calculator"
	run "${MCPBASH_HOME}/bin/mcp-bash" scaffold ui --tool calculator
	assert_success

	assert_file_exist "${PROJECT_ROOT}/tools/calculator/ui/index.html"
	# Template should contain the tool name in both files
	run grep -q "calculator" "${PROJECT_ROOT}/tools/calculator/ui/index.html"
	assert_success
	run grep -q "calculator" "${PROJECT_ROOT}/tools/calculator/ui/ui.meta.json"
	assert_success
}

@test "scaffold: ui fails if directory already exists" {
	mkdir -p "${PROJECT_ROOT}/ui/dashboard"
	run "${MCPBASH_HOME}/bin/mcp-bash" scaffold ui dashboard
	assert_failure
	assert_output --partial "already exists"
}

@test "scaffold: ui generates CSP with jsdelivr" {
	run "${MCPBASH_HOME}/bin/mcp-bash" scaffold ui monitor
	assert_success

	run grep -q "cdn.jsdelivr.net" "${PROJECT_ROOT}/ui/monitor/ui.meta.json"
	assert_success
}

@test "scaffold: ui --tool errors on non-existent tool" {
	run "${MCPBASH_HOME}/bin/mcp-bash" scaffold ui my-ui --tool nonexistent
	assert_failure
	assert_output --partial "Tool directory not found"
}
