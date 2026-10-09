#!/usr/bin/env bash
# Integration: only framework-owned MCP_* names reach tools and providers.
# shellcheck disable=SC2034  # Used by test runner for reporting.
TEST_DESC="User-set MCP_* secrets stay out of tool and provider env unless allowlisted."

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../common/env.sh
# shellcheck disable=SC1091
. "${SCRIPT_DIR}/../common/env.sh"
# shellcheck source=../common/assert.sh
# shellcheck disable=SC1091
. "${SCRIPT_DIR}/../common/assert.sh"

test_require_command jq

test_create_tmpdir
WORKSPACE="${TEST_TMPDIR}/mcp-names"
test_stage_workspace "${WORKSPACE}"

# Tool: report which MCP_* names it can see (states only, plus the sentinel check).
mkdir -p "${WORKSPACE}/tools/envprobe"
cat <<'META' >"${WORKSPACE}/tools/envprobe/tool.meta.json"
{"name":"envprobe","description":"Report MCP_* visibility","arguments":{"type":"object","properties":{}}}
META
cat <<'SH' >"${WORKSPACE}/tools/envprobe/tool.sh"
#!/usr/bin/env bash
set -euo pipefail
printf 'registry=[%s] args=[%s] sdk=[%s] custom=[%s]' \
	"${MCP_REGISTRY_TOKEN:-}" "${MCP_TOOL_ARGS_JSON:+set}" "${MCP_SDK:+set}" "${MCP_CUSTOM_SETTING:-}"
SH
chmod +x "${WORKSPACE}/tools/envprobe/tool.sh"

# Resource provider: same report for the provider curated env.
mkdir -p "${WORKSPACE}/providers" "${WORKSPACE}/resources"
cat <<'SH' >"${WORKSPACE}/providers/probe.sh"
#!/usr/bin/env bash
set -euo pipefail
printf 'registry=[%s] roots=[%s]' "${MCP_REGISTRY_TOKEN:-}" "${MCP_RESOURCES_ROOTS:+set}"
SH
chmod +x "${WORKSPACE}/providers/probe.sh"
echo placeholder >"${WORKSPACE}/resources/probe.txt"
cat <<'META' >"${WORKSPACE}/resources/probe.meta.json"
{"name":"probe","uri":"probe://env","provider":"probe"}
META

cat <<'JSON' >"${WORKSPACE}/requests.ndjson"
{"jsonrpc":"2.0","id":"init","method":"initialize","params":{}}
{"jsonrpc":"2.0","method":"notifications/initialized"}
{"jsonrpc":"2.0","id":"tool","method":"tools/call","params":{"name":"envprobe","arguments":{}}}
{"jsonrpc":"2.0","id":"res","method":"resources/read","params":{"uri":"probe://env"}}
JSON

# run_case <label> -- runs the requests with the caller's env; prints "tool<TAB>resource" text.
run_case() {
	local label="$1"
	local resp="${WORKSPACE}/responses-${label}.ndjson"
	test_run_mcp "${WORKSPACE}" "${WORKSPACE}/requests.ndjson" "${resp}"
	assert_json_lines "${resp}"
	TOOL_TEXT="$(jq -r 'select(.id=="tool") | .result.content[0].text // ("ERROR: " + (.error.message // "none"))' "${resp}")"
	RES_TEXT="$(jq -r 'select(.id=="res") | .result.contents[0].text // ("ERROR: " + (.error.message // "none"))' "${resp}")"
}

expect_contains() {
	local label="$1" have="$2" want="$3"
	case "${have}" in
	*"${want}"*) ;;
	*) test_fail "${label}: expected '${want}' in: ${have}" ;;
	esac
}

# Default modes (tool minimal, provider isolate): user-set MCP_* stays out;
# framework MCP_* still arrives.
MCP_REGISTRY_TOKEN="registry-sentinel" MCP_CUSTOM_SETTING="custom-sentinel" \
	MCPBASH_TOOL_ENV_MODE=minimal MCPBASH_PROVIDER_ENV_MODE=isolate run_case default
expect_contains "tool/minimal" "${TOOL_TEXT}" "registry=[] args=[set] sdk=[set] custom=[]"
expect_contains "provider/isolate" "${RES_TEXT}" "registry=[] roots=[set]"

# Allowlist modes: an operator-allowlisted non-framework MCP_* name passes.
MCP_REGISTRY_TOKEN="registry-sentinel" MCP_CUSTOM_SETTING="custom-sentinel" \
	MCPBASH_TOOL_ENV_MODE=allowlist MCPBASH_TOOL_ENV_ALLOWLIST="MCP_REGISTRY_TOKEN" \
	MCPBASH_PROVIDER_ENV_MODE=allowlist MCPBASH_PROVIDER_ENV_ALLOWLIST="MCP_REGISTRY_TOKEN" \
	run_case allowlist
expect_contains "tool/allowlist" "${TOOL_TEXT}" "registry=[registry-sentinel] args=[set] sdk=[set] custom=[]"
expect_contains "provider/allowlist" "${RES_TEXT}" "registry=[registry-sentinel] roots=[set]"

# server.meta.json may now name a non-framework MCP_* variable in its allowlists.
cat <<'META' >"${WORKSPACE}/server.d/server.meta.json"
{"name":"mcp-names","env":{"MCPBASH_TOOL_ENV_MODE":"allowlist","MCPBASH_TOOL_ENV_ALLOWLIST":"MCP_REGISTRY_TOKEN","MCPBASH_PROVIDER_ENV_MODE":"allowlist","MCPBASH_PROVIDER_ENV_ALLOWLIST":"MCP_REGISTRY_TOKEN"}}
META
MCP_REGISTRY_TOKEN="registry-sentinel" MCP_CUSTOM_SETTING="custom-sentinel" run_case meta
expect_contains "tool/meta-allowlist" "${TOOL_TEXT}" "registry=[registry-sentinel] args=[set] sdk=[set] custom=[]"
expect_contains "provider/meta-allowlist" "${RES_TEXT}" "registry=[registry-sentinel] roots=[set]"
if grep -q "ignoring MCPBASH_TOOL_ENV_ALLOWLIST" "${WORKSPACE}/responses-meta.ndjson.stderr"; then
	test_fail "server.meta.json allowlist naming MCP_REGISTRY_TOKEN was refused"
fi

printf 'MCP_* env narrowing passed.\n'
