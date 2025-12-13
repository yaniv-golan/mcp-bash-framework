#!/usr/bin/env bash
# Unit tests for resource template registry handling.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

# shellcheck source=test/common/env.sh
# shellcheck disable=SC1091
. "${REPO_ROOT}/test/common/env.sh"
# shellcheck source=test/common/assert.sh
# shellcheck disable=SC1091
. "${REPO_ROOT}/test/common/assert.sh"
# shellcheck source=lib/hash.sh disable=SC1090
. "${REPO_ROOT}/lib/hash.sh"
# shellcheck source=lib/lock.sh disable=SC1090
. "${REPO_ROOT}/lib/lock.sh"
# shellcheck source=lib/registry.sh disable=SC1090
. "${REPO_ROOT}/lib/registry.sh"
# shellcheck source=lib/resources.sh disable=SC1090
. "${REPO_ROOT}/lib/resources.sh"

MCPBASH_JSON_TOOL_BIN="$(command -v jq)"
MCPBASH_JSON_TOOL="jq"

if ! command -v mcp_logging_is_enabled >/dev/null 2>&1; then
	mcp_logging_is_enabled() {
		return 1
	}
fi
if ! command -v mcp_logging_verbose_enabled >/dev/null 2>&1; then
	mcp_logging_verbose_enabled() {
		return 0
	}
fi
if ! command -v mcp_logging_warning >/dev/null 2>&1; then
	mcp_logging_warning() {
		return 0
	}
fi
if ! command -v mcp_logging_info >/dev/null 2>&1; then
	mcp_logging_info() {
		return 0
	}
fi
if ! command -v mcp_logging_debug >/dev/null 2>&1; then
	mcp_logging_debug() {
		return 0
	}
fi
if ! command -v mcp_json_icons_to_data_uris >/dev/null 2>&1; then
	mcp_json_icons_to_data_uris() {
		printf '%s' "$1"
	}
fi

test_create_tmpdir
MCPBASH_TMP_ROOT="${TEST_TMPDIR}"
MCPBASH_STATE_DIR="${TEST_TMPDIR}/state"
MCPBASH_LOCK_ROOT="${TEST_TMPDIR}/locks"
MCPBASH_RESOURCES_DIR="${TEST_TMPDIR}/resources"
MCPBASH_REGISTRY_DIR="${TEST_TMPDIR}/.registry"
MCPBASH_HOME="${REPO_ROOT}"
MCPBASH_SERVER_DIR="${TEST_TMPDIR}/server.d"
MCP_RESOURCES_TEMPLATES_TTL=0
MCP_RESOURCES_TTL=0
mkdir -p "${MCPBASH_STATE_DIR}" "${MCPBASH_LOCK_ROOT}" "${MCPBASH_RESOURCES_DIR}" "${MCPBASH_REGISTRY_DIR}"
mcp_lock_init
mkdir -p "${MCPBASH_SERVER_DIR}"

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

reset_template_state

printf ' -> auto-discovery skips invalid templates and resource name collisions\n'
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

if ! mcp_resources_refresh_registry; then
	test_fail "resource registry refresh failed"
fi
if ! mcp_resources_templates_refresh_registry; then
	test_fail "template refresh failed"
fi

valid_count="$(printf '%s' "${MCP_RESOURCES_TEMPLATES_REGISTRY_JSON}" | "${MCPBASH_JSON_TOOL_BIN}" -r '.items | length')"
valid_name="$(printf '%s' "${MCP_RESOURCES_TEMPLATES_REGISTRY_JSON}" | "${MCPBASH_JSON_TOOL_BIN}" -r '.items[0].name')"
if [ "${valid_count}" != "1" ] || [ "${valid_name}" != "valid-template" ]; then
	test_fail "expected only valid-template to be registered (got count=${valid_count}, name=${valid_name})"
fi
if [ -z "${MCP_RESOURCES_TEMPLATES_REGISTRY_HASH}" ]; then
	test_fail "template registry hash should be set"
fi

printf ' -> manual registrations override auto-discovery\n'
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

if ! mcp_resources_templates_refresh_registry; then
	test_fail "template refresh with manual registration failed"
fi

template_names="$(printf '%s' "${MCP_RESOURCES_TEMPLATES_REGISTRY_JSON}" | "${MCPBASH_JSON_TOOL_BIN}" -r '.items[].name' | tr '\n' ',' )"
override_uri="$(printf '%s' "${MCP_RESOURCES_TEMPLATES_REGISTRY_JSON}" | "${MCPBASH_JSON_TOOL_BIN}" -r '.items[] | select(.name=="override-me") | .uriTemplate')"
total_templates="$(printf '%s' "${MCP_RESOURCES_TEMPLATES_REGISTRY_JSON}" | "${MCPBASH_JSON_TOOL_BIN}" -r '.total')"

if [ "${template_names}" != "manual-only,override-me," ]; then
	test_fail "unexpected template names after merge: ${template_names}"
fi
assert_eq "git+https://{repo}/{path}" "${override_uri}" "manual template should override auto entry"
assert_eq "2" "${total_templates}" "merged registry should include manual-only and override-me"
