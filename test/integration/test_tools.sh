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
	# Copy framework files
	cp -a "${MCPBASH_HOME}/bin" "${dest}/"
	cp -a "${MCPBASH_HOME}/lib" "${dest}/"
	cp -a "${MCPBASH_HOME}/handlers" "${dest}/"
	cp -a "${MCPBASH_HOME}/providers" "${dest}/"
	cp -a "${MCPBASH_HOME}/sdk" "${dest}/"
	cp -a "${MCPBASH_HOME}/scaffold" "${dest}/" 2>/dev/null || true
	# Create project directories
	mkdir -p "${dest}/tools"
	mkdir -p "${dest}/resources"
	mkdir -p "${dest}/prompts"
	mkdir -p "${dest}/server.d"
}

run_server() {
	local workdir="$1"
	local request_file="$2"
	local response_file="$3"
	(
		cd "${workdir}" || exit 1
		MCPBASH_PROJECT_ROOT="${workdir}" ./bin/mcp-bash <"${request_file}" >"${response_file}"
	)
}

# --- Auto-discovery pagination and structured output ---
AUTO_ROOT="${TEST_TMPDIR}/auto"
stage_workspace "${AUTO_ROOT}"
# Remove register.sh to force auto-discovery (chmod -x doesn't work on Windows)
rm -f "${AUTO_ROOT}/server.d/register.sh"
mkdir -p "${AUTO_ROOT}/tools"
cp -a "${MCPBASH_HOME}/examples/00-hello-tool/tools/." "${AUTO_ROOT}/tools/"

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
tools_count="$(echo "$list_resp" | jq '.result.tools | length')"
next_cursor="$(echo "$list_resp" | jq -r '.result.nextCursor // empty')"

# With limit=1, we should get 1 tool and a nextCursor if there are more
if [ "$tools_count" -lt 1 ]; then
	test_fail "expected at least one tool in paginated result"
fi
if [ -z "$next_cursor" ]; then
	test_fail "expected nextCursor for pagination (indicates more tools exist)"
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

# Paths are relative to MCPBASH_TOOLS_DIR (not MCPBASH_PROJECT_ROOT)
mcp_register_tool '{
  "name": "manual-alpha",
  "description": "Manual alpha tool",
  "path": "manual/alpha.sh",
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
  "path": "manual/beta.sh",
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
tools_count="$(echo "$list_resp" | jq '.result.tools | length')"
next_cursor="$(echo "$list_resp" | jq -r '.result.nextCursor // empty')"
names="$(echo "$list_resp" | jq -r '.result.tools[].name')"

# With limit=1, we should get 1 tool
if [ "$tools_count" -lt 1 ]; then
	test_fail "expected at least one tool in manual registry"
fi
if [ -z "$next_cursor" ]; then
	test_fail "manual registry should provide nextCursor for pagination"
fi
if [[ "$names" != *"manual-alpha"* ]] && [[ "$names" != *"manual-beta"* ]]; then
	test_fail "manual tools missing from manual registry"
fi
if [[ "$names" == *"hello"* ]]; then
	test_fail "auto-discovered tools should not appear when manual registry is active"
fi

call_resp="$(grep '"id":"manual-call"' "${MANUAL_ROOT}/responses.ndjson" | head -n1)"
alpha="$(echo "$call_resp" | jq -r '.result.structuredContent.alpha // empty')"
exit_code="$(echo "$call_resp" | jq -r '.result._meta.exitCode // empty')"

test_assert_eq "$alpha" "one"
test_assert_eq "$exit_code" "0"

# --- Tool environment isolation (minimal vs allowlist) ---
ENV_ROOT="${TEST_TMPDIR}/env"
stage_workspace "${ENV_ROOT}"
mkdir -p "${ENV_ROOT}/tools"

cat <<'META' >"${ENV_ROOT}/tools/env.meta.json"
{
  "name": "env.echo",
  "description": "Echo selected env",
  "arguments": {"type": "object", "properties": {}},
  "outputSchema": {
    "type": "object",
    "properties": {
      "foo": {"type": "string"},
      "bar": {"type": "string"}
    },
    "required": ["foo","bar"]
  }
}
META

cat <<'SH' >"${ENV_ROOT}/tools/env.sh"
#!/usr/bin/env bash
set -euo pipefail
printf '{"foo":"%s","bar":"%s"}' "${FOO:-}" "${BAR:-}"
SH
chmod +x "${ENV_ROOT}/tools/env.sh"

