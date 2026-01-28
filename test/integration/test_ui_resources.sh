#!/usr/bin/env bash
# shellcheck disable=SC2034  # Used by test runner for reporting.
TEST_DESC="UI resource serving integration tests."
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../common/env.sh
# shellcheck disable=SC1091
. "${SCRIPT_DIR}/../common/env.sh"
# shellcheck source=../common/assert.sh
# shellcheck disable=SC1091
. "${SCRIPT_DIR}/../common/assert.sh"

test_create_tmpdir

echo "UI resource serving temp root: ${TEST_TMPDIR}"

# --- Test 1: Static HTML served via resources/read ---
echo "  [1/4] Static HTML resource serving"

STATIC_ROOT="${TEST_TMPDIR}/static"
test_stage_workspace "${STATIC_ROOT}"

# Create UI resource
mkdir -p "${STATIC_ROOT}/ui/dashboard"
cat <<'HTML' >"${STATIC_ROOT}/ui/dashboard/index.html"
<!DOCTYPE html>
<html><head><title>Dashboard</title></head>
<body><h1>Test Dashboard</h1></body>
</html>
HTML

cat <<'JSON' >"${STATIC_ROOT}/ui/dashboard/ui.meta.json"
{
  "description": "Test dashboard UI",
  "meta": {
    "csp": {"connectDomains": ["api.example.com"]},
    "prefersBorder": true
  }
}
JSON

cat <<'JSON' >"${STATIC_ROOT}/requests.ndjson"
{"jsonrpc":"2.0","id":"init","method":"initialize","params":{"capabilities":{"extensions":{"io.modelcontextprotocol/ui":{}}}}}
{"jsonrpc":"2.0","method":"notifications/initialized"}
{"jsonrpc":"2.0","id":"read","method":"resources/read","params":{"uri":"ui://mcp-server/dashboard"}}
JSON

(
	cd "${STATIC_ROOT}" || exit 1
	MCPBASH_PROJECT_ROOT="${STATIC_ROOT}" MCPBASH_SERVER_NAME="mcp-server" ./bin/mcp-bash <"requests.ndjson" >"responses.ndjson"
)

