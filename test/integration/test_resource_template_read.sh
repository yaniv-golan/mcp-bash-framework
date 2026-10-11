#!/usr/bin/env bash
# Integration: resources/read matches resource templates and tells the provider
# which template matched; nothing else ever sees MCP_RESOURCE_TEMPLATE_*.
# shellcheck disable=SC2034  # Used by test runner for reporting.
TEST_DESC="Template-aware resources/read: provider env and no leaks."

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
WORKSPACE="${TEST_TMPDIR}/template-read"
test_stage_workspace "${WORKSPACE}"
mkdir -p "${WORKSPACE}/providers" "${WORKSPACE}/resources" "${WORKSPACE}/prompts/pick" \
	"${WORKSPACE}/tools/envprobe" "${WORKSPACE}/server.d"
printf '%s\n' '{"name": "template-read"}' >"${WORKSPACE}/server.d/server.meta.json"

# Reports the template env as the provider sees it ("<unset>" when absent).
cat <<'SH' >"${WORKSPACE}/providers/kv.sh"
#!/usr/bin/env bash
set -euo pipefail
printf 'name=[%s] vars=[%s]' "${MCP_RESOURCE_TEMPLATE_NAME-<unset>}" "${MCP_RESOURCE_TEMPLATE_VARS-<unset>}"
SH
chmod +x "${WORKSPACE}/providers/kv.sh"

# Supported template on the custom scheme.
cat <<'META' >"${WORKSPACE}/resources/kv-item.meta.json"
{"name": "kv-item", "uriTemplate": "kv://item/{id}/{+rest}"}
META
# Unsupported template (explode modifier): it still declares the kv scheme,
# so reads keep 1.5.0 behaviour: the provider runs without template env.
cat <<'META' >"${WORKSPACE}/resources/kv-legacy.meta.json"
{"name": "kv-legacy", "uriTemplate": "kv://legacy/{ids*}"}
META
# Static resource on the same provider: not a template read.
echo placeholder >"${WORKSPACE}/resources/kv-static.txt"
cat <<'META' >"${WORKSPACE}/resources/kv-static.meta.json"
{"name": "kv-static", "uri": "kv://static", "provider": "kv"}
META

# Completion script next to a prompt: also reports the template env.
cat <<'JSON' >"${WORKSPACE}/prompts/pick/pick.meta.json"
{"name": "pick", "description": "Pick", "path": "pick/pick.txt",
 "arguments": {"type": "object", "properties": {"q": {"type": "string"}}}}
JSON
printf 'Pick {{q}}\n' >"${WORKSPACE}/prompts/pick/pick.txt"
cat <<'SH' >"${WORKSPACE}/prompts/pick/pick.completion.sh"
#!/usr/bin/env bash
set -euo pipefail
report="$(printf 'name=[%s] vars=[%s]' "${MCP_RESOURCE_TEMPLATE_NAME-<unset>}" "${MCP_RESOURCE_TEMPLATE_VARS-<unset>}")"
"${MCPBASH_JSON_TOOL_BIN}" -cn --arg v "${report}" '[$v]'
SH
chmod +x "${WORKSPACE}/prompts/pick/pick.completion.sh"

# Tool: same report.
cat <<'META' >"${WORKSPACE}/tools/envprobe/tool.meta.json"
{"name":"envprobe","description":"Report template env","arguments":{"type":"object","properties":{}}}
META
cat <<'SH' >"${WORKSPACE}/tools/envprobe/tool.sh"
#!/usr/bin/env bash
set -euo pipefail
printf 'name=[%s] vars=[%s]' "${MCP_RESOURCE_TEMPLATE_NAME-<unset>}" "${MCP_RESOURCE_TEMPLATE_VARS-<unset>}"
SH
chmod +x "${WORKSPACE}/tools/envprobe/tool.sh"
chmod -R go-w "${WORKSPACE}"

cat <<'JSON' >"${WORKSPACE}/requests.ndjson"
{"jsonrpc":"2.0","id":"init","method":"initialize","params":{}}
{"jsonrpc":"2.0","method":"notifications/initialized"}
{"jsonrpc":"2.0","id":"tpl","method":"resources/read","params":{"uri":"kv://item/42/a/b%2Fc"}}
{"jsonrpc":"2.0","id":"static","method":"resources/read","params":{"uri":"kv://static"}}
{"jsonrpc":"2.0","id":"legacy","method":"resources/read","params":{"uri":"kv://legacy/5"}}
{"jsonrpc":"2.0","id":"tpl-again","method":"resources/read","params":{"uri":"kv://item/7/x"}}
{"jsonrpc":"2.0","id":"complete","method":"completion/complete","params":{"ref":{"type":"ref/prompt","name":"pick"},"argument":{"name":"q","value":""}}}
{"jsonrpc":"2.0","id":"tool","method":"tools/call","params":{"name":"envprobe","arguments":{}}}
{"jsonrpc":"2.0","id":"list","method":"resources/templates/list","params":{}}
JSON

