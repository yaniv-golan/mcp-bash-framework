#!/usr/bin/env bash
TEST_DESC="Prompt auto-discovery, manual overrides, and subscriptions."
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../common/env.sh
# shellcheck disable=SC1091
. "${SCRIPT_DIR}/../common/env.sh"
# shellcheck source=../common/assert.sh
# shellcheck disable=SC1091
. "${SCRIPT_DIR}/../common/assert.sh"

IS_WINDOWS=false
case "$(uname -s 2>/dev/null)" in
MINGW* | MSYS* | CYGWIN*)
	IS_WINDOWS=true
	;;
esac

test_create_tmpdir

stage_workspace() {
	local dest="$1"
	mkdir -p "${dest}"
	# Copy framework files
	cp -a "${MCPBASH_HOME}/bin" "${dest}/"
	cp -a "${MCPBASH_HOME}/lib" "${dest}/"
	cp -a "${MCPBASH_HOME}/handlers" "${dest}/"
	cp -a "${MCPBASH_HOME}/providers" "${dest}/"
	cp -a "${MCPBASH_HOME}/sdk" "${dest}/"
	cp -a "${MCPBASH_HOME}/scaffold" "${dest}/" 2>/dev/null || true
	# Create project directories
	mkdir -p "${dest}/tools"
	mkdir -p "${dest}/resources"
	mkdir -p "${dest}/prompts"
	mkdir -p "${dest}/server.d"
}

# --- Auto-discovery prompts ---
AUTO_ROOT="${TEST_TMPDIR}/auto"
stage_workspace "${AUTO_ROOT}"
# Remove register.sh to force auto-discovery (chmod -x doesn't work on Windows)
rm -f "${AUTO_ROOT}/server.d/register.sh"
mkdir -p "${AUTO_ROOT}/prompts"

cat <<'EOF_PROMPT' >"${AUTO_ROOT}/prompts/alpha.txt"
Hello ${name}!
EOF_PROMPT

cat <<'EOF_META' >"${AUTO_ROOT}/prompts/alpha.meta.json"
{"name": "prompt.alpha", "description": "Alpha prompt", "arguments": {"type": "object", "properties": {"name": {"type": "string"}}}, "role": "system"}
EOF_META

cat <<'EOF_PROMPT' >"${AUTO_ROOT}/prompts/beta.txt"
Beta prompt for ${topic}
EOF_PROMPT

cat <<'EOF_META' >"${AUTO_ROOT}/prompts/beta.meta.json"
{"name": "prompt.beta", "description": "Beta prompt", "arguments": {"type": "object", "properties": {"topic": {"type": "string"}}}, "role": "system"}
EOF_META

cat <<'JSON' >"${AUTO_ROOT}/requests.ndjson"
{"jsonrpc":"2.0","id":"auto-init","method":"initialize","params":{}}
{"jsonrpc":"2.0","method":"notifications/initialized"}
{"jsonrpc":"2.0","id":"auto-list","method":"prompts/list","params":{"limit":1}}
{"jsonrpc":"2.0","id":"auto-get","method":"prompts/get","params":{"name":"prompt.alpha","arguments":{"name":"World"}}}
JSON

(
	cd "${AUTO_ROOT}" || exit 1
	MCPBASH_PROJECT_ROOT="${AUTO_ROOT}" ./bin/mcp-bash <"requests.ndjson" >"responses.ndjson"
)

# Verify auto-discovery responses with jq
if ! jq -e '
	select(.id == "auto-list") |
	(.result.prompts | length == 1) and
	(.result.nextCursor != null) and
	(.result.prompts[0].name != null)
' "${AUTO_ROOT}/responses.ndjson" >/dev/null; then
	printf '❌ auto-list response invalid\n' >&2
	exit 1
fi

if ! jq -e '
	def trimstr($s):
		($s | gsub("^[[:space:]]+";"") | gsub("[[:space:]]+$";""));
	select(.id == "auto-get") |
	(trimstr(.result.text) == "Hello World!") and
	(trimstr(.result.messages[0].content[0].text) == "Hello World!") and
	(.result.arguments == {name: "World"})
' "${AUTO_ROOT}/responses.ndjson" >/dev/null; then
	printf '❌ auto-get response invalid\n' >&2
	exit 1
fi

# --- Manual registration overrides ---
MANUAL_ROOT="${TEST_TMPDIR}/manual"
stage_workspace "${MANUAL_ROOT}"
mkdir -p "${MANUAL_ROOT}/prompts/manual"

cat <<'EOF_PROMPT' >"${MANUAL_ROOT}/prompts/manual/greet.txt"
Greetings ${name}, welcome aboard.
EOF_PROMPT

cat <<'EOF_PROMPT' >"${MANUAL_ROOT}/prompts/manual/farewell.txt"
Goodbye ${name}, see you soon.
EOF_PROMPT

cat <<'EOF_SCRIPT' >"${MANUAL_ROOT}/server.d/register.sh"
#!/usr/bin/env bash
set -euo pipefail

