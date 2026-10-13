#!/usr/bin/env bash
# shellcheck disable=SC2034  # Used by test runner for reporting.
TEST_DESC="Server output validates against the official MCP JSON schemas."
set -euo pipefail

# For every protocol revision the server negotiates, run one session that
# touches each method family, then validate every line the server wrote:
# - each message against JSONRPCMessage;
# - each result against the Result type of the method that asked for it;
# - each notification against ServerNotification, each request against
#   ServerRequest.
# Schemas are vendored in test/conformance/schemas (see the README there).
# The validator is `jv` (github.com/santhosh-tekuri/jsonschema/cmd/jv). Without
# it the test skips, unless MCPBASH_CONFORMANCE_REQUIRE_SCHEMA=1 (CI sets it).

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../common/env.sh
# shellcheck disable=SC1091
. "${SCRIPT_DIR}/../common/env.sh"
# shellcheck source=../common/assert.sh
# shellcheck disable=SC1091
. "${SCRIPT_DIR}/../common/assert.sh"

SCHEMA_DIR="${MCPBASH_HOME}/test/conformance/schemas"
JV_BIN="${MCPBASH_JV_BIN:-$(command -v jv 2>/dev/null || true)}"
if [ -z "${JV_BIN}" ]; then
	if [ "${MCPBASH_CONFORMANCE_REQUIRE_SCHEMA:-0}" = "1" ]; then
		test_fail "jv not found (go install github.com/santhosh-tekuri/jsonschema/cmd/jv@v0.7.0)"
	fi
	printf 'SKIP: jv not found; install github.com/santhosh-tekuri/jsonschema/cmd/jv to run this test\n'
	exit 0
fi

test_create_tmpdir

# Revisions the server negotiates (lib/spec.sh); each needs a vendored schema.
# 2026-07-28 is a stateless session (no initialize; every request carries
# _meta), served with MCPBASH_MODERN_PROTOCOL=true.
VERSIONS="2024-11-05 2025-03-26 2025-06-18 2025-11-25 2026-07-28"
MODERN_VERSION="2026-07-28"

# --- Fixture project: tools, resources, a template, prompts, completions ---
WORKSPACE="${TEST_TMPDIR}/project"
test_stage_workspace "${WORKSPACE}"
mkdir -p "${WORKSPACE}/tools/echo" "${WORKSPACE}/tools/text" "${WORKSPACE}/tools/fail" \
	"${WORKSPACE}/tools/progress" "${WORKSPACE}/tools/crash" \
	"${WORKSPACE}/resources" "${WORKSPACE}/prompts" "${WORKSPACE}/completions" "${WORKSPACE}/server.d"

cat <<'JSON' >"${WORKSPACE}/tools/echo/tool.meta.json"
{"name": "conf.echo", "title": "Echo", "description": "Structured result",
 "inputSchema": {"type": "object", "properties": {"value": {"type": "string"}}},
 "outputSchema": {"type": "object", "required": ["value"], "properties": {"value": {"type": "string"}}},
 "annotations": {"readOnlyHint": true}}
JSON
cat <<'SH' >"${WORKSPACE}/tools/echo/tool.sh"
#!/usr/bin/env bash
source "${MCP_SDK}/tool-sdk.sh"
value="$(mcp_args_get '.value // "x"')"
mcp_result_json "$(mcp_json_obj value "${value}")"
SH

cat <<'JSON' >"${WORKSPACE}/tools/text/tool.meta.json"
{"name": "conf.text", "description": "Text result", "inputSchema": {"type": "object", "properties": {}}}
JSON
cat <<'SH' >"${WORKSPACE}/tools/text/tool.sh"
#!/usr/bin/env bash
source "${MCP_SDK}/tool-sdk.sh"
mcp_result_text "plain text"
SH

cat <<'JSON' >"${WORKSPACE}/tools/fail/tool.meta.json"
{"name": "conf.fail", "description": "Tool error result", "inputSchema": {"type": "object", "properties": {}}}
JSON
cat <<'SH' >"${WORKSPACE}/tools/fail/tool.sh"
#!/usr/bin/env bash
source "${MCP_SDK}/tool-sdk.sh"
mcp_fail --type invalid_args "value is required" --hint "pass value"
SH

