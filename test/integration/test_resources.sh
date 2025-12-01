#!/usr/bin/env bash
# shellcheck disable=SC2034  # Used by test runner for reporting.
TEST_DESC="Resource discovery, manual overrides, and subscriptions."
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

echo "Resources integration temp root: ${TEST_TMPDIR}"

run_server() {
	local workdir="$1"
	local request_file="$2"
	local response_file="$3"
	(
		cd "${workdir}" || exit 1
		MCPBASH_PROJECT_ROOT="${workdir}" ./bin/mcp-bash <"${request_file}" >"${response_file}"
	)
}

# --- Auto-discovery and pagination ---
AUTO_ROOT="${TEST_TMPDIR}/auto"
test_stage_workspace "${AUTO_ROOT}"
# Remove register.sh to force auto-discovery (chmod -x doesn't work on Windows)
rm -f "${AUTO_ROOT}/server.d/register.sh"
mkdir -p "${AUTO_ROOT}/resources"

echo "  • Auto-discovery workspace: ${AUTO_ROOT}"

cat <<EOF_RES >"${AUTO_ROOT}/resources/alpha.txt"
alpha
EOF_RES

cat <<EOF_RES >"${AUTO_ROOT}/resources/beta.txt"
beta
EOF_RES

cat <<EOF_META >"${AUTO_ROOT}/resources/alpha.meta.json"
{"name": "file.alpha", "description": "Alpha resource", "uri": "file://${AUTO_ROOT}/resources/alpha.txt", "mimeType": "text/plain"}
EOF_META

cat <<EOF_META >"${AUTO_ROOT}/resources/beta.meta.json"
{"name": "file.beta", "description": "Beta resource", "uri": "file://${AUTO_ROOT}/resources/beta.txt", "mimeType": "text/plain"}
EOF_META

cat <<'JSON' >"${AUTO_ROOT}/requests.ndjson"
{"jsonrpc":"2.0","id":"auto-init","method":"initialize","params":{}}
{"jsonrpc":"2.0","method":"notifications/initialized"}
{"jsonrpc":"2.0","id":"auto-list","method":"resources/list","params":{"limit":1}}
{"jsonrpc":"2.0","id":"auto-read","method":"resources/read","params":{"name":"file.alpha"}}
JSON

(
	cd "${AUTO_ROOT}" || exit 1
	MCPBASH_PROJECT_ROOT="${AUTO_ROOT}" ./bin/mcp-bash <"requests.ndjson" >"responses.ndjson"
)

# Use jq -s instead of --slurpfile for better gojq compatibility on Windows
jq -s '
	def error(msg): error(msg);
	
	(map(select(.id == "auto-list"))[0].result) as $list |
	(map(select(.id == "auto-read"))[0].result) as $read |
	
	if ($list.resources | length) != 1 then error("expected one resource in paginated result") else null end,
	if ($list | has("nextCursor") | not) then error("nextCursor missing for paginated resources") else null end,
	if ($list.resources[0].name | IN("file.alpha", "file.beta") | not) then error("unexpected resource name") else null end,
	
	if $read.contents[0].mimeType != "text/plain" then error("unexpected mimeType") else null end,
	if $read.contents[0].text != "alpha" then error("resource content mismatch") else null end
' <"${AUTO_ROOT}/responses.ndjson" >/dev/null

# --- Manual registration overrides ---
MANUAL_ROOT="${TEST_TMPDIR}/manual"
test_stage_workspace "${MANUAL_ROOT}"
mkdir -p "${MANUAL_ROOT}/resources/manual"

echo "  • Manual override workspace: ${MANUAL_ROOT}"

cat <<EOF_RES >"${MANUAL_ROOT}/resources/manual/left.txt"
left
EOF_RES
cat <<EOF_RES >"${MANUAL_ROOT}/resources/manual/right.txt"
right
EOF_RES

cat <<EOF_SCRIPT >"${MANUAL_ROOT}/server.d/register.sh"
#!/usr/bin/env bash
set -euo pipefail

mcp_register_resource '{
  "name": "manual.left",
  "description": "Left resource",
  "uri": "file://${MANUAL_ROOT}/resources/manual/left.txt",
  "mimeType": "text/plain"
}'

mcp_register_resource '{
  "name": "manual.right",
  "description": "Right resource",
  "uri": "file://${MANUAL_ROOT}/resources/manual/right.txt",
  "mimeType": "text/plain"
}'

return 0
EOF_SCRIPT
chmod +x "${MANUAL_ROOT}/server.d/register.sh"

