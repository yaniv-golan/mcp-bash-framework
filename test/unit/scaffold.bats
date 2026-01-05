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
