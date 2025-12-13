#!/usr/bin/env bash
# shellcheck disable=SC2034  # Used by test runner for reporting.
TEST_DESC="Tool discovery, calls, and list_changed notifications."
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../common/env.sh
# shellcheck disable=SC1091
. "${SCRIPT_DIR}/../common/env.sh"
# shellcheck source=../common/assert.sh
# shellcheck disable=SC1091
. "${SCRIPT_DIR}/../common/assert.sh"

test_create_tmpdir

run_server() {
	local project_root="$1"
	local request_file="$2"
	local response_file="$3"
	(
		# Run the framework from MCPBASH_HOME and point it at a throw-away project
		# root under TEST_TMPDIR. This avoids staging/copying the entire framework
		# into each scenario directory, which is very expensive on Windows/MSYS.
		cd "${project_root}" || exit 1
		MCPBASH_PROJECT_ROOT="${project_root}" mcp-bash <"${request_file}" >"${response_file}"
	)
}

create_project_root() {
	local dest="$1"
	mkdir -p "${dest}/tools" "${dest}/resources" "${dest}/prompts" "${dest}/server.d"
}

base64_url_decode() {
	local input="$1"
	local converted="${input//-/+}"
	converted="${converted//_/\/}"
	local pad=$(((4 - (${#converted} % 4)) % 4))
	case "${pad}" in
	1) converted="${converted}=" ;;
	2) converted="${converted}==" ;;
	3) converted="${converted}===" ;;
	esac

	local decoded
	if decoded="$(printf '%s' "${converted}" | base64 --decode 2>/dev/null)"; then
		printf '%s' "${decoded}"
		return 0
	fi
	if decoded="$(printf '%s' "${converted}" | base64 -d 2>/dev/null)"; then
		printf '%s' "${decoded}"
		return 0
	fi
	if decoded="$(printf '%s' "${converted}" | base64 -D 2>/dev/null)"; then
		printf '%s' "${decoded}"
		return 0
	fi
	if command -v openssl >/dev/null 2>&1; then
		if decoded="$(printf '%s' "${converted}" | openssl base64 -d -A 2>/dev/null)"; then
			printf '%s' "${decoded}"
			return 0
		fi
	fi
	return 1
}

# --- Auto-discovery pagination and structured output ---
AUTO_ROOT="${TEST_TMPDIR}/auto"
create_project_root "${AUTO_ROOT}"
# No server.d/register.sh so auto-discovery is used.
mkdir -p "${AUTO_ROOT}/tools"
cp -a "${MCPBASH_HOME}/examples/00-hello-tool/tools/." "${AUTO_ROOT}/tools/"

mkdir -p "${AUTO_ROOT}/tools/world"
cat <<'METADATA' >"${AUTO_ROOT}/tools/world/tool.meta.json"
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

cat <<'SH' >"${AUTO_ROOT}/tools/world/tool.sh"
#!/usr/bin/env bash
printf '{"message":"world"}'
SH
chmod +x "${AUTO_ROOT}/tools/world/tool.sh"

cat <<'JSON' >"${AUTO_ROOT}/requests.ndjson"
{"jsonrpc":"2.0","id":"auto-init","method":"initialize","params":{}}
{"jsonrpc":"2.0","method":"notifications/initialized"}
{"jsonrpc":"2.0","id":"auto-list","method":"tools/list","params":{"limit":1}}
{"jsonrpc":"2.0","id":"auto-call","method":"tools/call","params":{"name":"world","arguments":{}}}
JSON

run_server "${AUTO_ROOT}" "${AUTO_ROOT}/requests.ndjson" "${AUTO_ROOT}/responses.ndjson"

# Dump responses on verbose mode for debugging Windows CI failures
if [ "${VERBOSE:-0}" = "1" ]; then
	echo "=== AUTO_ROOT responses.ndjson ===" >&2
	cat "${AUTO_ROOT}/responses.ndjson" >&2 || true
	echo "=== end responses ===" >&2
fi

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
decoded_cursor="$(base64_url_decode "${next_cursor}")" || test_fail "failed to base64url-decode nextCursor"
if ! printf '%s' "${decoded_cursor}" | jq -e '.timestamp | type == "string" and (. | length) > 0' >/dev/null; then
	test_fail "expected cursor payload to include non-empty timestamp"
fi

call_resp="$(grep '"id":"auto-call"' "${AUTO_ROOT}/responses.ndjson" | head -n1)"
# Check if response is an error before trying to parse result
if echo "$call_resp" | jq -e '.error' >/dev/null 2>&1; then
	echo "Tool call returned error:" >&2
	echo "$call_resp" | jq '.error' >&2
	test_fail "auto-call returned error instead of result"
fi
message="$(echo "$call_resp" | jq -r '.result.structuredContent.message // empty')"
text="$(echo "$call_resp" | jq -r '(.result.content // [])[] | select(.type=="text") | .text' | head -n1)"
exit_code="$(echo "$call_resp" | jq -r '.result._meta.exitCode // empty')"

test_assert_eq "$message" "world"
if [[ "$text" != *"world"* ]]; then
	test_fail "tool text fallback missing expected output"
fi
test_assert_eq "$exit_code" "0"

# --- Manual registration overrides ---
MANUAL_ROOT="${TEST_TMPDIR}/manual"
create_project_root "${MANUAL_ROOT}"
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
create_project_root "${ENV_ROOT}"
mkdir -p "${ENV_ROOT}/tools/env"

cat <<'META' >"${ENV_ROOT}/tools/env/tool.meta.json"
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

cat <<'SH' >"${ENV_ROOT}/tools/env/tool.sh"
#!/usr/bin/env bash
set -euo pipefail
printf '{"foo":"%s","bar":"%s"}' "${FOO:-}" "${BAR:-}"
SH
chmod +x "${ENV_ROOT}/tools/env/tool.sh"

cat <<'JSON' >"${ENV_ROOT}/requests.ndjson"
{"jsonrpc":"2.0","id":"init","method":"initialize","params":{}}
{"jsonrpc":"2.0","method":"notifications/initialized"}
{"jsonrpc":"2.0","id":"env","method":"tools/call","params":{"name":"env.echo","arguments":{}}}
JSON

(
	cd "${ENV_ROOT}" || exit 1
	FOO="hidden" BAR="visible" MCPBASH_TOOL_ENV_MODE="minimal" MCPBASH_PROJECT_ROOT="${ENV_ROOT}" mcp-bash <"requests.ndjson" >"responses.ndjson"
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
	FOO="hidden" BAR="visible" MCPBASH_TOOL_ENV_MODE="allowlist" MCPBASH_TOOL_ENV_ALLOWLIST="BAR" MCPBASH_PROJECT_ROOT="${ENV_ROOT}" mcp-bash <"requests_allowlist.ndjson" >"responses_allowlist.ndjson"
)

foo_allow="$(jq -r 'select(.id=="env-allow") | .result.structuredContent.foo // empty' "${ENV_ROOT}/responses_allowlist.ndjson")"
bar_allow="$(jq -r 'select(.id=="env-allow") | .result.structuredContent.bar // empty' "${ENV_ROOT}/responses_allowlist.ndjson")"
if [ -n "${foo_allow}" ]; then
	test_fail "allowlist mode should not include FOO"
fi
if [ "${bar_allow}" != "visible" ]; then
	test_fail "allowlist mode should include BAR"
fi

# --- Embedded resources in tool output ---
EMBED_ROOT="${TEST_TMPDIR}/embed"
create_project_root "${EMBED_ROOT}"
# No server.d/register.sh so auto-discovery is used.
mkdir -p "${EMBED_ROOT}/tools/embed" "${EMBED_ROOT}/resources"

cat <<'META' >"${EMBED_ROOT}/tools/embed/tool.meta.json"
{
  "name": "embed-resource",
  "description": "Emits embedded resource content",
  "arguments": {"type": "object", "properties": {}}
}
META

cat <<'SH' >"${EMBED_ROOT}/tools/embed/tool.sh"
#!/usr/bin/env bash
set -euo pipefail
payload_path="${MCPBASH_PROJECT_ROOT}/resources/payload.txt"
mkdir -p "$(dirname "${payload_path}")"
printf 'embedded-content' >"${payload_path}"
if [ -n "${MCP_TOOL_RESOURCES_FILE:-}" ]; then
	printf '%s\ttext/plain\t\n' "${payload_path}" >>"${MCP_TOOL_RESOURCES_FILE}"
fi
printf 'ok'
SH
chmod +x "${EMBED_ROOT}/tools/embed/tool.sh"

cat <<'JSON' >"${EMBED_ROOT}/requests.ndjson"
{"jsonrpc":"2.0","id":"embed-init","method":"initialize","params":{}}
{"jsonrpc":"2.0","method":"notifications/initialized"}
{"jsonrpc":"2.0","id":"embed-call","method":"tools/call","params":{"name":"embed-resource","arguments":{}}}
JSON

run_server "${EMBED_ROOT}" "${EMBED_ROOT}/requests.ndjson" "${EMBED_ROOT}/responses.ndjson"

embed_resp="$(grep '"id":"embed-call"' "${EMBED_ROOT}/responses.ndjson" | head -n1)"
if echo "$embed_resp" | jq -e '.error' >/dev/null 2>&1; then
	echo "Embed tool call returned error:" >&2
	echo "$embed_resp" | jq '.error' >&2
	test_fail "embed-call returned error instead of result"
fi
embed_resource_count="$(echo "$embed_resp" | jq '[(.result.content // [])[] | select(.type=="resource")] | length')"
embed_resource_text="$(echo "$embed_resp" | jq -r '(.result.content // [])[] | select(.type=="resource") | .resource.text // empty' | head -n1)"
embed_resource_mime="$(echo "$embed_resp" | jq -r '(.result.content // [])[] | select(.type=="resource") | .resource.mimeType // empty' | head -n1)"

if [ "${embed_resource_count}" -ne 1 ]; then
	test_fail "expected one embedded resource content part"
fi
test_assert_eq "${embed_resource_text}" "embedded-content"
test_assert_eq "${embed_resource_mime}" "text/plain"

# --- Structured tool error propagation ---
FAIL_ROOT="${TEST_TMPDIR}/fail"
create_project_root "${FAIL_ROOT}"
mkdir -p "${FAIL_ROOT}/tools/fail"

cat <<'META' >"${FAIL_ROOT}/tools/fail/tool.meta.json"
{
  "name": "fail-tool",
  "description": "Returns a structured error",
  "arguments": {
    "type": "object",
    "properties": {}
  }
}
META

cat <<'SH' >"${FAIL_ROOT}/tools/fail/tool.sh"
#!/usr/bin/env bash
set -euo pipefail
source "${MCP_SDK}/tool-sdk.sh"
mcp_fail_invalid_args "bad input" '{"hint":"fix it"}'
SH
chmod +x "${FAIL_ROOT}/tools/fail/tool.sh"

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
