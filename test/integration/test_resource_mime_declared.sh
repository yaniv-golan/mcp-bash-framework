#!/usr/bin/env bash
# shellcheck disable=SC2034  # Used by test runner for reporting.
TEST_DESC="Declared mimeType is the reported label; detection labels undeclared content and decides encoding."
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../common/env.sh
# shellcheck disable=SC1091
. "${SCRIPT_DIR}/../common/env.sh"
# shellcheck source=../common/assert.sh
# shellcheck disable=SC1091
. "${SCRIPT_DIR}/../common/assert.sh"

if ! command -v file >/dev/null 2>&1; then
	printf 'SKIP: file(1) unavailable; mime detection cannot run\n'
	exit 0
fi

test_create_tmpdir

run_server() {
	local workdir="$1"
	(
		cd "${workdir}" || exit 1
		MCPBASH_PROJECT_ROOT="${workdir}" ./bin/mcp-bash <"requests.ndjson" >"responses.ndjson"
	)
}

write_samples() {
	local dir="$1"
	printf '# Notes\n\nSome *markdown* text.\n' >"${dir}/notes.md"
	printf '{"a":1,"b":[1,2,3]}\n' >"${dir}/data.json"
	# NUL-free PDF: only detection can tell it is binary.
	printf '%%PDF-1.4\n1 0 obj\n<< /Type /Catalog >>\nendobj\ntrailer\n<< /Root 1 0 R >>\n%%%%EOF\n' >"${dir}/doc.pdf"
}

# Fails unless the list never carries mimeTypeDeclared and each read reports
# the expected label and encoding. $1: responses file; $2: JSON object of
# name -> {mime, enc} where enc is "text" or "blob".
assert_reads() {
	local responses="$1"
	local expected="$2"
	jq -s --argjson expected "${expected}" '
		def err(msg): error(msg);
		. as $all |
		(map(select(.id == "list"))[0].result.resources) as $items |
		if $items == null then err("resources/list returned no result") else null end,
		if ([$items[] | select(has("mimeTypeDeclared"))] | length) > 0
			then err("resources/list leaked mimeTypeDeclared") else null end,
		($expected | to_entries[] | .key as $name | .value as $want |
			($all | map(select(.id == ("read-" + $name)))[0]) as $resp |
			if $resp.result == null then err("read " + $name + " failed: " + ($resp.error | tostring)) else null end,
			($resp.result.contents[0]) as $c |
			if $c.mimeType != $want.mime
				then err("read " + $name + ": mimeType " + ($c.mimeType | tostring) + " != " + $want.mime) else null end,
			if ($c | has($want.enc) | not)
				then err("read " + $name + ": expected " + $want.enc + " content") else null end
		)
	' <"${responses}" >/dev/null
}

# --- 1) Auto-scan .meta.json ---
META_ROOT="${TEST_TMPDIR}/meta"
test_stage_workspace "${META_ROOT}"
rm -f "${META_ROOT}/server.d/register.sh"
mkdir -p "${META_ROOT}/resources"
write_samples "${META_ROOT}/resources"
printf 'a = 1\n' >"${META_ROOT}/resources/numeric.toml"

cat <<EOF_META >"${META_ROOT}/resources/notes.meta.json"
{"name": "notes", "uri": "file://${META_ROOT}/resources/notes.md", "mimeType": "text/markdown"}
EOF_META
cat <<EOF_META >"${META_ROOT}/resources/data.meta.json"
{"name": "data", "description": "No mimeType: detection labels it", "uri": "file://${META_ROOT}/resources/data.json"}
EOF_META
cat <<EOF_META >"${META_ROOT}/resources/doc.meta.json"
{"name": "doc", "uri": "file://${META_ROOT}/resources/doc.pdf", "mimeType": "text/plain"}
EOF_META
cat <<EOF_META >"${META_ROOT}/resources/numeric.meta.json"
{"name": "numeric", "uri": "file://${META_ROOT}/resources/numeric.toml", "mimeType": 42}
EOF_META