jq -s '
	def err(msg): error(msg);

	(map(select(.id == "read"))[0]) as $read |

	if $read.error then
		err("resources/read failed: " + ($read.error.message // "unknown"))
	else null end,

	if ($read.result.contents[0].mimeType) != "text/html;profile=mcp-app" then
		err("Expected mcp-app MIME type, got: " + ($read.result.contents[0].mimeType // "null"))
	else null end,

	if ($read.result.contents[0].text | contains("Test Dashboard") | not) then
		err("HTML content missing expected text")
	else null end
' <"${STATIC_ROOT}/responses.ndjson" >/dev/null

echo "    PASS: Static HTML served correctly"

# --- Test 2: UI resource includes metadata in response ---
echo "  [2/4] UI metadata in resource response"

META_ROOT="${TEST_TMPDIR}/meta"
test_stage_workspace "${META_ROOT}"

mkdir -p "${META_ROOT}/ui/form"
cat <<'HTML' >"${META_ROOT}/ui/form/index.html"
<!DOCTYPE html><html><body>Form</body></html>
HTML

cat <<'JSON' >"${META_ROOT}/ui/form/ui.meta.json"
{
  "description": "Form UI",
  "meta": {
    "csp": {
      "connectDomains": ["api.example.com"],
      "resourceDomains": ["cdn.example.com"]
    },
    "permissions": {"clipboardWrite": {}},
    "prefersBorder": false
  }
}
JSON

cat <<'JSON' >"${META_ROOT}/requests.ndjson"
{"jsonrpc":"2.0","id":"init","method":"initialize","params":{"capabilities":{"extensions":{"io.modelcontextprotocol/ui":{}}}}}
{"jsonrpc":"2.0","method":"notifications/initialized"}
{"jsonrpc":"2.0","id":"read","method":"resources/read","params":{"uri":"ui://mcp-server/form"}}
JSON

(
	cd "${META_ROOT}" || exit 1
	MCPBASH_PROJECT_ROOT="${META_ROOT}" MCPBASH_SERVER_NAME="mcp-server" ./bin/mcp-bash <"requests.ndjson" >"responses.ndjson"
)

jq -s '
	def err(msg): error(msg);

	(map(select(.id == "read"))[0].result.contents[0]) as $content |

	if $content == null then
		err("No content returned")
	else null end,

	# _meta.ui should exist
	if ($content._meta.ui // null) == null then
		err("_meta.ui missing from response")
	else null end,

	# Check prefersBorder
	if ($content._meta.ui.prefersBorder // true) != false then
		err("prefersBorder should be false")
	else null end
' <"${META_ROOT}/responses.ndjson" >/dev/null

echo "    PASS: UI metadata included in response"

# --- Test 3: Tool-associated UI resources discovered ---
echo "  [3/4] Tool-associated UI resource discovery"

TOOL_UI_ROOT="${TEST_TMPDIR}/tool-ui"
test_stage_workspace "${TOOL_UI_ROOT}"

# Create tool with UI
mkdir -p "${TOOL_UI_ROOT}/tools/weather/ui"
cat <<'BASH' >"${TOOL_UI_ROOT}/tools/weather/tool.sh"
#!/usr/bin/env bash
echo '{"temperature": 72}'
BASH
chmod +x "${TOOL_UI_ROOT}/tools/weather/tool.sh"

cat <<'JSON' >"${TOOL_UI_ROOT}/tools/weather/tool.meta.json"
{
  "name": "weather",
  "description": "Get weather",
  "inputSchema": {"type": "object"},
  "_meta": {
    "ui": {
      "resourceUri": "ui://mcp-server/weather"
    }
  }
}
JSON

cat <<'HTML' >"${TOOL_UI_ROOT}/tools/weather/ui/index.html"
<!DOCTYPE html><html><body>Weather UI</body></html>
HTML

cat <<'JSON' >"${TOOL_UI_ROOT}/tools/weather/ui/ui.meta.json"
{"description": "Weather visualization"}
JSON

cat <<'JSON' >"${TOOL_UI_ROOT}/requests.ndjson"
{"jsonrpc":"2.0","id":"init","method":"initialize","params":{"capabilities":{"extensions":{"io.modelcontextprotocol/ui":{}}}}}
{"jsonrpc":"2.0","method":"notifications/initialized"}
{"jsonrpc":"2.0","id":"read","method":"resources/read","params":{"uri":"ui://mcp-server/weather"}}
JSON

(
	cd "${TOOL_UI_ROOT}" || exit 1
	MCPBASH_PROJECT_ROOT="${TOOL_UI_ROOT}" MCPBASH_SERVER_NAME="mcp-server" ./bin/mcp-bash <"requests.ndjson" >"responses.ndjson"
)

jq -s '
	def err(msg): error(msg);

	(map(select(.id == "read"))[0]) as $read |

	if $read.error then
		err("Tool UI resource not found: " + ($read.error.message // "unknown"))
	else null end,

	if ($read.result.contents[0].text | contains("Weather UI") | not) then
		err("Tool UI content not served correctly")
	else null end
' <"${TOOL_UI_ROOT}/responses.ndjson" >/dev/null

echo "    PASS: Tool-associated UI resource discovered and served"

# --- Test 4: Unknown UI resource returns error ---
echo "  [4/4] Unknown UI resource returns error"

ERR_ROOT="${TEST_TMPDIR}/err"
test_stage_workspace "${ERR_ROOT}"

cat <<'JSON' >"${ERR_ROOT}/requests.ndjson"
{"jsonrpc":"2.0","id":"init","method":"initialize","params":{"capabilities":{"extensions":{"io.modelcontextprotocol/ui":{}}}}}
{"jsonrpc":"2.0","method":"notifications/initialized"}
{"jsonrpc":"2.0","id":"read","method":"resources/read","params":{"uri":"ui://mcp-server/nonexistent"}}
JSON

(
	cd "${ERR_ROOT}" || exit 1
	MCPBASH_PROJECT_ROOT="${ERR_ROOT}" MCPBASH_SERVER_NAME="mcp-server" ./bin/mcp-bash <"requests.ndjson" >"responses.ndjson"
)

jq -s '
	def err(msg): error(msg);

	(map(select(.id == "read"))[0]) as $read |

	if $read.error == null then
		err("Should return error for unknown UI resource")
	else null end
' <"${ERR_ROOT}/responses.ndjson" >/dev/null

echo "    PASS: Unknown UI resource returns appropriate error"

echo "All UI resource tests passed."