cat <<'JSON' >"${MANUAL_ROOT}/requests.ndjson"
{"jsonrpc":"2.0","id":"manual-init","method":"initialize","params":{}}
{"jsonrpc":"2.0","method":"notifications/initialized"}
{"jsonrpc":"2.0","id":"manual-list","method":"resources/list","params":{"limit":2}}
{"jsonrpc":"2.0","id":"manual-read","method":"resources/read","params":{"name":"manual.right"}}
JSON

(
	cd "${MANUAL_ROOT}" || exit 1
	MCPBASH_PROJECT_ROOT="${MANUAL_ROOT}" ./bin/mcp-bash <"requests.ndjson" >"responses.ndjson"
)

# Use jq -s instead of --slurpfile for better gojq compatibility on Windows
jq -s '
	def error(msg): error(msg);
	
	(map(select(.id == "manual-list"))[0].result) as $list |
	(map(select(.id == "manual-read"))[0].result) as $read |
	
	if ($list.resources | length) != 2 then error("manual registry should contain two resources") else null end,
	if ($list.resources[] | .name | IN("manual.left", "manual.right") | not) then error("unexpected resource discovered in manual registry") else null end,
	
	if $read.contents[0].text != "right" then error("manual resource content mismatch: " + ($read.contents[0].text|tostring)) else null end
' <"${MANUAL_ROOT}/responses.ndjson" >/dev/null

# --- Resource templates contract ---
TEMPLATE_ROOT="${TEST_TMPDIR}/templates"
test_stage_workspace "${TEMPLATE_ROOT}"
# Remove register.sh to mirror auto-discovery baseline
rm -f "${TEMPLATE_ROOT}/server.d/register.sh"

cat <<'JSON' >"${TEMPLATE_ROOT}/requests.ndjson"
{"jsonrpc":"2.0","id":"templates-init","method":"initialize","params":{}}
{"jsonrpc":"2.0","method":"notifications/initialized"}
{"jsonrpc":"2.0","id":"templates-list","method":"resources/templates/list","params":{}}
JSON

(
	cd "${TEMPLATE_ROOT}" || exit 1
	MCPBASH_PROJECT_ROOT="${TEMPLATE_ROOT}" ./bin/mcp-bash <"requests.ndjson" >"responses.ndjson"
)

jq -s '
	def error(msg): error(msg);

	(map(select(.id == "templates-list"))[0].result) as $list |

	if ($list.resourceTemplates | length) != 0 then error("expected empty resourceTemplates") else null end,
	if ($list | has("nextCursor") and ($list.nextCursor | type) != "string") then error("nextCursor must be a string when present") else null end
' <"${TEMPLATE_ROOT}/responses.ndjson" >/dev/null

# --- Subscription updates ---
SUB_ROOT="${TEST_TMPDIR}/subscribe"
test_stage_workspace "${SUB_ROOT}"
# Remove register.sh to force auto-discovery (chmod -x doesn't work on Windows)
rm -f "${SUB_ROOT}/server.d/register.sh"
mkdir -p "${SUB_ROOT}/resources"

echo "  • Subscription workspace: ${SUB_ROOT}"

cat <<EOF_RES >"${SUB_ROOT}/resources/live.txt"
original
EOF_RES

cat <<EOF_META >"${SUB_ROOT}/resources/live.meta.json"
{"name": "file.live", "description": "Live file", "uri": "file://${SUB_ROOT}/resources/live.txt", "mimeType": "text/plain"}
EOF_META

windows_subscription_test() {
	local sub_root="$1"
	local resp_file="${sub_root}/responses.ndjson"

	# Pass 1: subscribe/ping (no streaming notification check on Windows)
	cat <<'EOF' | MCPBASH_PROJECT_ROOT="${sub_root}" ./bin/mcp-bash >"${resp_file}"
{"jsonrpc":"2.0","id":"init","method":"initialize","params":{}}
{"jsonrpc":"2.0","method":"notifications/initialized"}
{"jsonrpc":"2.0","id":"sub","method":"resources/subscribe","params":{"name":"file.live"}}
{"jsonrpc":"2.0","id":"ping","method":"ping"}
EOF

	local sub_ok
	sub_ok="$(jq -r 'select(.id=="sub") | .result // empty' "${resp_file}" || true)"
	if [ -z "${sub_ok}" ]; then
		printf 'Subscription response missing on Windows file-based path\n' >&2
		exit 1
	fi

	local ping_ok
	ping_ok="$(jq -r 'select(.id=="ping") | .result // empty' "${resp_file}" || true)"
	if [ -z "${ping_ok}" ]; then
		printf 'Ping response missing on Windows file-based path\n' >&2
		exit 1
	fi

	# Mutate the file and verify via a second stateless get
	echo "updated" >"${sub_root}/resources/live.txt"

	local live_uri
	live_uri="file://${sub_root}/resources/live.txt"

	# Build requests with proper URI (heredoc must be unquoted for variable expansion)
	# Note: MCP uses resources/read, not resources/get
	cat <<EOF | MCPBASH_PROJECT_ROOT="${sub_root}" ./bin/mcp-bash >"${resp_file}"
{"jsonrpc":"2.0","id":"init","method":"initialize","params":{}}
{"jsonrpc":"2.0","method":"notifications/initialized"}
{"jsonrpc":"2.0","id":"read","method":"resources/read","params":{"uri":"${live_uri}"}}
EOF

	local get_text
	get_text="$(jq -r 'select(.id=="read") | .result.contents[0].text // empty' "${resp_file}" || true)"
	if [ "${get_text}" != "updated" ]; then
		printf 'Updated content not observed on Windows file-based path\n' >&2
		exit 1
	fi
}