cat <<'JSON' >"${ENV_ROOT}/requests.ndjson"
{"jsonrpc":"2.0","id":"init","method":"initialize","params":{}}
{"jsonrpc":"2.0","method":"notifications/initialized"}
{"jsonrpc":"2.0","id":"env","method":"tools/call","params":{"name":"env.echo","arguments":{}}}
JSON

(
	cd "${ENV_ROOT}" || exit 1
	FOO="hidden" BAR="visible" MCPBASH_TOOL_ENV_MODE="minimal" MCPBASH_PROJECT_ROOT="${ENV_ROOT}" ./bin/mcp-bash <"requests.ndjson" >"responses.ndjson"
)

foo_val="$(jq -r 'select(.id=="env") | .result.structuredContent.foo // empty' "${ENV_ROOT}/responses.ndjson")"
bar_val="$(jq -r 'select(.id=="env") | .result.structuredContent.bar // empty' "${ENV_ROOT}/responses.ndjson")"
if [ -n "${foo_val}" ] || [ -n "${bar_val}" ]; then
	test_fail "minimal env isolation leaked vars: foo='${foo_val}' bar='${bar_val}'"
fi

cat <<'JSON' >"${ENV_ROOT}/requests_allowlist.ndjson"
{"jsonrpc":"2.0","id":"init","method":"initialize","params":{}}
{"jsonrpc":"2.0","method":"notifications/initialized"}
{"jsonrpc":"2.0","id":"env-allow","method":"tools/call","params":{"name":"env.echo","arguments":{}}}
JSON

(
	cd "${ENV_ROOT}" || exit 1
	FOO="hidden" BAR="visible" MCPBASH_TOOL_ENV_MODE="allowlist" MCPBASH_TOOL_ENV_ALLOWLIST="BAR" MCPBASH_PROJECT_ROOT="${ENV_ROOT}" ./bin/mcp-bash <"requests_allowlist.ndjson" >"responses_allowlist.ndjson"
)

foo_allow="$(jq -r 'select(.id=="env-allow") | .result.structuredContent.foo // empty' "${ENV_ROOT}/responses_allowlist.ndjson")"
bar_allow="$(jq -r 'select(.id=="env-allow") | .result.structuredContent.bar // empty' "${ENV_ROOT}/responses_allowlist.ndjson")"
if [ -n "${foo_allow}" ]; then
	test_fail "allowlist mode should not include FOO"
fi
if [ "${bar_allow}" != "visible" ]; then
	test_fail "allowlist mode should include BAR"
fi

# --- Structured tool error propagation ---
FAIL_ROOT="${TEST_TMPDIR}/fail"
stage_workspace "${FAIL_ROOT}"

cat <<'META' >"${FAIL_ROOT}/tools/fail.meta.json"
{
  "name": "fail-tool",
  "description": "Returns a structured error",
  "arguments": {
    "type": "object",
    "properties": {}
  }
}
META

cat <<'SH' >"${FAIL_ROOT}/tools/fail.sh"
#!/usr/bin/env bash
set -euo pipefail
source "${MCP_SDK}/tool-sdk.sh"
mcp_fail_invalid_args "bad input" '{"hint":"fix it"}'
SH
chmod +x "${FAIL_ROOT}/tools/fail.sh"

cat <<'JSON' >"${FAIL_ROOT}/requests.ndjson"
{"jsonrpc":"2.0","id":"fail-init","method":"initialize","params":{}}
{"jsonrpc":"2.0","method":"notifications/initialized"}
{"jsonrpc":"2.0","id":"fail-call","method":"tools/call","params":{"name":"fail-tool","arguments":{}}}
JSON

run_server "${FAIL_ROOT}" "${FAIL_ROOT}/requests.ndjson" "${FAIL_ROOT}/responses.ndjson"

fail_resp="$(grep '"id":"fail-call"' "${FAIL_ROOT}/responses.ndjson" | head -n1)"
fail_code="$(echo "$fail_resp" | jq '.error.code')"
fail_message="$(echo "$fail_resp" | jq -r '.error.message')"
fail_hint="$(echo "$fail_resp" | jq -r '.error.data.hint // empty')"

test_assert_eq "$fail_code" "-32602"
test_assert_eq "$fail_message" "bad input"
test_assert_eq "$fail_hint" "fix it"
