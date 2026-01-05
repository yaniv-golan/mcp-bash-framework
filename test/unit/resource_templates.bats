#!/usr/bin/env bats
# Unit tests for resource template registry handling.

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

	# Mock logging functions if not present
	if ! command -v mcp_logging_is_enabled >/dev/null 2>&1; then
		mcp_logging_is_enabled() { return 1; }
	fi
	if ! command -v mcp_logging_verbose_enabled >/dev/null 2>&1; then
		mcp_logging_verbose_enabled() { return 0; }
	fi
	if ! command -v mcp_logging_warning >/dev/null 2>&1; then
		mcp_logging_warning() { return 0; }
	fi
	if ! command -v mcp_logging_info >/dev/null 2>&1; then
		mcp_logging_info() { return 0; }
	fi
	if ! command -v mcp_logging_debug >/dev/null 2>&1; then
		mcp_logging_debug() { return 0; }
	fi
	if ! command -v mcp_json_icons_to_data_uris >/dev/null 2>&1; then
		mcp_json_icons_to_data_uris() { printf '%s' "$1"; }
	fi

	MCPBASH_TMP_ROOT="${BATS_TEST_TMPDIR}"
	MCPBASH_STATE_DIR="${BATS_TEST_TMPDIR}/state"
	MCPBASH_LOCK_ROOT="${BATS_TEST_TMPDIR}/locks"
	MCPBASH_RESOURCES_DIR="${BATS_TEST_TMPDIR}/resources"
	MCPBASH_REGISTRY_DIR="${BATS_TEST_TMPDIR}/.registry"
	MCPBASH_SERVER_DIR="${BATS_TEST_TMPDIR}/server.d"
	MCP_RESOURCES_TEMPLATES_TTL=0
	MCP_RESOURCES_TTL=0
	mkdir -p "${MCPBASH_STATE_DIR}" "${MCPBASH_LOCK_ROOT}" "${MCPBASH_RESOURCES_DIR}" "${MCPBASH_REGISTRY_DIR}" "${MCPBASH_SERVER_DIR}"
	mcp_lock_init
}

reset_template_state() {
	MCP_RESOURCES_REGISTRY_JSON=""
	MCP_RESOURCES_REGISTRY_HASH=""
	MCP_RESOURCES_TOTAL=0
	MCP_RESOURCES_LAST_SCAN=0
	MCP_RESOURCES_CHANGED=false
	MCP_RESOURCES_TEMPLATES_REGISTRY_JSON=""
	MCP_RESOURCES_TEMPLATES_REGISTRY_HASH=""
	MCP_RESOURCES_TEMPLATES_TOTAL=0
	MCP_RESOURCES_TEMPLATES_LAST_SCAN=0
	MCP_RESOURCES_TEMPLATES_MANUAL_JSON="[]"
	MCP_RESOURCES_TEMPLATES_MANUAL_BUFFER=""
	MCP_RESOURCES_TEMPLATES_MANUAL_ACTIVE=false
	MCP_RESOURCES_TEMPLATES_MANUAL_UPDATED=false
}

@test "resource_templates: auto-discovery skips invalid templates and resource name collisions" {
	reset_template_state
	rm -rf "${MCPBASH_RESOURCES_DIR:?}/"*
	mkdir -p "${MCPBASH_RESOURCES_DIR}"
	printf 'data' >"${MCPBASH_RESOURCES_DIR}/static.txt"
	cat >"${MCPBASH_RESOURCES_DIR}/static.meta.json" <<EOF
{"name":"static-resource","uri":"file://${MCPBASH_RESOURCES_DIR}/static.txt"}
EOF
	cat >"${MCPBASH_RESOURCES_DIR}/good.meta.json" <<'EOF'
{"name":"valid-template","uriTemplate":"file:///{path}","description":"ok"}
EOF
	cat >"${MCPBASH_RESOURCES_DIR}/conflict.meta.json" <<'EOF'
{"name":"static-resource","uriTemplate":"file:///{bad}"}
EOF
	cat >"${MCPBASH_RESOURCES_DIR}/novar.meta.json" <<'EOF'
{"name":"novar","uriTemplate":"file:///no/vars"}
EOF
	cat >"${MCPBASH_RESOURCES_DIR}/both.meta.json" <<'EOF'
{"name":"both","uri":"file:///tmp/a","uriTemplate":"file:///{also}"}
EOF

	# These functions return 1 if no hook is found (fallback to scan), which is fine
	mcp_resources_refresh_registry || true

	mcp_resources_templates_refresh_registry || true

	valid_count="$(printf '%s' "${MCP_RESOURCES_TEMPLATES_REGISTRY_JSON}" | "${MCPBASH_JSON_TOOL_BIN}" -r '.items | length')"
	valid_name="$(printf '%s' "${MCP_RESOURCES_TEMPLATES_REGISTRY_JSON}" | "${MCPBASH_JSON_TOOL_BIN}" -r '.items[0].name')"
	assert_equal "1" "${valid_count}"
	assert_equal "valid-template" "${valid_name}"
	[ -n "${MCP_RESOURCES_TEMPLATES_REGISTRY_HASH}" ]
}

@test "resource_templates: manual registrations override auto-discovery" {
	reset_template_state
	rm -rf "${MCPBASH_RESOURCES_DIR:?}/"*
	mkdir -p "${MCPBASH_RESOURCES_DIR}"
	cat >"${MCPBASH_RESOURCES_DIR}/auto.meta.json" <<'EOF'
{"name":"override-me","uriTemplate":"file:///{auto}"}
EOF

	mcp_resources_templates_manual_begin
	mcp_resources_templates_register_manual '{"name":"override-me","uriTemplate":"git+https://{repo}/{path}","description":"manual"}'
	mcp_resources_templates_register_manual '{"name":"manual-only","uriTemplate":"file:///var/log/{svc}/{date}"}'
	mcp_resources_templates_manual_finalize

	# This function returns 1 if no hook is found (fallback to scan), which is fine
	mcp_resources_templates_refresh_registry || true

	override_uri="$(printf '%s' "${MCP_RESOURCES_TEMPLATES_REGISTRY_JSON}" | "${MCPBASH_JSON_TOOL_BIN}" -r '.items[] | select(.name=="override-me") | .uriTemplate')"
	total_templates="$(printf '%s' "${MCP_RESOURCES_TEMPLATES_REGISTRY_JSON}" | "${MCPBASH_JSON_TOOL_BIN}" -r '.total')"

	assert_equal "git+https://{repo}/{path}" "${override_uri}"
	assert_equal "2" "${total_templates}"
}
