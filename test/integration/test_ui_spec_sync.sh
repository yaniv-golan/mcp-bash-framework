#!/usr/bin/env bash
# shellcheck disable=SC2034  # Used by test runner for reporting.
TEST_DESC="MCP Apps spec-sync: mimeType-aware UI gating (gap #5)."
set -euo pipefail

# NOTE: the resources/list_changed behaviour (gap #3) is covered by unit tests
# (test/unit/ui_list_changed.bats, including the poll-path case). An end-to-end
# integration test for it requires injecting a filesystem change mid-session and
# waiting out the registry TTL, which is timing-dependent and flaky in CI, so it
# is intentionally left to the deterministic unit coverage.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../common/env.sh
# shellcheck disable=SC1091
. "${SCRIPT_DIR}/../common/env.sh"
# shellcheck source=../common/assert.sh
# shellcheck disable=SC1091
. "${SCRIPT_DIR}/../common/assert.sh"

test_create_tmpdir

echo "UI spec-sync test temp root: ${TEST_TMPDIR}"

# Run a server invocation. The state dir is left to default (a unique PID-based
# dir under the TMP root), which isolates runs and keeps the cleanup-safety
# check happy. Usage: run_server <workspace> <reqfile> <outfile>
run_server() {
	local ws="$1" reqfile="$2" outfile="$3"
	(
		cd "${ws}" || exit 1
		MCPBASH_PROJECT_ROOT="${ws}" MCPBASH_SERVER_NAME="mcp-server" \
			./bin/mcp-bash <"${reqfile}" >"${outfile}"
	)
}

# === mimeType gating (gap #5) ===
# A client that advertises the UI extension with a mimeTypes list that excludes
# text/html;profile=mcp-app must NOT receive _meta.ui (degrade to text-only),
# while a client advertising the profile does — on tools, resources/list, and
# resources/read alike.
echo "  [1/1] mimeType gating degrades to text-only"

GATE_ROOT="${TEST_TMPDIR}/gate"
test_stage_workspace "${GATE_ROOT}"

mkdir -p "${GATE_ROOT}/tools/weather/ui" "${GATE_ROOT}/ui/dash"
cat <<'BASH' >"${GATE_ROOT}/tools/weather/tool.sh"
#!/usr/bin/env bash
echo '{"content":[{"type":"text","text":"ok"}],"isError":false}'
BASH
chmod +x "${GATE_ROOT}/tools/weather/tool.sh"
printf '%s' '{"name":"weather","description":"Get weather","inputSchema":{"type":"object","properties":{}}}' \
	>"${GATE_ROOT}/tools/weather/tool.meta.json"
printf '%s' '<!DOCTYPE html><html></html>' >"${GATE_ROOT}/tools/weather/ui/index.html"
printf '%s' '<!DOCTYPE html><html></html>' >"${GATE_ROOT}/ui/dash/index.html"
printf '%s' '{"description":"Dash"}' >"${GATE_ROOT}/ui/dash/ui.meta.json"

cat <<'JSON' >"${GATE_ROOT}/req_ok.ndjson"
{"jsonrpc":"2.0","id":"init","method":"initialize","params":{"capabilities":{"extensions":{"io.modelcontextprotocol/ui":{"mimeTypes":["text/html;profile=mcp-app"]}}}}}
{"jsonrpc":"2.0","method":"notifications/initialized"}
{"jsonrpc":"2.0","id":"tl","method":"tools/list"}
{"jsonrpc":"2.0","id":"rl","method":"resources/list"}
{"jsonrpc":"2.0","id":"rd","method":"resources/read","params":{"uri":"ui://mcp-server/dash"}}
JSON
sed 's#"text/html;profile=mcp-app"#"text/plain"#' \
	"${GATE_ROOT}/req_ok.ndjson" >"${GATE_ROOT}/req_deny.ndjson"

run_server "${GATE_ROOT}" "${GATE_ROOT}/req_ok.ndjson" "${GATE_ROOT}/resp_ok.ndjson"
run_server "${GATE_ROOT}" "${GATE_ROOT}/req_deny.ndjson" "${GATE_ROOT}/resp_deny.ndjson"

check_ui() {
	jq -rs '
		(map(select(.id=="tl"))[0].result.tools // []
			| map(select(.name=="weather"))[0]._meta.ui != null) as $tool |
		(map(select(.id=="rl"))[0].result.resources // []
			| map(select(.uri=="ui://mcp-server/dash"))[0]._meta.ui != null) as $list |
		(map(select(.id=="rd"))[0].result.contents[0]._meta.ui != null) as $read |
		"tool=\($tool) list=\($list) read=\($read)"
	' <"$1"
}

OK_FLAGS="$(check_ui "${GATE_ROOT}/resp_ok.ndjson")"
DENY_FLAGS="$(check_ui "${GATE_ROOT}/resp_deny.ndjson")"

if [ "${OK_FLAGS}" != "tool=true list=true read=true" ]; then
	echo "    FAIL: profile-advertised client should get _meta.ui everywhere; got: ${OK_FLAGS}"
	cat "${GATE_ROOT}/resp_ok.ndjson"
	exit 1
fi
if [ "${DENY_FLAGS}" != "tool=false list=false read=false" ]; then
	echo "    FAIL: non-matching mimeTypes should strip _meta.ui everywhere; got: ${DENY_FLAGS}"
	cat "${GATE_ROOT}/resp_deny.ndjson"
	exit 1
fi
echo "    PASS: _meta.ui emitted only when the client accepts the mcp-app profile"

echo "All UI spec-sync tests passed."
