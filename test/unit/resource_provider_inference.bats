#!/usr/bin/env bats
# Unit layer: every way of registering a static resource infers a missing
# "provider" with the same rule: built-in schemes (file://, git+https://,
# https://, ui://) use the built-in provider; another scheme uses the project
# provider of that name when providers/<scheme>.sh exists; otherwise file, with
# a warning. An explicit provider is never changed.

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
	if ! command -v mcp_json_icons_to_data_uris >/dev/null 2>&1; then
		mcp_json_icons_to_data_uris() { printf '%s' "$1"; }
	fi

	MCPBASH_TMP_ROOT="${BATS_TEST_TMPDIR}"
	MCPBASH_STATE_DIR="${BATS_TEST_TMPDIR}/state"
	MCPBASH_LOCK_ROOT="${BATS_TEST_TMPDIR}/locks"
	MCPBASH_RESOURCES_DIR="${BATS_TEST_TMPDIR}/resources"
	MCPBASH_REGISTRY_DIR="${BATS_TEST_TMPDIR}/.registry"
	MCPBASH_PROVIDERS_DIR="${BATS_TEST_TMPDIR}/providers"
	MCP_RESOURCES_REGISTRY_PATH="${MCPBASH_REGISTRY_DIR}/resources.json"
	mkdir -p "${MCPBASH_STATE_DIR}" "${MCPBASH_LOCK_ROOT}" "${MCPBASH_RESOURCES_DIR}" "${MCPBASH_REGISTRY_DIR}" "${MCPBASH_PROVIDERS_DIR}"
	mcp_lock_init
	printf '#!/usr/bin/env bash\n' >"${MCPBASH_PROVIDERS_DIR}/myapi.sh"
}

provider_of() {
	printf '%s' "${MCP_RESOURCES_REGISTRY_JSON}" | jq -r --arg n "$1" '.items[] | select(.name == $n) | .provider'
}

assert_inferred() {
	assert_equal "$(provider_of r-ui)" "ui"
	assert_equal "$(provider_of r-file)" "file"
	assert_equal "$(provider_of r-https)" "https"
	assert_equal "$(provider_of r-git)" "git"
	assert_equal "$(provider_of r-custom)" "myapi"
	assert_equal "$(provider_of r-missing)" "file"
	assert_equal "$(provider_of r-explicit)" "myapi"
	run grep -c 'no providers/nosuch.sh' "${WARNINGS_FILE}"
	assert_output "1"
	# Markers used for the warning never reach the registry.
	run bash -c 'printf "%s" "$1" | jq -e "[.items[] | has(\"_mcpbashNoProviderFor\")] | any | not"' _ "${MCP_RESOURCES_REGISTRY_JSON}"
	assert_success
}

RESOURCES_JSON='[
	{"name":"r-ui","uri":"ui://app/view"},
	{"name":"r-file","uri":"file:///tmp/x.txt"},
	{"name":"r-https","uri":"https://example.com/a"},
	{"name":"r-git","uri":"git+https://example.com/repo/main/README.md"},
	{"name":"r-custom","uri":"myapi://items/1"},
	{"name":"r-missing","uri":"nosuch://thing"},
	{"name":"r-explicit","uri":"other://x","provider":"myapi"}
]'

@test "provider inference: register.sh (mcp_register_resource)" {
	mcp_resources_manual_begin
	local item
	while IFS= read -r item; do
		mcp_resources_register_manual "${item}"
	done < <(printf '%s' "${RESOURCES_JSON}" | jq -c '.[]')
	mcp_resources_manual_finalize
	assert_inferred
}

@test "provider inference: register.sh printing JSON" {
	mcp_resources_apply_manual_json "$(printf '%s' "${RESOURCES_JSON}" | jq -c '{resources: .}')"
	assert_inferred
}

@test "provider inference: an empty provider string counts as missing" {
	mcp_resources_apply_manual_json '{"resources":[{"name":"r-ui","uri":"ui://app/view","provider":""}]}'
	assert_equal "$(provider_of r-ui)" "ui"
}

@test "provider inference: register.json" {
	local normalized
	normalized="$(mcp_registry_declarative_validate_and_normalize "$(printf '%s' "${RESOURCES_JSON}" | jq -c '{version: 1, resources: .}')")"
	mcp_resources_apply_manual_json "$(printf '%s' "${normalized}" | jq -c '{resources: .resources}')"
	assert_inferred
}

@test "provider inference: register.json no longer maps an unknown scheme to a same-named provider" {
	local normalized
	normalized="$(mcp_registry_declarative_validate_and_normalize '{"version":1,"resources":[{"name":"g","uri":"git://example.com/r"}]}')"
	mcp_resources_apply_manual_json "$(printf '%s' "${normalized}" | jq -c '{resources: .resources}')"
	assert_equal "$(provider_of g)" "file"
}

@test "provider inference: auto-discovery warns for a scheme with no provider" {
	printf 'x' >"${MCPBASH_RESOURCES_DIR}/missing.txt"
	printf '%s' '{"name":"r-missing","uri":"nosuch://thing"}' >"${MCPBASH_RESOURCES_DIR}/missing.meta.json"
	printf 'x' >"${MCPBASH_RESOURCES_DIR}/custom.txt"
	printf '%s' '{"name":"r-custom","uri":"myapi://items/1"}' >"${MCPBASH_RESOURCES_DIR}/custom.meta.json"
	mcp_resources_scan "${MCPBASH_RESOURCES_DIR}" >/dev/null
	MCP_RESOURCES_REGISTRY_JSON="$(cat "${MCP_RESOURCES_REGISTRY_PATH}")"
	assert_equal "$(provider_of r-missing)" "file"
	assert_equal "$(provider_of r-custom)" "myapi"
	run grep -c 'no providers/nosuch.sh' "${WARNINGS_FILE}"
	assert_output "1"
}

@test "provider inference: a provider script name that is not a scheme is ignored" {
	printf '#!/usr/bin/env bash\n' >"${MCPBASH_PROVIDERS_DIR}/my_api.sh"
	run mcp_resources_project_provider_names_json
	assert_output '["myapi"]'
}