# Paths are relative to MCPBASH_PROMPTS_DIR (not MCPBASH_PROJECT_ROOT)
mcp_register_prompt '{
  "name": "manual.greet",
  "description": "Manual greet prompt",
  "path": "manual/greet.txt",
  "arguments": {"type": "object", "properties": {"name": {"type": "string"}}},
  "role": "system"
}'

mcp_register_prompt '{
  "name": "manual.farewell",
  "description": "Manual farewell prompt",
  "path": "manual/farewell.txt",
  "arguments": {"type": "object", "properties": {"name": {"type": "string"}}},
  "role": "system"
}'

return 0
EOF_SCRIPT
chmod +x "${MANUAL_ROOT}/server.d/register.sh"

cat <<'JSON' >"${MANUAL_ROOT}/requests.ndjson"
{"jsonrpc":"2.0","id":"manual-init","method":"initialize","params":{}}
{"jsonrpc":"2.0","method":"notifications/initialized"}
{"jsonrpc":"2.0","id":"manual-list","method":"prompts/list","params":{"limit":5}}
{"jsonrpc":"2.0","id":"manual-get","method":"prompts/get","params":{"name":"manual.farewell","arguments":{"name":"Ada"}}}
JSON

(
	cd "${MANUAL_ROOT}" || exit 1
	MCPBASH_PROJECT_ROOT="${MANUAL_ROOT}" ./bin/mcp-bash <"requests.ndjson" >"responses.ndjson"
)

# Verify manual prompt responses
if ! jq -e '
	select(.id == "manual-list") |
	(.result.prompts | length == 2) and
	(.result.prompts | map(.name) | sort == ["manual.farewell", "manual.greet"])
' "${MANUAL_ROOT}/responses.ndjson" >/dev/null; then
	printf '❌ manual-list response invalid\n' >&2
	exit 1
fi

if ! jq -e '
	def trimstr($s):
		($s | gsub("^[[:space:]]+";"") | gsub("[[:space:]]+$";""));
	select(.id == "manual-get") |
	(trimstr(.result.text) == "Goodbye Ada, see you soon.") and
	(trimstr(.result.messages[0].content[0].text) == "Goodbye Ada, see you soon.")
' "${MANUAL_ROOT}/responses.ndjson" >/dev/null; then
	printf '❌ manual-get response invalid\n' >&2
	exit 1
fi

# --- TTL-driven list_changed notifications ---

run_windows_prompt_notification() {
	local win_root="${TEST_TMPDIR}/poll-win"
	stage_workspace "${win_root}"
	rm -f "${win_root}/server.d/register.sh"
	mkdir -p "${win_root}/prompts"

	cat <<'EOF_PROMPT' >"${win_root}/prompts/live.txt"
Live version 1
EOF_PROMPT

	cat <<'EOF_META' >"${win_root}/prompts/live.meta.json"
{"name": "prompt.live", "description": "Live prompt", "arguments": {"type": "object", "properties": {}}, "role": "system"}
EOF_META

	cat <<'JSON' >"${win_root}/req1.ndjson"
{"jsonrpc":"2.0","id":"init","method":"initialize","params":{}}
{"jsonrpc":"2.0","method":"notifications/initialized"}
{"jsonrpc":"2.0","id":"list1","method":"prompts/list","params":{}}
JSON

	MCPBASH_PROJECT_ROOT="${win_root}" MCP_PROMPTS_TTL=1 ./bin/mcp-bash <"${win_root}/req1.ndjson" >"${win_root}/res1.ndjson"

	local count1
	count1="$(grep -c 'notifications/prompts/list_changed' "${win_root}/res1.ndjson" || true)"
	assert_eq 1 "${count1}" "Expected one prompts list_changed on first run (Windows file-based)"

	local desc1
	desc1="$(jq -r 'select(.id=="list1") | .result.prompts[0].description // empty' "${win_root}/res1.ndjson")"
	assert_eq "Live prompt" "${desc1}" "Description should match v1"

	# mutate prompt metadata
	cat <<'EOF_META' >"${win_root}/prompts/live.meta.json"
{"name": "prompt.live", "description": "Live prompt v2", "arguments": {"type": "object", "properties": {}}, "role": "system"}
EOF_META

	cat <<'JSON' >"${win_root}/req2.ndjson"
{"jsonrpc":"2.0","id":"init","method":"initialize","params":{}}
{"jsonrpc":"2.0","method":"notifications/initialized"}
{"jsonrpc":"2.0","id":"list2","method":"prompts/list","params":{}}
JSON

	MCPBASH_PROJECT_ROOT="${win_root}" MCP_PROMPTS_TTL=1 ./bin/mcp-bash <"${win_root}/req2.ndjson" >"${win_root}/res2.ndjson"

	local count2
	count2="$(grep -c 'notifications/prompts/list_changed' "${win_root}/res2.ndjson" || true)"
	assert_eq 1 "${count2}" "Expected one prompts list_changed after mutation (Windows file-based)"

	local desc2
	desc2="$(jq -r 'select(.id=="list2") | .result.prompts[0].description // empty' "${win_root}/res2.ndjson")"
	assert_eq "Live prompt v2" "${desc2}" "Description should match v2"
}

