#!/usr/bin/env bash
TEST_DESC="Capabilities negotiation including listChanged/template flags."
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../common/env.sh
# shellcheck disable=SC1091
. "${SCRIPT_DIR}/../common/env.sh"
# shellcheck source=../common/assert.sh
# shellcheck disable=SC1091
. "${SCRIPT_DIR}/../common/assert.sh"

TMP=$(mktemp -d)
trap 'rm -rf "${TMP}"' EXIT

cat <<'JSON' >"${TMP}/requests.ndjson"
{"jsonrpc":"2.0","id":"1","method":"initialize","params":{}}
{"jsonrpc":"2.0","method":"notifications/initialized"}
{"jsonrpc":"2.0","id":"2","method":"tools/list"}
{"jsonrpc":"2.0","id":"3","method":"resources/templates/list"}
JSON

"${MCPBASH_HOME}/examples/run" 00-hello-tool <"${TMP}/requests.ndjson" >"${TMP}/responses.ndjson" || true

if ! grep -q '"id":"2"' "${TMP}/responses.ndjson"; then
	test_fail "tools/list response missing"
fi

init_caps="$(jq 'select(.id=="1") | .result.capabilities' "${TMP}/responses.ndjson")"
tools_list_changed="$(printf '%s' "${init_caps}" | jq -r '.tools.listChanged // empty')"
resources_subscribe="$(printf '%s' "${init_caps}" | jq -r '.resources.subscribe // empty')"
resources_list_changed="$(printf '%s' "${init_caps}" | jq -r '.resources.listChanged // empty')"
resources_templates="$(printf '%s' "${init_caps}" | jq -r '.resources.templates // empty')"
prompts_list_changed="$(printf '%s' "${init_caps}" | jq -r '.prompts.listChanged // empty')"

test_assert_eq "${tools_list_changed}" "true"
test_assert_eq "${resources_subscribe}" "true"
test_assert_eq "${resources_list_changed}" "true"
test_assert_eq "${resources_templates}" "true"
test_assert_eq "${prompts_list_changed}" "true"

templates_result_count="$(jq -r 'select(.id=="3") | .result.resourceTemplates | length' "${TMP}/responses.ndjson")"
test_assert_eq "${templates_result_count}" "0"

# Backport protocol should omit listChanged/templates
cat <<'JSON' >"${TMP}/requests_backport.ndjson"
{"jsonrpc":"2.0","id":"init-back","method":"initialize","params":{"protocolVersion":"2024-11-05"}}
{"jsonrpc":"2.0","method":"notifications/initialized"}
JSON

"${MCPBASH_HOME}/examples/run" 00-hello-tool <"${TMP}/requests_backport.ndjson" >"${TMP}/responses_backport.ndjson" || true

back_caps="$(jq 'select(.id=="init-back") | .result.capabilities' "${TMP}/responses_backport.ndjson")"
back_tools_has_list_changed="$(printf '%s' "${back_caps}" | jq 'has("tools") and (.tools | has("listChanged"))')"
back_res_has_list_changed="$(printf '%s' "${back_caps}" | jq '.resources | has("listChanged")')"
back_res_has_templates="$(printf '%s' "${back_caps}" | jq '.resources | has("templates")')"

test_assert_eq "${back_tools_has_list_changed}" "false"
test_assert_eq "${back_res_has_list_changed}" "false"
test_assert_eq "${back_res_has_templates}" "false"
