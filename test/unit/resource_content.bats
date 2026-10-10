#!/usr/bin/env bats
# Unit layer: resource content builder (declared label vs detected encoding).

load '../../node_modules/bats-support/load'
load '../../node_modules/bats-assert/load'
load '../common/fixtures'

setup() {
	# shellcheck source=lib/runtime.sh
	# shellcheck disable=SC1091
	. "${MCPBASH_HOME}/lib/runtime.sh"

	MCPBASH_FORCE_MINIMAL=false
	mcp_runtime_detect_json_tool
	if [ "${MCPBASH_MODE}" = "minimal" ]; then
		skip "JSON tooling unavailable for resource content tests"
	fi
	if ! command -v file >/dev/null 2>&1; then
		skip "file(1) unavailable; detection cannot run"
	fi

	# shellcheck source=lib/resource_content.sh
	# shellcheck disable=SC1091
	. "${MCPBASH_HOME}/lib/resource_content.sh"

	TEST_TMPDIR="$(mktemp -d)"
	export TEST_TMPDIR

	# A small, valid-looking PDF with no NUL byte anywhere: only detection
	# (not the NUL sniff) can tell that it is binary.
	PDF_FILE="${TEST_TMPDIR}/doc.pdf"
	printf '%%PDF-1.4\n1 0 obj\n<< /Type /Catalog >>\nendobj\ntrailer\n<< /Root 1 0 R >>\n%%%%EOF\n' >"${PDF_FILE}"
	TOML_FILE="${TEST_TMPDIR}/conf.toml"
	printf 'title = "demo"\n[server]\nport = 8080\n' >"${TOML_FILE}"
	MD_FILE="${TEST_TMPDIR}/notes.md"
	printf '# Notes\n\nSome *markdown* text.\n' >"${MD_FILE}"
	JSON_FILE="${TEST_TMPDIR}/data.json"
	printf '{"a":1,"b":[1,2,3]}\n' >"${JSON_FILE}"
}

teardown() {
	rm -rf "${TEST_TMPDIR:-}" 2>/dev/null || true
}

jq_get() {
	printf '%s' "$1" | "${MCPBASH_JSON_TOOL_BIN}" -r "$2"
}

@test "resource_content: declared label is reported as given" {
	run mcp_resource_content_object_from_file "${MD_FILE}" "text/markdown" "file:///notes.md" true
	assert_success
	assert_equal "$(jq_get "${output}" '.mimeType')" "text/markdown"
	assert_equal "$(jq_get "${output}" 'has("text")')" "true"
	assert_equal "$(jq_get "${output}" '.text')" "$(cat "${MD_FILE}")"
}

@test "resource_content: declared text/plain on a NUL-free PDF is still base64" {
	run mcp_resource_content_object_from_file "${PDF_FILE}" "text/plain" "file:///doc.pdf" true
	assert_success
	assert_equal "$(jq_get "${output}" '.mimeType')" "text/plain"
	assert_equal "$(jq_get "${output}" 'has("blob")')" "true"
	assert_equal "$(jq_get "${output}" 'has("text")')" "false"
}

@test "resource_content: declared text/plain on NUL-free random binary is base64" {
	local bin="${TEST_TMPDIR}/noise.bin"
	printf '\x89\xfe\xa1\xb2\xc3\xd4\xe5\xf6\x87\x98\xa9\xba\xcb\xdc\xed\xfe\x81\x92' >"${bin}"
	run mcp_resource_content_object_from_file "${bin}" "text/plain" "" true
	assert_success
	assert_equal "$(jq_get "${output}" '.mimeType')" "text/plain"
	assert_equal "$(jq_get "${output}" 'has("blob")')" "true"
}

@test "resource_content: declared unknown text type (application/toml) stays text" {
	run mcp_resource_content_object_from_file "${TOML_FILE}" "application/toml" "file:///conf.toml" true
	assert_success
	assert_equal "$(jq_get "${output}" '.mimeType')" "application/toml"
	assert_equal "$(jq_get "${output}" 'has("text")')" "true"
	assert_equal "$(jq_get "${output}" 'has("blob")')" "false"
}

@test "resource_content: declared binary class on text bytes is base64" {
	run mcp_resource_content_object_from_file "${TOML_FILE}" "image/png" "" true
	assert_success
	assert_equal "$(jq_get "${output}" '.mimeType')" "image/png"
	assert_equal "$(jq_get "${output}" 'has("blob")')" "true"
}

@test "resource_content: undeclared hint is overridden by detection (unchanged)" {
	run mcp_resource_content_object_from_file "${JSON_FILE}" "text/plain" "file:///data.json"
	assert_success
	assert_equal "$(jq_get "${output}" '.mimeType')" "application/json"
	assert_equal "$(jq_get "${output}" 'has("text")')" "true"

	run mcp_resource_content_object_from_file "${JSON_FILE}" "text/plain" "file:///data.json" false
	assert_success
	assert_equal "$(jq_get "${output}" '.mimeType')" "application/json"
}

@test "resource_content: undeclared PDF is detected and base64 (unchanged)" {
	run mcp_resource_content_object_from_file "${PDF_FILE}" "text/plain" ""
	assert_success
	assert_equal "$(jq_get "${output}" '.mimeType')" "application/pdf"
	assert_equal "$(jq_get "${output}" 'has("blob")')" "true"
}

@test "resource_content: undeclared profile hint is kept (unchanged)" {
	local html="${TEST_TMPDIR}/app.html"
	printf '<!DOCTYPE html><html><body>hi</body></html>\n' >"${html}"
	run mcp_resource_content_object_from_file "${html}" "text/html;profile=mcp-app" ""
	assert_success
	assert_equal "$(jq_get "${output}" '.mimeType')" "text/html;profile=mcp-app"
	assert_equal "$(jq_get "${output}" 'has("text")')" "true"
}
