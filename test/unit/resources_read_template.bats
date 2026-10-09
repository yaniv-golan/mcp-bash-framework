#!/usr/bin/env bats
# Unit layer: what mcp_resources_read passes on a template match.
#
# The provider runner and the content builder are stubbed so the test asserts
# the read path's arguments (template name/VARS for the provider, the declared
# mimeType flag for mcp_resource_content_object_from_file), independent of how
# the content builder treats a declared type.

load '../../node_modules/bats-support/load'
load '../../node_modules/bats-assert/load'
load '../common/fixtures'

setup() {
	# shellcheck source=lib/hash.sh
	# shellcheck disable=SC1091
	. "${MCPBASH_HOME}/lib/hash.sh"
	# shellcheck source=lib/lock.sh
	# shellcheck disable=SC1091
	. "${MCPBASH_HOME}/lib/lock.sh"
	# shellcheck source=lib/registry.sh
	# shellcheck disable=SC1091
	. "${MCPBASH_HOME}/lib/registry.sh"
	# shellcheck source=lib/resources.sh
	# shellcheck disable=SC1091
	. "${MCPBASH_HOME}/lib/resources.sh"

	MCPBASH_JSON_TOOL_BIN="${TEST_JSON_TOOL_BIN:-$(command -v jq)}"
	MCPBASH_JSON_TOOL="jq"
	MCPBASH_TMP_ROOT="${BATS_TEST_TMPDIR}"
	MCPBASH_PROVIDERS_DIR="${BATS_TEST_TMPDIR}/providers"
	mkdir -p "${MCPBASH_PROVIDERS_DIR}"
	: >"${MCPBASH_PROVIDERS_DIR}/kv.sh"

	mcp_logging_is_enabled() { return 1; }
	mcp_logging_verbose_enabled() { return 1; }
	mcp_logging_debug() { return 0; }
	mcp_logging_warning() { return 0; }
	mcp_logging_info() { return 0; }
	mcp_logging_error() { return 0; }

	MCP_RESOURCES_REGISTRY_JSON='{"items":[{"name":"kv-static","uri":"kv://d/static","provider":"kv"}]}'
	MCP_RESOURCES_TEMPLATES_REGISTRY_JSON='{"items":[
		{"name":"md","uriTemplate":"kv://d/{a}","mimeType":"text/markdown"},
		{"name":"plain","uriTemplate":"kv://p/{+rest}"},
		{"name":"legacy","uriTemplate":"kv://l/{ids*}"}]}'
	mcp_resources_refresh_registry() { return 0; }
	mcp_resources_templates_refresh_registry() {
		printf 'x\n' >>"${BATS_TEST_TMPDIR}/templates.refreshes"
		return 0
	}
	mcp_resources_read_via_provider() {
		printf '%s\n' "$#" "$@" >"${BATS_TEST_TMPDIR}/provider.args"
		printf 'hello'
	}
	mcp_resource_content_object_from_file() {
		printf '%s\n' "$2" "${4-<none>}" >"${BATS_TEST_TMPDIR}/content.args"
		printf '{"uri":"%s","mimeType":"%s","text":"hello"}' "$3" "$2"
	}
}

refreshes() {
	if [ -f "${BATS_TEST_TMPDIR}/templates.refreshes" ]; then
		wc -l <"${BATS_TEST_TMPDIR}/templates.refreshes" | tr -d ' '
	else
		printf '0'
	fi
}

@test "read_template: a match with mimeType passes it as declared, and the template env" {
	mcp_resources_read "" "kv://d/a%2Fb"
	run cat "${BATS_TEST_TMPDIR}/content.args"
	assert_output "$(printf 'text/markdown\ntrue')"
	run cat "${BATS_TEST_TMPDIR}/provider.args"
	assert_output "$(printf '4\nkv\nkv://d/a%%2Fb\nmd\n{"a":"a%%2Fb"}')"
	[ "$(refreshes)" = "1" ] || fail "templates registry refreshed $(refreshes) times"
}

@test "read_template: a match without mimeType keeps the default label, undeclared" {
	mcp_resources_read "" "kv://p/x/y"
	run cat "${BATS_TEST_TMPDIR}/content.args"
	assert_output "$(printf 'text/plain\nfalse')"
	run cat "${BATS_TEST_TMPDIR}/provider.args"
	assert_output "$(printf '4\nkv\nkv://p/x/y\nplain\n{"rest":"x/y"}')"
	[ "$(refreshes)" = "1" ] || fail "templates registry refreshed $(refreshes) times"
}

@test "read_template: an unsupported template passes no template env" {
	mcp_resources_read "" "kv://l/5"
	run cat "${BATS_TEST_TMPDIR}/provider.args"
	assert_output "$(printf '4\nkv\nkv://l/5\n\n')"
	run cat "${BATS_TEST_TMPDIR}/content.args"
	assert_output "$(printf 'text/plain\nfalse')"
	[ "$(refreshes)" = "1" ] || fail "templates registry refreshed $(refreshes) times"
}

@test "read_template: an exact static URI wins and skips template matching" {
	mcp_resources_read "" "kv://d/static"
	run cat "${BATS_TEST_TMPDIR}/provider.args"
	assert_output "$(printf '4\nkv\nkv://d/static\n\n')"
	[ "$(refreshes)" = "0" ] || fail "templates registry refreshed $(refreshes) times"
}

@test "read_template: a lookup by name skips template matching" {
	mcp_resources_read "kv-static" ""
	run cat "${BATS_TEST_TMPDIR}/provider.args"
	assert_output "$(printf '4\nkv\nkv://d/static\n\n')"
	[ "$(refreshes)" = "0" ] || fail "templates registry refreshed $(refreshes) times"
}

@test "read_template: provider selection is unchanged by a match" {
	# A template on an undeclared-provider scheme: the file provider still
	# handles file:// URIs, with the template env attached.
	MCP_RESOURCES_TEMPLATES_REGISTRY_JSON='{"items":[{"name":"files","uriTemplate":"file:///{+path}"}]}'
	mcp_resources_read "" "file:///tmp/x"
	run cat "${BATS_TEST_TMPDIR}/provider.args"
	assert_output "$(printf '4\nfile\nfile:///tmp/x\nfiles\n{"path":"tmp/x"}')"
}

@test "read_template: a failed templates refresh is not retried and fails the scheme gate closed" {
	mcp_resources_templates_refresh_registry() {
		printf 'x\n' >>"${BATS_TEST_TMPDIR}/templates.refreshes"
		return 1
	}
	# No static resource declares kv, so only the templates could.
	MCP_RESOURCES_REGISTRY_JSON='{"items":[]}'
	run mcp_resources_read "" "kv://l/5"
	[ "$(refreshes)" = "1" ] || fail "templates registry refreshed $(refreshes) times"
	# Undeclared scheme: falls back to the file provider (1.5.0 behaviour).
	mcp_resources_read "" "kv://l/5" || true
	run cat "${BATS_TEST_TMPDIR}/provider.args"
	assert_line --index 1 "file"
}
