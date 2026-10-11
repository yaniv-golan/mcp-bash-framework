#!/usr/bin/env bats
# Unit layer: a resource template's "provider". A usable one is kept in the
# templates registry (never in resources/templates/list); anything else is
# dropped with a warning, and the URI scheme picks the provider.

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

	MCPBASH_JSON_TOOL_BIN="$(command -v jq)"
	MCPBASH_JSON_TOOL="jq"

	WARNINGS_FILE="${BATS_TEST_TMPDIR}/warnings.log"
	: >"${WARNINGS_FILE}"
	mcp_logging_warning() { printf '%s\n' "$2" >>"${WARNINGS_FILE}"; }
	mcp_logging_error() { printf 'ERROR %s\n' "$2" >>"${WARNINGS_FILE}"; }
	mcp_logging_is_enabled() { return 1; }
	mcp_logging_verbose_enabled() { return 1; }
	mcp_logging_info() { return 0; }
	mcp_logging_debug() { return 0; }

	MCPBASH_TMP_ROOT="${BATS_TEST_TMPDIR}"
	MCPBASH_STATE_DIR="${BATS_TEST_TMPDIR}/state"
	MCPBASH_LOCK_ROOT="${BATS_TEST_TMPDIR}/locks"
	MCPBASH_RESOURCES_DIR="${BATS_TEST_TMPDIR}/resources"
	MCPBASH_REGISTRY_DIR="${BATS_TEST_TMPDIR}/.registry"
	MCPBASH_SERVER_DIR="${BATS_TEST_TMPDIR}/server.d"
	MCPBASH_PROVIDERS_DIR="${BATS_TEST_TMPDIR}/providers"
	MCP_RESOURCES_TEMPLATES_TTL=0
	MCP_RESOURCES_TTL=0
	mkdir -p "${MCPBASH_STATE_DIR}" "${MCPBASH_LOCK_ROOT}" "${MCPBASH_RESOURCES_DIR}" \
		"${MCPBASH_REGISTRY_DIR}" "${MCPBASH_SERVER_DIR}" "${MCPBASH_PROVIDERS_DIR}"
	mcp_lock_init
	printf '#!/usr/bin/env bash\n' >"${MCPBASH_PROVIDERS_DIR}/alpha.sh"
	# Templates registered without a resource registry log a collision warning
	# unrelated to providers; give them an empty one.
	MCP_RESOURCES_REGISTRY_JSON='{"items":[]}'
}

normalized_provider() {
	mcp_resources_templates_normalize "$1" "test" | jq -r '.provider // "<none>"'
}

@test "template provider: a project provider is kept for any scheme" {
	run normalized_provider '{"name":"t","uriTemplate":"svc://a/{id}","provider":"alpha"}'
	assert_output "alpha"
	run normalized_provider '{"name":"t","uriTemplate":"https://api.example.com/{id}","provider":"alpha"}'
	assert_output "alpha"
	[ ! -s "${WARNINGS_FILE}" ]
}

@test "template provider: a built-in is kept on its own scheme only" {
	run normalized_provider '{"name":"t","uriTemplate":"ui://app/{id}","provider":"ui"}'
	assert_output "ui"
	run normalized_provider '{"name":"t","uriTemplate":"git+https://{repo}/{+path}","provider":"git"}'
	assert_output "git"
	run normalized_provider '{"name":"t","uriTemplate":"svc://a/{id}","provider":"ui"}'
	assert_output "<none>"
	run normalized_provider '{"name":"t","uriTemplate":"https://x/{id}","provider":"file"}'
	assert_output "<none>"
	run grep -c 'is a built-in provider for' "${WARNINGS_FILE}"
	assert_output "2"
}

@test "template provider: a missing script or invalid name is dropped with a warning" {
	run normalized_provider '{"name":"t","uriTemplate":"svc://a/{id}","provider":"nosuch"}'
	assert_output "<none>"
	run normalized_provider '{"name":"t","uriTemplate":"svc://a/{id}","provider":"../alpha"}'
	assert_output "<none>"
	run cat "${WARNINGS_FILE}"
	assert_output --partial "provider 'nosuch' has no providers/nosuch.sh"
	assert_output --partial "provider '../alpha' is not a valid provider name"
}

@test "template provider: an unmatchable template drops its provider with a warning" {
	run normalized_provider '{"name":"t","uriTemplate":"svc://a/{ids*}","provider":"alpha"}'
	assert_output "<none>"
	run cat "${WARNINGS_FILE}"
	assert_output --partial "syntax the matcher does not support"
}

@test "template provider: register.sh and register.json keep a valid provider" {
	mcp_resources_templates_manual_begin
	mcp_resources_templates_register_manual '{"name":"via-hook","uriTemplate":"svc://h/{id}","provider":"alpha"}'
	mcp_resources_templates_manual_finalize
	run bash -c 'printf "%s" "$1" | jq -r ".[] | select(.name==\"via-hook\") | .provider"' _ "${MCP_RESOURCES_TEMPLATES_MANUAL_JSON}"
	assert_output "alpha"

	mcp_resources_templates_apply_manual_json '{"resourceTemplates":[{"name":"via-json","uriTemplate":"svc://j/{id}","provider":"alpha"}]}'
	run bash -c 'printf "%s" "$1" | jq -r ".[] | select(.name==\"via-json\") | .provider"' _ "${MCP_RESOURCES_TEMPLATES_MANUAL_JSON}"
	assert_output "alpha"
}

@test "template provider: the matcher reports the best match's provider" {
	local registry='{"items":[
		{"name":"a","uriTemplate":"svc://a/{id}","provider":"alpha"},
		{"name":"a-special","uriTemplate":"svc://a/special-{id}"}]}'
	match() { printf '%s' "${registry}" | mcp_resource_template_match "$1" | jq -r '.name + " " + (.provider // "<none>")'; }
	run match "svc://a/1"
	assert_output "a alpha"
	run match "svc://a/special-1"
	assert_output "a-special <none>"
}

@test "template provider: resources/templates/list never includes provider" {
	MCP_RESOURCES_TEMPLATES_REGISTRY_JSON='{"version":1,"hash":"h","total":1,"items":[{"name":"t","uriTemplate":"svc://a/{id}","provider":"alpha"}]}'
	MCP_RESOURCES_TEMPLATES_REGISTRY_HASH="h"
	MCP_RESOURCES_TEMPLATES_TOTAL=1
	mcp_resources_templates_refresh_registry() { return 0; }
	run mcp_resources_templates_list "" ""
	assert_success
	run bash -c 'printf "%s" "$1" | jq -c "[.resourceTemplates[] | keys]"' _ "${output}"
	assert_output '[["name","uriTemplate"]]'
}