cat <<'JSON' >"${META_ROOT}/requests.ndjson"
{"jsonrpc":"2.0","id":"init","method":"initialize","params":{}}
{"jsonrpc":"2.0","method":"notifications/initialized"}
{"jsonrpc":"2.0","id":"list","method":"resources/list","params":{}}
{"jsonrpc":"2.0","id":"read-notes","method":"resources/read","params":{"name":"notes"}}
{"jsonrpc":"2.0","id":"read-data","method":"resources/read","params":{"name":"data"}}
{"jsonrpc":"2.0","id":"read-doc","method":"resources/read","params":{"name":"doc"}}
{"jsonrpc":"2.0","id":"read-numeric","method":"resources/read","params":{"name":"numeric"}}
JSON
run_server "${META_ROOT}"
assert_reads "${META_ROOT}/responses.ndjson" '{
	"notes": {"mime": "text/markdown", "enc": "text"},
	"data": {"mime": "application/json", "enc": "text"},
	"doc": {"mime": "text/plain", "enc": "blob"},
	"numeric": {"mime": "text/plain", "enc": "text"}
}'
# The flag lives in the registry cache, not on the wire.
if ! jq -e '[.items[] | select(.name == "notes")][0].mimeTypeDeclared == true' \
	"${META_ROOT}/.registry/resources.json" >/dev/null 2>&1; then
	test_fail "meta.json: registry should record mimeTypeDeclared for a declared resource"
fi
if jq -e '[.items[] | select(.name == "data" or .name == "numeric") | has("mimeTypeDeclared")] | any' \
	"${META_ROOT}/.registry/resources.json" >/dev/null 2>&1; then
	test_fail "meta.json: registry should not flag undeclared resources"
fi
printf ' -> meta.json: declared label kept, undeclared detected, list clean\n'

# --- 2) register.json (a user-supplied flag is ignored) ---
JSON_ROOT="${TEST_TMPDIR}/json"
test_stage_workspace "${JSON_ROOT}"
rm -f "${JSON_ROOT}/server.d/register.sh"
mkdir -p "${JSON_ROOT}/resources"
write_samples "${JSON_ROOT}/resources"
cat <<EOF_JSON >"${JSON_ROOT}/server.d/register.json"
{
  "version": 1,
  "resources": [
    {"name": "notes", "uri": "file://${JSON_ROOT}/resources/notes.md", "provider": "file", "mimeType": "text/markdown"},
    {"name": "data", "uri": "file://${JSON_ROOT}/resources/data.json", "provider": "file", "mimeTypeDeclared": true}
  ]
}
EOF_JSON
grep -Ev 'read-(doc|numeric)' "${META_ROOT}/requests.ndjson" >"${JSON_ROOT}/requests.ndjson"
run_server "${JSON_ROOT}"
assert_reads "${JSON_ROOT}/responses.ndjson" '{
	"notes": {"mime": "text/markdown", "enc": "text"},
	"data": {"mime": "application/json", "enc": "text"}
}'
printf ' -> register.json: declared label kept, injected flag ignored\n'

# --- 3) register.sh ---
SH_ROOT="${TEST_TMPDIR}/sh"
test_stage_workspace "${SH_ROOT}"
mkdir -p "${SH_ROOT}/resources"
write_samples "${SH_ROOT}/resources"
cat <<EOF_SCRIPT >"${SH_ROOT}/server.d/register.sh"
#!/usr/bin/env bash
set -euo pipefail
mcp_register_resource '{"name": "notes", "uri": "file://${SH_ROOT}/resources/notes.md", "mimeType": "text/markdown"}'
mcp_register_resource '{"name": "data", "uri": "file://${SH_ROOT}/resources/data.json", "mimeTypeDeclared": true}'
return 0
EOF_SCRIPT
chmod +x "${SH_ROOT}/server.d/register.sh"
cp "${JSON_ROOT}/requests.ndjson" "${SH_ROOT}/requests.ndjson"
run_server "${SH_ROOT}"
assert_reads "${SH_ROOT}/responses.ndjson" '{
	"notes": {"mime": "text/markdown", "enc": "text"},
	"data": {"mime": "application/json", "enc": "text"}
}'
printf ' -> register.sh: declared label kept, undeclared detected\n'

