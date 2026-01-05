#!/usr/bin/env bats
# Unit: debug payload redaction should scrub secrets beyond params._meta.

load '../../node_modules/bats-support/load'
load '../../node_modules/bats-assert/load'
load '../common/fixtures'

setup() {
	# shellcheck source=lib/io.sh
	# shellcheck disable=SC1091
	. "${MCPBASH_HOME}/lib/io.sh"

	MCPBASH_JSON_TOOL_BIN="${TEST_JSON_TOOL_BIN}"
	MCPBASH_JSON_TOOL="$(basename "${TEST_JSON_TOOL_BIN}")"
	case "${MCPBASH_JSON_TOOL}" in
	jq | gojq) ;;
	*) MCPBASH_JSON_TOOL="jq" ;;
	esac
	export MCPBASH_JSON_TOOL MCPBASH_JSON_TOOL_BIN
}

@test "io_debug: redacts secrets recursively (arguments + nested objects)" {
	payload='{"jsonrpc":"2.0","id":"1","method":"tools/call","params":{"name":"t","arguments":{"password":"pw-123","nested":{"client_secret":"cs-456"},"headers":[{"Authorization":"Bearer abc.def.ghi"}]},"_meta":{"mcpbash/remoteToken":"rt-789"}}}'

	redacted="$(mcp_io_debug_redact_payload "${payload}")"

	# Must stay parseable JSON when jq/gojq is available.
	run bash -c "printf '%s' '${redacted}' | jq . >/dev/null 2>&1"
	assert_success

	# Verify original secrets are gone.
	[[ "${redacted}" != *"pw-123"* ]]
	[[ "${redacted}" != *"cs-456"* ]]
	[[ "${redacted}" != *"rt-789"* ]]
	[[ "${redacted}" != *"abc.def.ghi"* ]]
}

@test "io_debug: sed fallback redacts common keys when JSON tooling is disabled" {
	MCPBASH_JSON_TOOL="none"
	MCPBASH_JSON_TOOL_BIN=""
	export MCPBASH_JSON_TOOL MCPBASH_JSON_TOOL_BIN

	fallback='{"authorization":"Bearer should-not-appear","access_token":"at-1","refresh_token":"rt-1","client_secret":"cs-1","password":"pw-1"}'
	fallback_redacted="$(mcp_io_debug_redact_payload "${fallback}")"

	[[ "${fallback_redacted}" != *"should-not-appear"* ]]
	[[ "${fallback_redacted}" != *"at-1"* ]]
	[[ "${fallback_redacted}" != *"cs-1"* ]]
}