if [ "${IS_WINDOWS}" = "true" ]; then
	run_windows_prompt_notification
	exit 0
fi

POLL_ROOT="${TEST_TMPDIR}/poll"
stage_workspace "${POLL_ROOT}"
# Remove register.sh to force auto-discovery (chmod -x doesn't work on Windows)
rm -f "${POLL_ROOT}/server.d/register.sh"
mkdir -p "${POLL_ROOT}/prompts"

cat <<'EOF_PROMPT' >"${POLL_ROOT}/prompts/live.txt"
Live version 1
EOF_PROMPT

cat <<'EOF_META' >"${POLL_ROOT}/prompts/live.meta.json"
{"name": "prompt.live", "description": "Live prompt", "arguments": {"type": "object", "properties": {}}, "role": "system"}
EOF_META

export POLL_ROOT
pipe_in="${POLL_ROOT}/prompts_pipe_in"
pipe_out="${POLL_ROOT}/prompts_pipe_out"
rm -f "${pipe_in}" "${pipe_out}"
mkfifo "${pipe_in}" "${pipe_out}"
(
	cd "${POLL_ROOT}" || exit 1
	export MCP_PROMPTS_TTL="1"
	export MCPBASH_PROJECT_ROOT="${POLL_ROOT}"
	./bin/mcp-bash <"${pipe_in}" >"${pipe_out}" &
	echo $! >"${POLL_ROOT}/server.pid"
) || true
exec 3>"${pipe_in}"
exec 4<"${pipe_out}"

send() {
	printf '%s\n' "$1" >&3
}

read_response() {
	local line
	# Safety timeout to avoid hanging if the server stops producing output
	if read -r -t 5 -u 4 line; then
		printf '%s' "${line}"
		return 0
	fi
	# Timeout or EOF: return empty so callers can decide to continue waiting
	return 2
}

wait_for() {
	local match_key="$1"
	local match_val="$2"
	local timeout="${3:-10}"
	local end_time=$(($(date +%s) + timeout))

	while [ "$(date +%s)" -lt "${end_time}" ]; do
		local response
		if ! response="$(read_response)"; then
			return 1
		fi
		if [ -z "${response}" ]; then
			continue
		fi

		local val
		val="$(printf '%s' "${response}" | jq -r ".${match_key} // empty")"
		if [ "${val}" = "${match_val}" ]; then
			return 0
		fi
	done
	return 1
}

# Initialize
send '{"jsonrpc": "2.0", "id": "init", "method": "initialize", "params": {}}'
wait_for "id" "init" || {
	printf 'Init timeout\n' >&2
	exit 1
}

send '{"jsonrpc": "2.0", "method": "notifications/initialized"}'

# Initial list
send '{"jsonrpc": "2.0", "id": "list", "method": "prompts/list", "params": {}}'
wait_for "id" "list" || {
	printf 'List timeout\n' >&2
	exit 1
}

# Wait for TTL, then modify prompt metadata and trigger another prompts/list
sleep 1.2
cat <<'EOF_META' >"${POLL_ROOT}/prompts/live.meta.json"
{"name": "prompt.live", "description": "Live prompt v2", "arguments": {"type": "object", "properties": {}}, "role": "system"}
EOF_META
send '{"jsonrpc": "2.0", "id": "list2", "method": "prompts/list", "params": {}}'

# Expect a list2 response AND a list_changed notification
seen_update=false
seen_list=false
end_time=$(($(date +%s) + 10))

while [ "$(date +%s)" -lt "${end_time}" ]; do
	if [ "${seen_update}" = "true" ] && [ "${seen_list}" = "true" ]; then
		break
	fi
	response="$(read_response || true)"
	if [ -z "${response}" ]; then
		continue
	fi

	id="$(printf '%s' "${response}" | jq -r '.id // empty')"
	method="$(printf '%s' "${response}" | jq -r '.method // empty')"

	if [ "${id}" = "list2" ]; then
		seen_list=true
	fi
	if [ "${method}" = "notifications/prompts/list_changed" ]; then
		seen_update=true
	fi
done

if [ "${seen_update}" != "true" ]; then
	printf 'Missing prompts/list_changed notification\n' >&2
	result=1
else
	result=0
fi

send '{"jsonrpc": "2.0", "id": "shutdown", "method": "shutdown"}'
wait_for "id" "shutdown" 5 || result=1
send '{"jsonrpc": "2.0", "id": "exit", "method": "exit"}'
exec 3>&-
# Drain remaining responses with timeout to prevent hang if server died
while read -t 2 -r -u 4 line 2>/dev/null; do
	:
done
exec 4<&-
if [ -f "${POLL_ROOT}/server.pid" ]; then
	server_pid="$(cat "${POLL_ROOT}/server.pid")"
	wait "${server_pid}" 2>/dev/null || true
fi
rm -f "${pipe_in}" "${pipe_out}"
[ "${result:-0}" -eq 0 ] || exit 1