run_subscription_test() {
	local sub_root="$1"
	local pipe_in="${sub_root}/pipe_in"
	local pipe_out="${sub_root}/pipe_out"

	rm -f "$pipe_in" "$pipe_out"
	mkfifo "$pipe_in" "$pipe_out"

	(
		cd "$sub_root" || exit 1
		MCPBASH_PROJECT_ROOT="${sub_root}" ./bin/mcp-bash <"$pipe_in" >"$pipe_out" &
		echo $! >"${sub_root}/server.pid"
	)

	local server_pid
	# Wait for pid file
	sleep 1
	server_pid="$(cat "${sub_root}/server.pid")"

	exec 3>"$pipe_in"
	exec 4<"$pipe_out"

	# Send init
	echo '{"jsonrpc":"2.0","id":"init","method":"initialize","params":{}}' >&3

	# Read init (with timeout)
	local init_timeout=10
	while read -t "$init_timeout" -r line <&4; do
		local id
		id="$(echo "$line" | jq -r '.id // empty')"
		if [ "$id" = "init" ]; then
			break
		fi
	done

	echo '{"jsonrpc":"2.0","method":"notifications/initialized"}' >&3

	# Send subscribe
	echo '{"jsonrpc":"2.0","id":"sub","method":"resources/subscribe","params":{"name":"file.live"}}' >&3

	local sub_ok=false
	local sub_timeout=10

	# Wait for subscribe response
	while read -t "$sub_timeout" -r line <&4; do
		local id
		id="$(echo "$line" | jq -r '.id // empty')"
		if [ "$id" = "sub" ]; then
			sub_ok=true
			break
		fi
	done

	if [ "$sub_ok" != true ]; then
		echo "Failed to subscribe" >&2
		kill "$server_pid" 2>/dev/null || true
		exit 1
	fi

	# Trigger update by modifying the file
	echo "updated" >"${sub_root}/resources/live.txt"

	# Send ping to ensure we process events
	echo '{"jsonrpc":"2.0","id":"ping","method":"ping"}' >&3

	local ping_seen=false
	local update_seen=false

	while read -t 5 -r line <&4; do
		local id method
		id="$(echo "$line" | jq -r '.id // empty')"
		method="$(echo "$line" | jq -r '.method // empty')"

		if [ "$id" = "ping" ]; then
			ping_seen=true
		elif [ "$method" = "notifications/resources/updated" ]; then
			if [ "$(echo "$line" | jq -r '.params.resource.contents[0].text // empty')" = "updated" ]; then
				update_seen=true
			fi
		fi

		if [ "$ping_seen" = true ] && [ "$update_seen" = true ]; then
			break
		fi
	done

	if [ "$update_seen" != true ]; then
		echo "Update not seen" >&2
		kill "$server_pid" 2>/dev/null || true
		exit 1
	fi

	echo '{"jsonrpc":"2.0","id":"shutdown","method":"shutdown"}' >&3
	echo '{"jsonrpc":"2.0","id":"exit","method":"exit"}' >&3
	exec 3>&-
	# Drain output with timeout to avoid hanging
	while read -t 2 -r -u 4 _line; do
		:
	done
	exec 4<&-
	wait "$server_pid" 2>/dev/null || true
	# Ensure server is gone; Windows sometimes keeps pipes busy.
	kill "$server_pid" 2>/dev/null || true
	# Retry pipe cleanup without failing the test on Windows "busy" errors.
	for _i in 1 2 3; do
		rm -f "$pipe_in" "$pipe_out" 2>/dev/null && break
		sleep 1
	done
}

if [ "${IS_WINDOWS}" = "true" ]; then
	windows_subscription_test "${SUB_ROOT}"
else
	run_subscription_test "${SUB_ROOT}"
fi
