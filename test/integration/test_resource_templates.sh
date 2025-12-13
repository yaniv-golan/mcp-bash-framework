#!/usr/bin/env bash
# shellcheck disable=SC2034  # Used by test runner for reporting.
TEST_DESC="Resource template discovery, pagination, manual overrides, and collisions."
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../common/env.sh
# shellcheck disable=SC1091
. "${SCRIPT_DIR}/../common/env.sh"
# shellcheck source=../common/assert.sh
# shellcheck disable=SC1091
. "${SCRIPT_DIR}/../common/assert.sh"

test_create_tmpdir

run_with_env() {
	local workdir="$1"
	local request_file="$2"
	local response_file="$3"
	(
		cd "${workdir}" || exit 1
		MCP_RESOURCES_TEMPLATES_TTL=0 \
			MCP_RESOURCES_TTL=0 \
			MCPBASH_PROJECT_ROOT="${workdir}" \
			./bin/mcp-bash <"${request_file}" >"${response_file}"
	)
}

echo "Resource templates temp root: ${TEST_TMPDIR}"

# --- Auto-discovery, pagination, and stale cursor rejection ---
AUTO_ROOT="${TEST_TMPDIR}/auto"
test_stage_workspace "${AUTO_ROOT}"

mkdir -p "${AUTO_ROOT}/resources"
cat >"${AUTO_ROOT}/resources/bravo.meta.json" <<'EOF'
{"name":"bravo","uriTemplate":"file:///{bravoPath}","description":"Second template"}
EOF
cat >"${AUTO_ROOT}/resources/alpha.meta.json" <<'EOF'
{"name":"alpha","uriTemplate":"file:///{alpha}","description":"First template","mimeType":"text/plain"}
EOF
# Invalid template: missing variable placeholder, should be skipped
cat >"${AUTO_ROOT}/resources/invalid.meta.json" <<'EOF'
{"name":"invalid","uriTemplate":"file:///no/vars/here"}
EOF

cat >"${AUTO_ROOT}/requests-1.ndjson" <<'JSON'
{"jsonrpc":"2.0","id":"init-auto","method":"initialize","params":{}}
{"jsonrpc":"2.0","method":"notifications/initialized"}
{"jsonrpc":"2.0","id":"auto-page-1","method":"resources/templates/list","params":{"limit":1}}
JSON

run_with_env "${AUTO_ROOT}" "${AUTO_ROOT}/requests-1.ndjson" "${AUTO_ROOT}/responses-1.ndjson"

auto_cursor="$(jq -r 'select(.id=="auto-page-1") | .result.nextCursor' "${AUTO_ROOT}/responses-1.ndjson")"
auto_first_name="$(jq -r 'select(.id=="auto-page-1") | .result.resourceTemplates[0].name' "${AUTO_ROOT}/responses-1.ndjson")"
auto_first_total="$(jq -r 'select(.id=="auto-page-1") | .result._meta["mcpbash/total"]' "${AUTO_ROOT}/responses-1.ndjson")"

assert_eq "alpha" "${auto_first_name}" "templates should be sorted by name"
if [ -z "${auto_cursor}" ] || [ "${auto_cursor}" = "null" ]; then
	test_fail "expected nextCursor for first page"
fi
assert_eq "2" "${auto_first_total}" "total should include all valid templates"

# Add a new template so the previous cursor becomes stale
cat >"${AUTO_ROOT}/resources/charlie.meta.json" <<'EOF'
{"name":"charlie","uriTemplate":"file:///{charlie}"}
EOF

cat >"${AUTO_ROOT}/requests-2.ndjson" <<JSON
{"jsonrpc":"2.0","id":"init-auto-2","method":"initialize","params":{}}
{"jsonrpc":"2.0","method":"notifications/initialized"}
{"jsonrpc":"2.0","id":"auto-stale","method":"resources/templates/list","params":{"cursor":"${auto_cursor}"}}
JSON

run_with_env "${AUTO_ROOT}" "${AUTO_ROOT}/requests-2.ndjson" "${AUTO_ROOT}/responses-2.ndjson" || true

auto_error_code="$(jq -r 'select(.id=="auto-stale") | .error.code' "${AUTO_ROOT}/responses-2.ndjson")"
assert_eq "-32602" "${auto_error_code}" "stale cursor should be rejected after registry hash changes"

# --- Manual overrides and name collisions ---
MANUAL_ROOT="${TEST_TMPDIR}/manual"
test_stage_workspace "${MANUAL_ROOT}"
mkdir -p "${MANUAL_ROOT}/resources" "${MANUAL_ROOT}/server.d"

# Resource with the same name as a template candidate; template should be skipped
printf 'resource-one' >"${MANUAL_ROOT}/resources/resource.txt"
cat >"${MANUAL_ROOT}/resources/shared.meta.json" <<EOF
{"name":"shared-name","uri":"file://${MANUAL_ROOT}/resources/resource.txt"}
EOF
cat >"${MANUAL_ROOT}/resources/shared-template.meta.json" <<'EOF'
{"name":"shared-name","uriTemplate":"file:///{sharedPath}"}
EOF

# Auto-discovered template that will be overridden
cat >"${MANUAL_ROOT}/resources/override.me.meta.json" <<'EOF'
{"name":"override-me","uriTemplate":"file:///{original}","description":"auto"}
EOF

# Manual registrations: override and add a unique entry
cat >"${MANUAL_ROOT}/server.d/register.sh" <<'EOF'
#!/usr/bin/env bash
mcp_resources_templates_manual_begin
mcp_resources_templates_register_manual '{
  "name": "override-me",
  "uriTemplate": "git+https://{repo}/{path}",
  "description": "manual wins",
  "mimeType": "application/x-git"
}'
mcp_resources_templates_register_manual '{
  "name": "manual-only",
  "uriTemplate": "file:///var/log/{service}/{date}.log",
  "title": "Logs by date"
}'
mcp_resources_templates_manual_finalize
EOF
chmod +x "${MANUAL_ROOT}/server.d/register.sh"

cat >"${MANUAL_ROOT}/requests-manual.ndjson" <<'JSON'
{"jsonrpc":"2.0","id":"init-manual","method":"initialize","params":{}}
{"jsonrpc":"2.0","method":"notifications/initialized"}
{"jsonrpc":"2.0","id":"manual-list","method":"resources/templates/list","params":{}}
JSON

run_with_env "${MANUAL_ROOT}" "${MANUAL_ROOT}/requests-manual.ndjson" "${MANUAL_ROOT}/responses-manual.ndjson"

jq -s '
	def err(msg): error(msg);
	(map(select(.id == "manual-list"))[0].result) as $list |
	$list.resourceTemplates as $templates |

	if ($list._meta["mcpbash/total"] != 2) then err("expected two templates after collision/override filtering") else null end,
	if ($templates | map(.name) | sort != ["manual-only","override-me"]) then err("unexpected template names") else null end,
	if ($templates | map(select(.name == "shared-name")) | length) != 0 then err("resource collision should skip shared-name") else null end,
	($templates[] | select(.name == "override-me")) as $override |
	if $override.uriTemplate != "git+https://{repo}/{path}" then err("manual override did not win") else null end,
	($templates[] | select(.name == "manual-only")) as $manual |
	if $manual.title != "Logs by date" then err("manual-only template missing title") else null end
' <"${MANUAL_ROOT}/responses-manual.ndjson" >/dev/null
