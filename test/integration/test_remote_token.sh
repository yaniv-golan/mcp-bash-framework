#!/usr/bin/env bash
# Integration: remote token guard enforces per-request shared secret.
# shellcheck disable=SC2034  # Used by test runner for reporting.
TEST_DESC="Remote token guard rejects missing/invalid tokens and accepts valid ones."

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
WORKSPACE="${TEST_TMPDIR}/remote-token"
test_stage_workspace "${WORKSPACE}"

REQUESTS="${WORKSPACE}/requests.ndjson"
cat <<'JSON' >"${REQUESTS}"
{"jsonrpc":"2.0","id":"missing","method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{}}}
{"jsonrpc":"2.0","id":"bad","method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{},"_meta":{"mcpbash/remoteToken":"wrong"}}}
{"jsonrpc":"2.0","id":"ok","method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{},"_meta":{"mcpbash/remoteToken":"dummy-test-token-0123456789abcdef"}}}
JSON

RESPONSES="${WORKSPACE}/responses.ndjson"

MCPBASH_REMOTE_TOKEN="dummy-test-token-0123456789abcdef" test_run_mcp "${WORKSPACE}" "${REQUESTS}" "${RESPONSES}"

assert_json_lines "${RESPONSES}"

codes="$(
	jq -r '
		[
			(.id // "unknown"),
			(if has("error") then (.error.code|tostring) else "ok" end)
		] | @tsv
	' "${RESPONSES}"
)"

expect_code() {
	local id="$1" want="$2"
	local line
	line="$(printf '%s\n' "${codes}" | awk -v id="${id}" '$1==id {print $0}')"
	if [ -z "${line}" ]; then
		test_fail "Missing response for id=${id}"
	fi
	local have
	have="$(printf '%s' "${line}" | awk '{print $2}')"
	if [ "${have}" != "${want}" ]; then
		test_fail "id=${id} expected ${want}, got ${have}"
	fi
}

expect_code "missing" "-32602"
expect_code "bad" "-32602"
expect_code "ok" "ok"

# --- The token never reaches tools: env (minimal/allowlist) or request _meta ---
TOKEN="dummy-test-token-0123456789abcdef"
mkdir -p "${WORKSPACE}/tools/tokenprobe"
cat <<'META' >"${WORKSPACE}/tools/tokenprobe/tool.meta.json"
{"name":"tokenprobe","description":"Report remote-token visibility","arguments":{"type":"object","properties":{}}}
META
cat <<'SH' >"${WORKSPACE}/tools/tokenprobe/tool.sh"
#!/usr/bin/env bash
set -euo pipefail
names="$(env | awk -F= '/^MCPBASH_REMOTE_TOKEN/ {print $1}' | tr '\n' ',')"
meta="${MCP_TOOL_META_JSON:-}"
if [ -n "${MCP_TOOL_META_FILE:-}" ]; then
	meta="$(cat "${MCP_TOOL_META_FILE}")"
fi
printf 'names=[%s] set=[%s] meta=%s' "${names}" "${MCPBASH_REMOTE_TOKEN+set}" "${meta}"
SH
chmod +x "${WORKSPACE}/tools/tokenprobe/tool.sh"

# probe_run <label> <primary-key>: initialize + tools/call carrying the token
# under the given key and the legacy fallback key, plus an unrelated key.
probe_run() {
	local label="$1" key="$2"
	local req="${WORKSPACE}/probe-${label}.ndjson" resp="${WORKSPACE}/probe-${label}.out.ndjson"
	jq -cn --arg k "${key}" --arg t "${TOKEN}" '
		{jsonrpc:"2.0",id:"init",method:"initialize",params:{protocolVersion:"2025-11-25",capabilities:{},_meta:{($k):$t}}},
		{jsonrpc:"2.0",method:"notifications/initialized",params:{_meta:{($k):$t}}},
		{jsonrpc:"2.0",id:"probe",method:"tools/call",params:{name:"tokenprobe",arguments:{},_meta:{($k):$t,remoteToken:$t,keep:"yes"}}}
	' >"${req}"
	test_run_mcp "${WORKSPACE}" "${req}" "${resp}"
	assert_json_lines "${resp}"
	local text
	text="$(jq -r 'select(.id=="probe") | .result.content[0].text // ("ERROR: " + (.error.message // "no result"))' "${resp}")"
	case "${text}" in
	*"names=[]"*"set=[]"*) ;;
	*) test_fail "${label}: MCPBASH_REMOTE_TOKEN* visible to tool: ${text%% meta=*}" ;;
	esac
	case "${text}" in
	*"${TOKEN}"*) test_fail "${label}: token value reached the tool via _meta" ;;
	esac
	case "${text}" in
	*'"keep":"yes"'*) ;;
	*) test_fail "${label}: unrelated _meta keys must survive: ${text}" ;;
	esac
}

# Minimal mode, default keys, _meta passed via MCP_TOOL_META_JSON.
MCPBASH_REMOTE_TOKEN="${TOKEN}" MCPBASH_TOOL_ENV_MODE=minimal probe_run minimal "mcpbash/remoteToken"

# Allowlist mode naming the token explicitly, a custom key, and _meta passed via
# MCP_TOOL_META_FILE: the token still must not reach the tool.
MCPBASH_REMOTE_TOKEN="${TOKEN}" MCPBASH_REMOTE_TOKEN_KEY="custom/tok" \
	MCPBASH_TOOL_ENV_MODE=allowlist \
	MCPBASH_TOOL_ENV_ALLOWLIST="MCPBASH_REMOTE_TOKEN,MCPBASH_REMOTE_TOKEN_KEY,MCPBASH_REMOTE_TOKEN_FALLBACK_KEY" \
	MCPBASH_ENV_PAYLOAD_THRESHOLD=0 \
	probe_run allowlist "custom/tok"

printf 'Remote token guard integration passed.\n'