UNSET='name=[<unset>] vars=[<unset>]'
FAILURES=0

# expect_eq <message> <expected> <actual>: report every mismatch, fail at the end.
expect_eq() {
	if [ "$2" != "$3" ]; then
		printf 'MISMATCH %s\n  want: %s\n  got:  %s\n' "$1" "$2" "$3" >&2
		FAILURES=$((FAILURES + 1))
	fi
}

check_case() {
	local label="$1"
	local resp="${WORKSPACE}/responses-${label}.ndjson"
	test_run_mcp "${WORKSPACE}" "${WORKSPACE}/requests.ndjson" "${resp}"
	assert_json_lines "${resp}"
	local got
	got="$(jq -r 'select(.id=="tpl") | .result.contents[0].text // .error.message' "${resp}")"
	expect_eq "${label}: template read gets raw VARS" 'name=[kv-item] vars=[{"id":"42","rest":"a/b%2Fc"}]' "${got}"
	got="$(jq -r 'select(.id=="tpl-again") | .result.contents[0].text // .error.message' "${resp}")"
	expect_eq "${label}: second template read" 'name=[kv-item] vars=[{"id":"7","rest":"x"}]' "${got}"
	got="$(jq -r 'select(.id=="static") | .result.contents[0].text // .error.message' "${resp}")"
	expect_eq "${label}: static read sees no template env" "${UNSET}" "${got}"
	got="$(jq -r 'select(.id=="legacy") | .result.contents[0].text // .error.message' "${resp}")"
	expect_eq "${label}: unsupported template keeps 1.5.0 behaviour" "${UNSET}" "${got}"
	got="$(jq -r 'select(.id=="complete") | .result.completion.values[0] // .error.message // tojson' "${resp}")"
	expect_eq "${label}: completion provider sees no template env" "${UNSET}" "${got}"
	got="$(jq -r 'select(.id=="tool") | .result.content[0].text // .error.message' "${resp}")"
	expect_eq "${label}: tool sees no template env" "${UNSET}" "${got}"
	# templates/list shape is unchanged: no internal fields leak.
	got="$(jq -c 'select(.id=="list") | [.result.resourceTemplates[] | keys] | unique' "${resp}")"
	expect_eq "${label}: templates/list item keys" '[["name","uriTemplate"]]' "${got}"
}

# Host-set values must never reach a non-template read, a completion or a tool.
MCP_RESOURCE_TEMPLATE_NAME="host-name" MCP_RESOURCE_TEMPLATE_VARS='{"host":"1"}' \
	check_case isolate
MCP_RESOURCE_TEMPLATE_NAME="host-name" MCP_RESOURCE_TEMPLATE_VARS='{"host":"1"}' \
	MCPBASH_PROVIDER_ENV_MODE=inherit MCPBASH_PROVIDER_ENV_INHERIT_ALLOW=true \
	MCPBASH_TOOL_ENV_MODE=inherit MCPBASH_TOOL_ENV_INHERIT_ALLOW=true \
	check_case inherit

# --- Template "provider": the best-matching template picks the provider ---
ROUTE="${TEST_TMPDIR}/template-provider"
test_stage_workspace "${ROUTE}"
mkdir -p "${ROUTE}/providers" "${ROUTE}/resources" "${ROUTE}/server.d"
# The staged workspace carries copies of the built-in providers, and a project
# copy counts as a project provider. Remove them: built-ins come from MCPBASH_HOME.
rm -f "${ROUTE}/providers/"*.sh
printf '%s\n' '{"name": "template-provider"}' >"${ROUTE}/server.d/server.meta.json"
for p in alpha beta svc; do
	cat <<SH >"${ROUTE}/providers/${p}.sh"
#!/usr/bin/env bash
printf '${p} name=[%s]' "\${MCP_RESOURCE_TEMPLATE_NAME-<unset>}"
SH
	chmod +x "${ROUTE}/providers/${p}.sh"
