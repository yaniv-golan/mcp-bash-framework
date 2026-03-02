#!/usr/bin/env bash
# shellcheck disable=SC2034  # Used by test runner for reporting.
TEST_DESC="Resource annotations from meta.json, inline headers, and manual registration."
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../common/env.sh
# shellcheck disable=SC1091
. "${SCRIPT_DIR}/../common/env.sh"
# shellcheck source=../common/assert.sh
# shellcheck disable=SC1091
. "${SCRIPT_DIR}/../common/assert.sh"

test_create_tmpdir

# --- 1) Annotations via *.meta.json ---
META_ROOT="${TEST_TMPDIR}/meta"
test_stage_workspace "${META_ROOT}"
rm -f "${META_ROOT}/server.d/register.sh"
mkdir -p "${META_ROOT}/resources"

printf 'hello\n' >"${META_ROOT}/resources/annotated.txt"

cat <<EOF_META >"${META_ROOT}/resources/annotated.meta.json"
{
  "name": "res.annotated",
  "description": "Annotated via meta",
  "uri": "file://${META_ROOT}/resources/annotated.txt",
  "mimeType": "text/plain",
  "annotations": {
    "audience": ["internal"],
    "priority": 0.8
  }
}
EOF_META

cat <<'JSON' >"${META_ROOT}/requests.ndjson"
{"jsonrpc":"2.0","id":"init","method":"initialize","params":{}}
{"jsonrpc":"2.0","method":"notifications/initialized"}
{"jsonrpc":"2.0","id":"list","method":"resources/list","params":{}}
JSON

(
	cd "${META_ROOT}" || exit 1
	MCPBASH_PROJECT_ROOT="${META_ROOT}" ./bin/mcp-bash <"requests.ndjson" >"responses.ndjson"
)

jq -s '
	def err(msg): error(msg);

	(map(select(.id == "list"))[0].result) as $list |
	($list.resources[] | select(.name == "res.annotated")) as $r |

	if ($r | has("annotations") | not) then err("meta.json: annotations missing from resources/list") else null end,
	if $r.annotations.priority != 0.8 then err("meta.json: annotations.priority mismatch") else null end,
	if ($r.annotations.audience | length) != 1 then err("meta.json: annotations.audience length mismatch") else null end,
	if $r.annotations.audience[0] != "internal" then err("meta.json: annotations.audience[0] mismatch") else null end
' <"${META_ROOT}/responses.ndjson" >/dev/null

# --- 2) Annotations via inline # mcp: header ---
INLINE_ROOT="${TEST_TMPDIR}/inline"
test_stage_workspace "${INLINE_ROOT}"
rm -f "${INLINE_ROOT}/server.d/register.sh"
mkdir -p "${INLINE_ROOT}/resources"

cat <<'EOF_RES' >"${INLINE_ROOT}/resources/header_annotated.sh"
#!/usr/bin/env bash
# mcp:{"name":"res.header","uri":"custom://header","description":"From header","annotations":{"audience":["user"],"priority":0.5}}
echo "header resource"
EOF_RES

cat <<'JSON' >"${INLINE_ROOT}/requests.ndjson"
{"jsonrpc":"2.0","id":"init","method":"initialize","params":{}}
{"jsonrpc":"2.0","method":"notifications/initialized"}
{"jsonrpc":"2.0","id":"list","method":"resources/list","params":{}}
JSON

(
	cd "${INLINE_ROOT}" || exit 1
	MCPBASH_PROJECT_ROOT="${INLINE_ROOT}" ./bin/mcp-bash <"requests.ndjson" >"responses.ndjson"
)

jq -s '
	def err(msg): error(msg);

	(map(select(.id == "list"))[0].result) as $list |
	($list.resources[] | select(.name == "res.header")) as $r |

	if ($r | has("annotations") | not) then err("header: annotations missing from resources/list") else null end,
	if $r.annotations.priority != 0.5 then err("header: annotations.priority mismatch") else null end,
	if $r.annotations.audience[0] != "user" then err("header: annotations.audience[0] mismatch") else null end
' <"${INLINE_ROOT}/responses.ndjson" >/dev/null

# --- 3) Annotations via manual registration (register.sh) ---
MANUAL_ROOT="${TEST_TMPDIR}/manual"
test_stage_workspace "${MANUAL_ROOT}"
mkdir -p "${MANUAL_ROOT}/resources"

printf 'manual content\n' >"${MANUAL_ROOT}/resources/manual_ann.txt"

cat <<EOF_SCRIPT >"${MANUAL_ROOT}/server.d/register.sh"
#!/usr/bin/env bash
set -euo pipefail

mcp_register_resource '{
  "name": "manual.annotated",
  "description": "Manual with annotations",
  "uri": "file://${MANUAL_ROOT}/resources/manual_ann.txt",
  "mimeType": "text/plain",
  "annotations": {
    "audience": ["assistant"],
    "priority": 0.3
  }
}'

return 0
EOF_SCRIPT
chmod +x "${MANUAL_ROOT}/server.d/register.sh"

cat <<'JSON' >"${MANUAL_ROOT}/requests.ndjson"
{"jsonrpc":"2.0","id":"init","method":"initialize","params":{}}
{"jsonrpc":"2.0","method":"notifications/initialized"}
{"jsonrpc":"2.0","id":"list","method":"resources/list","params":{}}
JSON

(
	cd "${MANUAL_ROOT}" || exit 1
	MCPBASH_PROJECT_ROOT="${MANUAL_ROOT}" ./bin/mcp-bash <"requests.ndjson" >"responses.ndjson"
)

jq -s '
	def err(msg): error(msg);

	(map(select(.id == "list"))[0].result) as $list |
	($list.resources[] | select(.name == "manual.annotated")) as $r |

	if ($r | has("annotations") | not) then err("manual: annotations missing from resources/list") else null end,
	if $r.annotations.priority != 0.3 then err("manual: annotations.priority mismatch") else null end,
	if $r.annotations.audience[0] != "assistant" then err("manual: annotations.audience[0] mismatch") else null end
' <"${MANUAL_ROOT}/responses.ndjson" >/dev/null

# --- 4) No annotations: field must be absent (not null) ---
NOANNO_ROOT="${TEST_TMPDIR}/noanno"
test_stage_workspace "${NOANNO_ROOT}"
rm -f "${NOANNO_ROOT}/server.d/register.sh"
mkdir -p "${NOANNO_ROOT}/resources"

printf 'plain\n' >"${NOANNO_ROOT}/resources/plain.txt"
cat <<EOF_META >"${NOANNO_ROOT}/resources/plain.meta.json"
{"name": "res.plain", "description": "No annotations", "uri": "file://${NOANNO_ROOT}/resources/plain.txt", "mimeType": "text/plain"}
EOF_META

cat <<'JSON' >"${NOANNO_ROOT}/requests.ndjson"
{"jsonrpc":"2.0","id":"init","method":"initialize","params":{}}
{"jsonrpc":"2.0","method":"notifications/initialized"}
{"jsonrpc":"2.0","id":"list","method":"resources/list","params":{}}
JSON

(
	cd "${NOANNO_ROOT}" || exit 1
	MCPBASH_PROJECT_ROOT="${NOANNO_ROOT}" ./bin/mcp-bash <"requests.ndjson" >"responses.ndjson"
)

jq -s '
	def err(msg): error(msg);

	(map(select(.id == "list"))[0].result) as $list |
	($list.resources[] | select(.name == "res.plain")) as $r |

	if ($r | has("annotations")) then err("no-annotations: field should be absent when unset") else null end
' <"${NOANNO_ROOT}/responses.ndjson" >/dev/null
