#!/usr/bin/env bash
# shellcheck disable=SC2034  # Used by test runner for reporting.
TEST_DESC="Per-resource completion scripts serve ref/resource for resource templates."
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

WS="${TEST_TMPDIR}/ws"
test_stage_workspace "${WS}"
mkdir -p "${WS}/resources/orders" "${WS}/server.d"
printf '%s\n' '{"name": "template-completion"}' >"${WS}/server.d/server.meta.json"

# Flat layout: resources/items.meta.json + resources/items.completion.sh.
# The script echoes what it was given so the test can check its env.
printf '%s\n' '{"name": "items", "description": "Items", "uriTemplate": "file:///items/{id}"}' >"${WS}/resources/items.meta.json"
cat >"${WS}/resources/items.completion.sh" <<'SH'
#!/usr/bin/env bash
arg="$(printf '%s' "${MCP_COMPLETION_ARGS_JSON}" | jq -r '.argument.name // ""')"
jq -cn --arg uri "${MCP_RESOURCE_URI:-}" --arg n "${MCP_COMPLETION_NAME:-}" --arg arg "${arg}" \
	'[("item-" + $arg), ("name=" + $n), ("uri=" + $uri)]'
SH

# Directory layout: resources/orders/orders.meta.json + resources/orders/orders.completion.sh.
printf '%s\n' '{"name": "orders", "description": "Orders", "uriTemplate": "orders://{+key}"}' >"${WS}/resources/orders/orders.meta.json"
printf '#!/usr/bin/env bash\nprintf %%s %s\n' "'[\"order-1\"]'" >"${WS}/resources/orders/orders.completion.sh"

# A template with no completion script falls back to the builtin generator.
printf '%s\n' '{"name": "plain", "description": "Plain", "uriTemplate": "file:///plain/{p}"}' >"${WS}/resources/plain.meta.json"

chmod +x "${WS}/resources/items.completion.sh" "${WS}/resources/orders/orders.completion.sh"
chmod -R go-w "${WS}"

cat >"${WS}/requests.ndjson" <<'JSON'
{"jsonrpc":"2.0","id":"init","method":"initialize","params":{}}
{"jsonrpc":"2.0","method":"notifications/initialized"}
{"jsonrpc":"2.0","id":"tpl","method":"completion/complete","params":{"ref":{"type":"ref/resource","uri":"file:///items/{id}"},"argument":{"name":"id","value":""}}}
{"jsonrpc":"2.0","id":"concrete","method":"completion/complete","params":{"ref":{"type":"ref/resource","uri":"file:///items/42"},"argument":{"name":"id","value":"4"}}}
{"jsonrpc":"2.0","id":"dir","method":"completion/complete","params":{"ref":{"type":"ref/resource","uri":"orders://{+key}"},"argument":{"name":"key","value":""}}}
{"jsonrpc":"2.0","id":"plain","method":"completion/complete","params":{"ref":{"type":"ref/resource","uri":"file:///plain/{p}"},"argument":{"name":"p","value":""}}}
{"jsonrpc":"2.0","id":"templates","method":"resources/templates/list","params":{}}
JSON

test_run_mcp "${WS}" "${WS}/requests.ndjson" "${WS}/responses.ndjson" || true

values() { jq -c --arg id "$1" 'select(.id==$id) | (.result.completion.values // .error)' "${WS}/responses.ndjson"; }

assert_eq '["item-id","name=items","uri=file:///items/{id}"]' "$(values tpl)" "ref/resource with the uriTemplate runs the template's completion script"
assert_eq '["item-id","name=items","uri=file:///items/{id}"]' "$(values concrete)" "ref/resource with a URI matching the template runs the same script"
assert_eq '["order-1"]' "$(values dir)" "directory layout: resources/<name>/<name>.completion.sh"
plain="$(values plain)"
case "${plain}" in
'['*) ;;
*) test_fail "template without a script should fall back to builtin values, got: ${plain}" ;;
esac

listed="$(jq -c 'select(.id=="templates") | [.result.resourceTemplates[].name] | sort' "${WS}/responses.ndjson")"
assert_eq '["items","orders","plain"]' "${listed}" "completion scripts are not listed as templates"

printf 'Resource template completion test passed.\n'