done
# Two templates in one scheme, each with its own provider.
printf '%s\n' '{"name": "svc-alpha", "uriTemplate": "svc://alpha/{id}", "provider": "alpha"}' >"${ROUTE}/resources/svc-alpha.meta.json"
printf '%s\n' '{"name": "svc-beta", "uriTemplate": "svc://beta/{id}", "provider": "beta"}' >"${ROUTE}/resources/svc-beta.meta.json"
# No provider: scheme routing (providers/svc.sh).
printf '%s\n' '{"name": "svc-other", "uriTemplate": "svc://other/{id}"}' >"${ROUTE}/resources/svc-other.meta.json"
# A built-in on a foreign scheme is refused: scheme routing instead.
printf '%s\n' '{"name": "svc-bad", "uriTemplate": "svc://bad/{id}", "provider": "ui"}' >"${ROUTE}/resources/svc-bad.meta.json"
# A more specific template without provider beats the alpha template.
printf '%s\n' '{"name": "svc-alpha-special", "uriTemplate": "svc://alpha/special-{id}"}' >"${ROUTE}/resources/svc-alpha-special.meta.json"
# An exact static URI still wins over a matching template.
echo placeholder >"${ROUTE}/resources/svc-static.txt"
printf '%s\n' '{"name": "svc-static", "uri": "svc://alpha/static", "provider": "svc"}' >"${ROUTE}/resources/svc-static.meta.json"
chmod -R go-w "${ROUTE}"

cat <<'JSON' >"${ROUTE}/requests.ndjson"
{"jsonrpc":"2.0","id":"init","method":"initialize","params":{}}
{"jsonrpc":"2.0","method":"notifications/initialized"}
{"jsonrpc":"2.0","id":"alpha","method":"resources/read","params":{"uri":"svc://alpha/1"}}
{"jsonrpc":"2.0","id":"beta","method":"resources/read","params":{"uri":"svc://beta/2"}}
{"jsonrpc":"2.0","id":"other","method":"resources/read","params":{"uri":"svc://other/3"}}
{"jsonrpc":"2.0","id":"unmatched","method":"resources/read","params":{"uri":"svc://nowhere"}}
{"jsonrpc":"2.0","id":"bad","method":"resources/read","params":{"uri":"svc://bad/4"}}
{"jsonrpc":"2.0","id":"special","method":"resources/read","params":{"uri":"svc://alpha/special-5"}}
{"jsonrpc":"2.0","id":"static","method":"resources/read","params":{"uri":"svc://alpha/static"}}
{"jsonrpc":"2.0","id":"list","method":"resources/templates/list","params":{}}
JSON
ROUTE_RESP="${ROUTE}/responses.ndjson"
test_run_mcp "${ROUTE}" "${ROUTE}/requests.ndjson" "${ROUTE_RESP}"
assert_json_lines "${ROUTE_RESP}"
route_text() {
	jq -r --arg id "$1" 'select(.id==$id) | .result.contents[0].text // .error.message' "${ROUTE_RESP}"
}
expect_eq "provider: alpha template" 'alpha name=[svc-alpha]' "$(route_text alpha)"
expect_eq "provider: beta template, same scheme" 'beta name=[svc-beta]' "$(route_text beta)"
expect_eq "provider: template without provider uses the scheme" 'svc name=[svc-other]' "$(route_text other)"
expect_eq "provider: unmatched URI uses the scheme" 'svc name=[<unset>]' "$(route_text unmatched)"
expect_eq "provider: built-in on a foreign scheme is refused" 'svc name=[svc-bad]' "$(route_text bad)"
expect_eq "provider: the best match decides, no fallthrough" 'svc name=[svc-alpha-special]' "$(route_text special)"
expect_eq "provider: exact static URI wins" 'svc name=[<unset>]' "$(route_text static)"
expect_eq "provider: templates/list never shows provider" '[["name","uriTemplate"]]' \
	"$(jq -c 'select(.id=="list") | [.result.resourceTemplates[] | keys] | unique' "${ROUTE_RESP}")"
# The refused provider is not stored; a valid one is. (The registration
# warning is logged too, but whether it reaches the client as a notification
# depends on when the scan runs; unit tests check its text.)
ROUTE_TEMPLATES="${ROUTE}/.registry/resource-templates.json"
if [ ! -f "${ROUTE_TEMPLATES}" ]; then
	printf 'MISSING templates registry %s\n' "${ROUTE_TEMPLATES}" >&2
	FAILURES=$((FAILURES + 1))
else
	expect_eq "provider: refused provider is not stored" '<none>' \
		"$(jq -r '[.items[] | select(.name=="svc-bad") | .provider // "<none>"] | first // "<missing>"' "${ROUTE_TEMPLATES}")"
	expect_eq "provider: valid provider is stored" 'alpha' \
		"$(jq -r '[.items[] | select(.name=="svc-alpha") | .provider // "<none>"] | first // "<missing>"' "${ROUTE_TEMPLATES}")"
fi

if [ "${FAILURES}" -gt 0 ]; then
	test_fail "${FAILURES} template-read expectation(s) failed"
fi
printf 'Template-aware resources/read passed.\n'
