#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../common/env.sh
# shellcheck disable=SC1091
. "${SCRIPT_DIR}/../common/env.sh"
# shellcheck source=../common/assert.sh
# shellcheck disable=SC1091
. "${SCRIPT_DIR}/../common/assert.sh"

test_create_tmpdir

stage_workspace() {
	local dest="$1"
	mkdir -p "${dest}"
	cp -a "${MCPBASH_ROOT}/bin" "${dest}/"
	cp -a "${MCPBASH_ROOT}/lib" "${dest}/"
	cp -a "${MCPBASH_ROOT}/handlers" "${dest}/"
	cp -a "${MCPBASH_ROOT}/providers" "${dest}/"
	cp -a "${MCPBASH_ROOT}/sdk" "${dest}/"
	cp -a "${MCPBASH_ROOT}/resources" "${dest}/" 2>/dev/null || true
	cp -a "${MCPBASH_ROOT}/prompts" "${dest}/" 2>/dev/null || true
	cp -a "${MCPBASH_ROOT}/server.d" "${dest}/"
}

run_server() {
	local workdir="$1"
	local request_file="$2"
	local response_file="$3"
	(
		cd "${workdir}" || exit 1
		./bin/mcp-bash <"${request_file}" >"${response_file}"
	)
}

# --- Auto-discovery pagination and structured output ---
AUTO_ROOT="${TEST_TMPDIR}/auto"
stage_workspace "${AUTO_ROOT}"
chmod -x "${AUTO_ROOT}/server.d/register.sh"
mkdir -p "${AUTO_ROOT}/tools"
cp -a "${MCPBASH_ROOT}/examples/00-hello-tool/tools/." "${AUTO_ROOT}/tools/"

cat <<'METADATA' >"${AUTO_ROOT}/tools/world.meta.json"
{
  "name": "world",
  "description": "Structured world tool",
  "arguments": {
    "type": "object",
    "properties": {}
  },
  "outputSchema": {
    "type": "object",
    "properties": {
      "message": { "type": "string" }
    },
    "required": ["message"]
  }
}
METADATA

cat <<'SH' >"${AUTO_ROOT}/tools/world.sh"
#!/usr/bin/env bash
printf '{"message":"world"}'
SH
chmod +x "${AUTO_ROOT}/tools/world.sh"

cat <<'JSON' >"${AUTO_ROOT}/requests.ndjson"
{"jsonrpc":"2.0","id":"auto-init","method":"initialize","params":{}}
{"jsonrpc":"2.0","method":"notifications/initialized"}
{"jsonrpc":"2.0","id":"auto-list","method":"tools/list","params":{"limit":1}}
{"jsonrpc":"2.0","id":"auto-call","method":"tools/call","params":{"name":"world","arguments":{}}}
JSON

run_server "${AUTO_ROOT}" "${AUTO_ROOT}/requests.ndjson" "${AUTO_ROOT}/responses.ndjson"

list_resp="$(grep '"id":"auto-list"' "${AUTO_ROOT}/responses.ndjson" | head -n1)"
total="$(echo "$list_resp" | jq '.result.total // 0')"
next_cursor="$(echo "$list_resp" | jq -r '.result.nextCursor // empty')"

if [ "$total" -lt 2 ]; then
	test_fail "expected at least two tools discovered"
fi
if [ -z "$next_cursor" ]; then
	test_fail "expected nextCursor for pagination"
fi

call_resp="$(grep '"id":"auto-call"' "${AUTO_ROOT}/responses.ndjson" | head -n1)"
message="$(echo "$call_resp" | jq -r '.result.structuredContent.message // empty')"
text="$(echo "$call_resp" | jq -r '.result.content[] | select(.type=="text") | .text' | head -n1)"
exit_code="$(echo "$call_resp" | jq -r '.result._meta.exitCode // empty')"

test_assert_eq "$message" "world"
if [[ "$text" != *"world"* ]]; then
	test_fail "tool text fallback missing expected output"
fi
test_assert_eq "$exit_code" "0"

# --- Manual registration overrides ---
MANUAL_ROOT="${TEST_TMPDIR}/manual"
stage_workspace "${MANUAL_ROOT}"
mkdir -p "${MANUAL_ROOT}/tools/manual"

cat <<'SH' >"${MANUAL_ROOT}/tools/manual/alpha.sh"
#!/usr/bin/env bash
printf '{"alpha":"one"}'
SH
chmod +x "${MANUAL_ROOT}/tools/manual/alpha.sh"

cat <<'SH' >"${MANUAL_ROOT}/tools/manual/beta.sh"
#!/usr/bin/env bash
printf 'beta'
SH
chmod +x "${MANUAL_ROOT}/tools/manual/beta.sh"

cat <<'SCRIPT' >"${MANUAL_ROOT}/server.d/register.sh"
#!/usr/bin/env bash
set -euo pipefail

mcp_register_tool '{
  "name": "manual-alpha",
  "description": "Manual alpha tool",
  "path": "tools/manual/alpha.sh",
  "arguments": {"type": "object", "properties": {}},
  "outputSchema": {
    "type": "object",
    "properties": {"alpha": {"type": "string"}},
    "required": ["alpha"]
  }
}'

mcp_register_tool '{
  "name": "manual-beta",
  "description": "Manual beta tool",
  "path": "tools/manual/beta.sh",
  "arguments": {"type": "object", "properties": {}}
}'

return 0
SCRIPT
chmod +x "${MANUAL_ROOT}/server.d/register.sh"

cat <<'JSON' >"${MANUAL_ROOT}/requests.ndjson"
{"jsonrpc":"2.0","id":"manual-init","method":"initialize","params":{}}
{"jsonrpc":"2.0","method":"notifications/initialized"}
{"jsonrpc":"2.0","id":"manual-list","method":"tools/list","params":{"limit":1}}
{"jsonrpc":"2.0","id":"manual-call","method":"tools/call","params":{"name":"manual-alpha","arguments":{}}}
JSON

run_server "${MANUAL_ROOT}" "${MANUAL_ROOT}/requests.ndjson" "${MANUAL_ROOT}/responses.ndjson"

list_resp="$(grep '"id":"manual-list"' "${MANUAL_ROOT}/responses.ndjson" | head -n1)"
total="$(echo "$list_resp" | jq '.result.total // 0')"
next_cursor="$(echo "$list_resp" | jq -r '.result.nextCursor // empty')"
names="$(echo "$list_resp" | jq -r '.result.items[].name')"

test_assert_eq "$total" "2"
if [ -z "$next_cursor" ]; then
	test_fail "manual registry should provide nextCursor for pagination"
fi
if [[ "$names" != *"manual-alpha"* ]]; then
	test_fail "manual-alpha missing from manual registry"
fi
if [[ "$names" == *"hello"* ]]; then
	test_fail "auto-discovered tools should not appear when manual registry is active"
fi

call_resp="$(grep '"id":"manual-call"' "${MANUAL_ROOT}/responses.ndjson" | head -n1)"
alpha="$(echo "$call_resp" | jq -r '.result.structuredContent.alpha // empty')"
exit_code="$(echo "$call_resp" | jq -r '.result._meta.exitCode // empty')"

test_assert_eq "$alpha" "one"
test_assert_eq "$exit_code" "0"