# --- 4) Tools: embedded resources via the SDK and the TSV form ---
TOOL_ROOT="${TEST_TMPDIR}/tool"
test_stage_workspace "${TOOL_ROOT}"
rm -f "${TOOL_ROOT}/server.d/register.sh"
mkdir -p "${TOOL_ROOT}/tools/embed" "${TOOL_ROOT}/tools/embedtsv" "${TOOL_ROOT}/resources"
write_samples "${TOOL_ROOT}/resources"

cat <<'META' >"${TOOL_ROOT}/tools/embed/tool.meta.json"
{"name": "embed", "description": "SDK embeds", "inputSchema": {"type": "object", "properties": {}}}
META
cat <<'SH' >"${TOOL_ROOT}/tools/embed/tool.sh"
#!/usr/bin/env bash
set -euo pipefail
# shellcheck disable=SC1091
source "${MCP_SDK:?}/tool-sdk.sh"
dir="${MCPBASH_PROJECT_ROOT}/resources"
mcp_result_text_with_resource "$(mcp_json_obj message ok)" \
	--path "${dir}/data.json" \
	--path "${dir}/notes.md" --mime text/markdown \
	--path "${dir}/doc.pdf" --mime text/plain
SH
chmod +x "${TOOL_ROOT}/tools/embed/tool.sh"

cat <<'META' >"${TOOL_ROOT}/tools/embedtsv/tool.meta.json"
{"name": "embedtsv", "description": "TSV embeds", "inputSchema": {"type": "object", "properties": {}}}
META
cat <<'SH' >"${TOOL_ROOT}/tools/embedtsv/tool.sh"
#!/usr/bin/env bash
set -euo pipefail
dir="${MCPBASH_PROJECT_ROOT}/resources"
# Empty mime column with a uri after it: the uri must not become the mime.
printf '%s\t\t%s\n' "${dir}/data.json" "custom://data" >>"${MCP_TOOL_RESOURCES_FILE}"
printf 'ok'
SH
chmod +x "${TOOL_ROOT}/tools/embedtsv/tool.sh"

cat <<'JSON' >"${TOOL_ROOT}/requests.ndjson"
{"jsonrpc":"2.0","id":"init","method":"initialize","params":{}}
{"jsonrpc":"2.0","method":"notifications/initialized"}
{"jsonrpc":"2.0","id":"embed","method":"tools/call","params":{"name":"embed","arguments":{}}}
{"jsonrpc":"2.0","id":"embedtsv","method":"tools/call","params":{"name":"embedtsv","arguments":{}}}
JSON
run_server "${TOOL_ROOT}"

jq -s '
	def err(msg): error(msg);
	def res(id): [(map(select(.id == id))[0].result.content // [])[] | select(.type == "resource") | .resource];
	res("embed") as $r |
	if ($r | length) != 3 then err("embed: expected 3 embedded resources, got " + ($r | length | tostring)) else null end,
	if $r[0].mimeType != "application/json" then err("embed: no --mime should be detected, got " + ($r[0].mimeType | tostring)) else null end,
	if ($r[0] | has("text") | not) then err("embed: json should be text") else null end,
	if $r[1].mimeType != "text/markdown" then err("embed: --mime text/markdown should be kept, got " + ($r[1].mimeType | tostring)) else null end,
	if $r[2].mimeType != "text/plain" then err("embed: --mime text/plain on pdf should be kept as label") else null end,
	if ($r[2] | has("blob") | not) then err("embed: pdf declared text/plain must still be a blob") else null end,
	res("embedtsv") as $t |
	if ($t | length) != 1 then err("embedtsv: expected 1 embedded resource") else null end,
	if $t[0].mimeType != "application/json" then err("embedtsv: empty mime column should be detected, got " + ($t[0].mimeType | tostring)) else null end,
	if $t[0].uri != "custom://data" then err("embedtsv: uri column lost, got " + ($t[0].uri | tostring)) else null end
' <"${TOOL_ROOT}/responses.ndjson" >/dev/null
printf ' -> tools: --mime is the label, omitted mime is detected\n'
