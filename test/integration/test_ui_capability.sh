#!/usr/bin/env bash
# shellcheck disable=SC2034  # Used by test runner for reporting.
TEST_DESC="UI capability negotiation integration tests."
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../common/env.sh
# shellcheck disable=SC1091
. "${SCRIPT_DIR}/../common/env.sh"
# shellcheck source=../common/assert.sh
# shellcheck disable=SC1091
. "${SCRIPT_DIR}/../common/assert.sh"

test_create_tmpdir

echo "UI capability negotiation temp root: ${TEST_TMPDIR}"

# --- Test 1: Client with UI support gets UI capabilities in response ---
echo "  [1/4] Client with UI extension support"

UI_ROOT="${TEST_TMPDIR}/ui-capable"
test_stage_workspace "${UI_ROOT}"

cat <<'JSON' >"${UI_ROOT}/requests.ndjson"
{"jsonrpc":"2.0","id":"init","method":"initialize","params":{"capabilities":{"extensions":{"io.modelcontextprotocol/ui":{"mimeTypes":["text/html;profile=mcp-app"]}}}}}
{"jsonrpc":"2.0","method":"notifications/initialized"}
JSON

(
	cd "${UI_ROOT}" || exit 1
	MCPBASH_PROJECT_ROOT="${UI_ROOT}" ./bin/mcp-bash <"requests.ndjson" >"responses.ndjson"
)

jq -s '
	def err(msg): error(msg);

	(map(select(.id == "init"))[0].result) as $init |

	# Server should advertise UI extension when client supports it
	if ($init.capabilities.extensions["io.modelcontextprotocol/ui"] | type) != "object" then
		err("Server should advertise UI extension when client supports it")
	else null end,

	if ($init.capabilities.extensions["io.modelcontextprotocol/ui"].mimeTypes[0]) != "text/html;profile=mcp-app" then
		err("Server should advertise correct MIME type")
	else null end
' <"${UI_ROOT}/responses.ndjson" >/dev/null

echo "    PASS: Server advertises UI capability when client supports it"

# --- Test 2: Client without UI support gets no UI capabilities ---
echo "  [2/4] Client without UI extension support"

NO_UI_ROOT="${TEST_TMPDIR}/no-ui"
test_stage_workspace "${NO_UI_ROOT}"

cat <<'JSON' >"${NO_UI_ROOT}/requests.ndjson"
{"jsonrpc":"2.0","id":"init","method":"initialize","params":{"capabilities":{"tools":{}}}}
{"jsonrpc":"2.0","method":"notifications/initialized"}
JSON

(
	cd "${NO_UI_ROOT}" || exit 1
	MCPBASH_PROJECT_ROOT="${NO_UI_ROOT}" ./bin/mcp-bash <"requests.ndjson" >"responses.ndjson"
)

jq -s '
	def err(msg): error(msg);

	(map(select(.id == "init"))[0].result) as $init |

	# Extensions should be empty or missing when client does not support UI
	if ($init.capabilities.extensions // {} | keys | length) > 0 then
		err("Server should not advertise extensions when client has none")
	else null end
' <"${NO_UI_ROOT}/responses.ndjson" >/dev/null

echo "    PASS: Server does not advertise UI when client lacks support"

# --- Test 3: Client capabilities state persists for tools ---
echo "  [3/4] UI state file created for subprocesses"

STATE_ROOT="${TEST_TMPDIR}/state"
test_stage_workspace "${STATE_ROOT}"

cat <<'JSON' >"${STATE_ROOT}/requests.ndjson"
{"jsonrpc":"2.0","id":"init","method":"initialize","params":{"capabilities":{"extensions":{"io.modelcontextprotocol/ui":{}}}}}
{"jsonrpc":"2.0","method":"notifications/initialized"}
JSON

(
	cd "${STATE_ROOT}" || exit 1
	MCPBASH_STATE_DIR="${STATE_ROOT}/state" MCPBASH_PROJECT_ROOT="${STATE_ROOT}" ./bin/mcp-bash <"requests.ndjson" >"responses.ndjson"
)

# Check state file was created
if [ ! -f "${STATE_ROOT}/state/extensions.ui.support" ]; then
	echo "    FAIL: State file not created"
	exit 1
fi

content="$(cat "${STATE_ROOT}/state/extensions.ui.support")"
if [ "${content}" != "1" ]; then
	echo "    FAIL: State file has wrong content: ${content}"
	exit 1
fi

echo "    PASS: UI support state file created correctly"

# --- Test 4: Empty UI extension object still indicates support ---
echo "  [4/4] Empty UI extension object indicates support"

EMPTY_ROOT="${TEST_TMPDIR}/empty-ext"
test_stage_workspace "${EMPTY_ROOT}"

cat <<'JSON' >"${EMPTY_ROOT}/requests.ndjson"
{"jsonrpc":"2.0","id":"init","method":"initialize","params":{"capabilities":{"extensions":{"io.modelcontextprotocol/ui":{}}}}}
{"jsonrpc":"2.0","method":"notifications/initialized"}
JSON

(
	cd "${EMPTY_ROOT}" || exit 1
	MCPBASH_PROJECT_ROOT="${EMPTY_ROOT}" ./bin/mcp-bash <"requests.ndjson" >"responses.ndjson"
)

jq -s '
	def err(msg): error(msg);

	(map(select(.id == "init"))[0].result) as $init |

	# Empty object still means support (per MCP Apps spec)
	if ($init.capabilities.extensions["io.modelcontextprotocol/ui"] | type) != "object" then
		err("Server should recognize empty UI extension object as support")
	else null end
' <"${EMPTY_ROOT}/responses.ndjson" >/dev/null

echo "    PASS: Empty extension object recognized as support"

echo "All UI capability tests passed."