cat <<'JSON' >"${WORKSPACE}/tools/progress/tool.meta.json"
{"name": "conf.progress", "description": "Progress and log notifications", "inputSchema": {"type": "object", "properties": {}}}
JSON
cat <<'SH' >"${WORKSPACE}/tools/progress/tool.sh"
#!/usr/bin/env bash
source "${MCP_SDK}/tool-sdk.sh"
mcp_progress 50 "half way"
mcp_log_info "conf" "working"
mcp_progress 100 "done"
mcp_result_text "finished"
SH

cat <<'JSON' >"${WORKSPACE}/tools/crash/tool.meta.json"
{"name": "conf.crash", "description": "Exits non-zero without a result", "inputSchema": {"type": "object", "properties": {}}}
JSON
cat <<'SH' >"${WORKSPACE}/tools/crash/tool.sh"
#!/usr/bin/env bash
printf 'something broke\n' >&2
exit 3
SH
chmod +x "${WORKSPACE}"/tools/*/tool.sh

printf 'Hello from a resource\n' >"${WORKSPACE}/resources/greeting.txt"
cat <<'JSON' >"${WORKSPACE}/resources/greeting.meta.json"
{"name": "conf-greeting", "title": "Greeting", "description": "A text resource",
 "uri": "file://./resources/greeting.txt", "mimeType": "text/plain", "provider": "file"}
JSON

printf 'Hello {{name}}\n' >"${WORKSPACE}/prompts/greeting.txt"
cat <<'JSON' >"${WORKSPACE}/prompts/greeting.meta.json"
{"name": "conf.greeting", "description": "Greeting prompt", "path": "greeting.txt",
 "arguments": {"type": "object", "required": ["name"], "properties": {"name": {"type": "string", "description": "Who"}}}}
JSON

cat <<'SH' >"${WORKSPACE}/completions/suggest.sh"
#!/usr/bin/env bash
printf '%s\n' '{"suggestions":["alpha","beta"],"hasMore":false}'
SH
chmod +x "${WORKSPACE}/completions/suggest.sh"

cat <<'JSON' >"${WORKSPACE}/server.d/register.json"
{
  "version": 1,
  "completions": [{"name": "conf.greeting", "path": "completions/suggest.sh", "timeoutSecs": 5}],
  "resourceTemplates": [
    {"name": "conf-files", "title": "Files", "uriTemplate": "file:///{+path}", "description": "Files under the roots", "provider": "file"}
  ]
}
JSON

# --- One session per revision ---
# Request ids are "<method>#<n>", so each response says which method it answers.
write_requests() {
	local version="$1" file="$2" greeting_uri="file://${WORKSPACE}/resources/greeting.txt"
	if [ "${version}" = "${MODERN_VERSION}" ]; then
		write_modern_requests "${file}" "${greeting_uri}"
		return
	fi
	{
		printf '%s\n' '{"jsonrpc":"2.0","id":"initialize#1","method":"initialize","params":{"protocolVersion":"'"${version}"'","capabilities":{"roots":{"listChanged":true}},"clientInfo":{"name":"conformance","version":"1.0.0"}}}'
		printf '%s\n' '{"jsonrpc":"2.0","method":"notifications/initialized"}'
		printf '%s\n' '{"jsonrpc":"2.0","id":"ping#2","method":"ping"}'
		printf '%s\n' '{"jsonrpc":"2.0","id":"logging/setLevel#3","method":"logging/setLevel","params":{"level":"info"}}'
		printf '%s\n' '{"jsonrpc":"2.0","id":"tools/list#4","method":"tools/list"}'
		printf '%s\n' '{"jsonrpc":"2.0","id":"tools/call#5","method":"tools/call","params":{"name":"conf.echo","arguments":{"value":"hi"}}}'
		printf '%s\n' '{"jsonrpc":"2.0","id":"tools/call#6","method":"tools/call","params":{"name":"conf.text","arguments":{}}}'
		printf '%s\n' '{"jsonrpc":"2.0","id":"tools/call#7","method":"tools/call","params":{"name":"conf.fail","arguments":{}}}'
		printf '%s\n' '{"jsonrpc":"2.0","id":"tools/call#8","method":"tools/call","params":{"name":"conf.progress","arguments":{},"_meta":{"progressToken":"p1"}}}'
		printf '%s\n' '{"jsonrpc":"2.0","id":"tools/call#9","method":"tools/call","params":{"name":"conf.crash","arguments":{}}}'
		printf '%s\n' '{"jsonrpc":"2.0","id":"tools/call#10","method":"tools/call","params":{"name":"conf.missing","arguments":{}}}'
		printf '%s\n' '{"jsonrpc":"2.0","id":"resources/list#11","method":"resources/list"}'
		printf '%s\n' '{"jsonrpc":"2.0","id":"resources/templates/list#12","method":"resources/templates/list"}'
		printf '%s\n' '{"jsonrpc":"2.0","id":"resources/read#13","method":"resources/read","params":{"uri":"'"${greeting_uri}"'"}}'
		printf '%s\n' '{"jsonrpc":"2.0","id":"resources/read#14","method":"resources/read","params":{"uri":"file:///nonexistent/conformance.txt"}}'
		printf '%s\n' '{"jsonrpc":"2.0","id":"resources/subscribe#15","method":"resources/subscribe","params":{"uri":"'"${greeting_uri}"'"}}'
		printf '%s\n' '{"jsonrpc":"2.0","id":"resources/unsubscribe#16","method":"resources/unsubscribe","params":{"uri":"'"${greeting_uri}"'"}}'
		printf '%s\n' '{"jsonrpc":"2.0","id":"prompts/list#17","method":"prompts/list"}'
		printf '%s\n' '{"jsonrpc":"2.0","id":"prompts/get#18","method":"prompts/get","params":{"name":"conf.greeting","arguments":{"name":"Ada"}}}'
		printf '%s\n' '{"jsonrpc":"2.0","id":"completion/complete#19","method":"completion/complete","params":{"ref":{"type":"ref/prompt","name":"conf.greeting"},"argument":{"name":"name","value":"a"}}}'
		printf '%s\n' '{"jsonrpc":"2.0","id":"no/such/method#20","method":"no/such/method"}'
		printf '%s\n' 'this is not json'
	} >"${file}"
}

# The same session for 2026-07-28: no initialize, and every request carries
# the protocol version and client capabilities in _meta. ping,
# logging/setLevel and resources/(un)subscribe were removed, so they get
# "Method not found"; the progress call asks for log notifications.
write_modern_requests() {
	local file="$1" greeting_uri="$2"
	local meta='"_meta":{"io.modelcontextprotocol/protocolVersion":"2026-07-28","io.modelcontextprotocol/clientCapabilities":{}}'
	local meta_log='"_meta":{"io.modelcontextprotocol/protocolVersion":"2026-07-28","io.modelcontextprotocol/clientCapabilities":{},"io.modelcontextprotocol/logLevel":"info","progressToken":"p1"}'
	{
		printf '%s\n' '{"jsonrpc":"2.0","id":"server/discover#1","method":"server/discover","params":{'"${meta}"'}}'
		printf '%s\n' '{"jsonrpc":"2.0","id":"ping#2","method":"ping","params":{'"${meta}"'}}'
		printf '%s\n' '{"jsonrpc":"2.0","id":"logging/setLevel#3","method":"logging/setLevel","params":{"level":"info",'"${meta}"'}}'
		printf '%s\n' '{"jsonrpc":"2.0","id":"tools/list#4","method":"tools/list","params":{'"${meta}"'}}'
		printf '%s\n' '{"jsonrpc":"2.0","id":"tools/call#5","method":"tools/call","params":{"name":"conf.echo","arguments":{"value":"hi"},'"${meta}"'}}'
		printf '%s\n' '{"jsonrpc":"2.0","id":"tools/call#6","method":"tools/call","params":{"name":"conf.text","arguments":{},'"${meta}"'}}'
		printf '%s\n' '{"jsonrpc":"2.0","id":"tools/call#7","method":"tools/call","params":{"name":"conf.fail","arguments":{},'"${meta}"'}}'
		printf '%s\n' '{"jsonrpc":"2.0","id":"tools/call#8","method":"tools/call","params":{"name":"conf.progress","arguments":{},'"${meta_log}"'}}'
		printf '%s\n' '{"jsonrpc":"2.0","id":"tools/call#9","method":"tools/call","params":{"name":"conf.crash","arguments":{},'"${meta}"'}}'
		printf '%s\n' '{"jsonrpc":"2.0","id":"tools/call#10","method":"tools/call","params":{"name":"conf.missing","arguments":{},'"${meta}"'}}'
		printf '%s\n' '{"jsonrpc":"2.0","id":"resources/list#11","method":"resources/list","params":{'"${meta}"'}}'
		printf '%s\n' '{"jsonrpc":"2.0","id":"resources/templates/list#12","method":"resources/templates/list","params":{'"${meta}"'}}'
		printf '%s\n' '{"jsonrpc":"2.0","id":"resources/read#13","method":"resources/read","params":{"uri":"'"${greeting_uri}"'",'"${meta}"'}}'
		printf '%s\n' '{"jsonrpc":"2.0","id":"resources/read#14","method":"resources/read","params":{"uri":"file:///nonexistent/conformance.txt",'"${meta}"'}}'
		printf '%s\n' '{"jsonrpc":"2.0","id":"resources/subscribe#15","method":"resources/subscribe","params":{"uri":"'"${greeting_uri}"'",'"${meta}"'}}'
		printf '%s\n' '{"jsonrpc":"2.0","id":"prompts/list#17","method":"prompts/list","params":{'"${meta}"'}}'
		printf '%s\n' '{"jsonrpc":"2.0","id":"prompts/get#18","method":"prompts/get","params":{"name":"conf.greeting","arguments":{"name":"Ada"},'"${meta}"'}}'
		printf '%s\n' '{"jsonrpc":"2.0","id":"completion/complete#19","method":"completion/complete","params":{"ref":{"type":"ref/prompt","name":"conf.greeting"},"argument":{"name":"name","value":"a"},'"${meta}"'}}'
		printf '%s\n' '{"jsonrpc":"2.0","id":"no/such/method#20","method":"no/such/method","params":{'"${meta}"'}}'
		printf '%s\n' 'this is not json'
	} >"${file}"
}

# Result type for each method, as named in the schemas.
result_def_for() {
	case "$1" in
	initialize) printf 'InitializeResult' ;;
	server/discover) printf 'DiscoverResult' ;;
	tools/list) printf 'ListToolsResult' ;;
	tools/call) printf 'CallToolResult' ;;
	resources/list) printf 'ListResourcesResult' ;;
	resources/templates/list) printf 'ListResourceTemplatesResult' ;;
	resources/read) printf 'ReadResourceResult' ;;
	prompts/list) printf 'ListPromptsResult' ;;
	prompts/get) printf 'GetPromptResult' ;;
	completion/complete) printf 'CompleteResult' ;;
	ping | logging/setLevel | resources/subscribe | resources/unsubscribe) printf 'EmptyResult' ;;
	*) return 1 ;;
	esac
}

# Results the session must produce, so a quiet server can't pass by saying nothing.
REQUIRED_DEFS="InitializeResult ListToolsResult CallToolResult ListResourcesResult ListResourceTemplatesResult ReadResourceResult ListPromptsResult GetPromptResult CompleteResult EmptyResult ServerNotification"

failures=0
for version in ${VERSIONS}; do
	schema="${SCHEMA_DIR}/${version}.json"
	[ -f "${schema}" ] || test_fail "no vendored schema for ${version}"
	defs_key="definitions"
	if jq -e 'has("$defs")' "${schema}" >/dev/null; then
		defs_key='$defs'
	fi

	# Up to 2025-06-18 an error response must carry a string or integer id, so
	# a parse error (whose request id is unknown) has no valid shape there;
	# JSON-RPC's "id": null fails too. Those lines are checked from 2025-11-25,
	# where id is optional, and skipped before it.
	error_id_required=0
	if jq -e --arg k "${defs_key}" '.[$k] | (.JSONRPCError // .JSONRPCErrorResponse).required | index("id")' "${schema}" >/dev/null; then
		error_id_required=1
	fi

	run_dir="${TEST_TMPDIR}/${version}"
	mkdir -p "${run_dir}/instances"
	write_requests "${version}" "${run_dir}/requests.ndjson"
	required_defs="${REQUIRED_DEFS}"
	if [ "${version}" = "${MODERN_VERSION}" ]; then
		MCPBASH_MODERN_PROTOCOL=true test_run_mcp "${WORKSPACE}" "${run_dir}/requests.ndjson" "${run_dir}/responses.ndjson" || true
		# No initialize, and no EmptyResult (ping and friends were removed).
		required_defs="DiscoverResult ListToolsResult CallToolResult ListResourcesResult ListResourceTemplatesResult ReadResourceResult ListPromptsResult GetPromptResult CompleteResult ServerNotification"
		for removed in ping#2 logging/setLevel#3 resources/subscribe#15; do
			if ! jq -e --arg id "${removed}" 'select(.id == $id) | .error.code == -32601' "${run_dir}/responses.ndjson" >/dev/null; then
				printf '%s: %s should get -32601\n' "${version}" "${removed}" >&2
				failures=$((failures + 1))
			fi
		done
	else
		test_run_mcp "${WORKSPACE}" "${run_dir}/requests.ndjson" "${run_dir}/responses.ndjson" || true

		negotiated="$(jq -r 'select(.id == "initialize#1") | .result.protocolVersion // empty' "${run_dir}/responses.ndjson")"
		if [ "${negotiated}" != "${version}" ]; then
			printf '%s: negotiated %s\n' "${version}" "${negotiated:-nothing}" >&2
			failures=$((failures + 1))
			continue
		fi
	fi

	# Sort every line into instance files: <def>/<n>.json.
	n=0
	while IFS= read -r line; do
		[ -n "${line}" ] || continue
		n=$((n + 1))
		if [ "${error_id_required}" = "1" ] && printf '%s' "${line}" | jq -e 'has("error") and (has("id") | not)' >/dev/null; then
			continue
		fi
		mkdir -p "${run_dir}/instances/JSONRPCMessage"
		printf '%s\n' "${line}" >"${run_dir}/instances/JSONRPCMessage/${n}.json"
		kind="$(printf '%s' "${line}" | jq -r '
			if has("method") and has("id") then "request"
			elif has("method") then "notification"
			elif has("result") then "result"
			else "error" end')"
		case "${kind}" in
		request)
			mkdir -p "${run_dir}/instances/ServerRequest"
			printf '%s\n' "${line}" >"${run_dir}/instances/ServerRequest/${n}.json"
			;;
		notification)
			mkdir -p "${run_dir}/instances/ServerNotification"
			printf '%s\n' "${line}" >"${run_dir}/instances/ServerNotification/${n}.json"
			;;
		result)
			id="$(printf '%s' "${line}" | jq -r '.id | tostring')"
			if ! def="$(result_def_for "${id%#*}")"; then
				printf '%s: result for unexpected id %s\n' "${version}" "${id}" >&2
				failures=$((failures + 1))
				continue
			fi
			mkdir -p "${run_dir}/instances/${def}"
			printf '%s' "${line}" | jq -c '.result' >"${run_dir}/instances/${def}/${n}.json"
			;;
		esac
	done <"${run_dir}/responses.ndjson"

	for def in ${required_defs}; do
		if [ ! -d "${run_dir}/instances/${def}" ]; then
			printf '%s: no %s in the session output\n' "${version}" "${def}" >&2
			failures=$((failures + 1))
		fi
	done
	if ! jq -e 'select(.id == "tools/call#7") | .result.isError == true' "${run_dir}/responses.ndjson" >/dev/null; then
		printf '%s: conf.fail did not return an isError result\n' "${version}" >&2
		failures=$((failures + 1))
	fi
	if ! jq -e 'select(has("error") and (has("id") | not))' "${run_dir}/responses.ndjson" >/dev/null; then
		printf '%s: no parse-error response for the malformed line\n' "${version}" >&2
		failures=$((failures + 1))
	fi

	for dir in "${run_dir}/instances"/*; do
		[ -d "${dir}" ] || continue
		def="${dir##*/}"
		if ! jq -e --arg k "${defs_key}" --arg d "${def}" '.[$k] | has($d)' "${schema}" >/dev/null; then
			printf '%s: schema has no %s\n' "${version}" "${def}" >&2
			failures=$((failures + 1))
			continue
		fi
		if ! "${JV_BIN}" "${schema}#/${defs_key}/${def}" "${dir}"/*.json >"${run_dir}/jv.${def}.out" 2>&1; then
			printf '%s: %s failed schema validation:\n' "${version}" "${def}" >&2
			grep -v ': ok$' "${run_dir}/jv.${def}.out" | sed 's/^/    /' >&2
			for f in "${dir}"/*.json; do
				if ! "${JV_BIN}" -q "${schema}#/${defs_key}/${def}" "${f}" >/dev/null 2>&1; then
					printf '    instance: %s\n' "$(head -c 600 "${f}")" >&2
				fi
			done
			failures=$((failures + 1))
		fi
	done
	printf '%s: %d messages checked\n' "${version}" "${n}"
	# MCPBASH_CONFORMANCE_OUT=DIR keeps each session's requests, output and
	# validator reports for inspection.
	if [ -n "${MCPBASH_CONFORMANCE_OUT:-}" ]; then
		mkdir -p "${MCPBASH_CONFORMANCE_OUT}"
		cp -R "${run_dir}" "${MCPBASH_CONFORMANCE_OUT}/"
	fi
done

if [ "${failures}" -gt 0 ]; then
	test_fail "${failures} schema conformance failure(s)"
fi
printf 'Schema conformance passed for %s\n' "${VERSIONS}"
