#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../common/env.sh
# shellcheck disable=SC1091
. "${SCRIPT_DIR}/../common/env.sh"
# shellcheck source=../common/assert.sh
# shellcheck disable=SC1091
. "${SCRIPT_DIR}/../common/assert.sh"

test_create_tmpdir

echo "Resources integration temp root: ${TEST_TMPDIR}"

stage_workspace() {
	local dest="$1"
	mkdir -p "${dest}"
	cp -a "${MCPBASH_ROOT}/bin" "${dest}/"
	cp -a "${MCPBASH_ROOT}/lib" "${dest}/"
	cp -a "${MCPBASH_ROOT}/handlers" "${dest}/"
	cp -a "${MCPBASH_ROOT}/providers" "${dest}/"
	cp -a "${MCPBASH_ROOT}/sdk" "${dest}/"
	cp -a "${MCPBASH_ROOT}/resources" "${dest}/" 2>/dev/null || true
	cp -a "${MCPBASH_ROOT}/prompts" "${dest}/" 2>/dev/null || true
	cp -a "${MCPBASH_ROOT}/server.d" "${dest}/"
}

# --- Auto-discovery and pagination ---
AUTO_ROOT="${TEST_TMPDIR}/auto"
stage_workspace "${AUTO_ROOT}"
chmod -x "${AUTO_ROOT}/server.d/register.sh"
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
	./bin/mcp-bash <"requests.ndjson" >"responses.ndjson"
)

jq -n --slurpfile messages "${AUTO_ROOT}/responses.ndjson" '
	def error(msg): error(msg);
	
	($messages | map(select(.id == "auto-list"))[0].result) as $list |
	($messages | map(select(.id == "auto-read"))[0].result) as $read |
	
	if $list.total != 2 then error("expected two resources discovered") else null end,
	if ($list | has("nextCursor") | not) then error("nextCursor missing for paginated resources") else null end,
	if ($list.items[0].name | IN("file.alpha", "file.beta") | not) then error("unexpected resource name") else null end,
	
	if $read.mimeType != "text/plain" then error("unexpected mimeType") else null end,
	if $read.content != "alpha" then error("resource content mismatch") else null end
' >/dev/null

# --- Manual registration overrides ---
MANUAL_ROOT="${TEST_TMPDIR}/manual"
stage_workspace "${MANUAL_ROOT}"
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
	./bin/mcp-bash <"requests.ndjson" >"responses.ndjson"
)

jq -n --slurpfile messages "${MANUAL_ROOT}/responses.ndjson" '
	def error(msg): error(msg);
	
	($messages | map(select(.id == "manual-list"))[0].result) as $list |
	($messages | map(select(.id == "manual-read"))[0].result) as $read |
	
	if $list.total != 2 then error("manual registry should contain two resources") else null end,
	if ($list.items[] | .name | IN("manual.left", "manual.right") | not) then error("unexpected resource discovered in manual registry") else null end,
	
	if $read.content != "right" then error("manual resource content mismatch: " + ($read.content|tostring)) else null end
' >/dev/null

# --- Subscription updates ---
SUB_ROOT="${TEST_TMPDIR}/subscribe"
stage_workspace "${SUB_ROOT}"
chmod -x "${SUB_ROOT}/server.d/register.sh"
mkdir -p "${SUB_ROOT}/resources"

echo "  • Subscription workspace: ${SUB_ROOT}"

cat <<EOF_RES >"${SUB_ROOT}/resources/live.txt"
original
EOF_RES

cat <<EOF_META >"${SUB_ROOT}/resources/live.meta.json"
{"name": "file.live", "description": "Live file", "uri": "file://${SUB_ROOT}/resources/live.txt", "mimeType": "text/plain"}
EOF_META

run_subscription_test() {
	local sub_root="$1"
	local pipe_in="${sub_root}/pipe_in"
	local pipe_out="${sub_root}/pipe_out"

	rm -f "$pipe_in" "$pipe_out"
	mkfifo "$pipe_in" "$pipe_out"

	(
		cd "$sub_root" || exit 1
		./bin/mcp-bash <"$pipe_in" >"$pipe_out" &
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

	# Read init
	while read -r line <&4; do
		local id
		id="$(echo "$line" | jq -r '.id // empty')"
		if [ "$id" = "init" ]; then
			break
		fi
	done

	echo '{"jsonrpc":"2.0","method":"notifications/initialized"}' >&3

	# Send subscribe
	echo '{"jsonrpc":"2.0","id":"sub","method":"resources/subscribe","params":{"name":"file.live"}}' >&3

	local sub_id=""
	local initial_content=""

	while read -r line <&4; do
		local id method
		id="$(echo "$line" | jq -r '.id // empty')"
		method="$(echo "$line" | jq -r '.method // empty')"
		if [ "$id" = "sub" ]; then
			sub_id="$(echo "$line" | jq -r '.result.subscriptionId // empty')"
		elif [ "$method" = "notifications/resources/updated" ]; then
			local sid
			sid="$(echo "$line" | jq -r '.params.subscriptionId // empty')"
			if [ "$sid" = "$sub_id" ]; then
				initial_content="$(echo "$line" | jq -r '.params.content // empty')"
				if [ "$initial_content" = "original" ]; then
					break
				fi
			fi
		fi
	done

	if [ -z "$sub_id" ]; then
		echo "Failed to get subscription ID" >&2
		kill "$server_pid" 2>/dev/null || true
		exit 1
	fi

	# Trigger update
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
			local sid
			sid="$(echo "$line" | jq -r '.params.subscriptionId // empty')"
			if [ "$sid" = "$sub_id" ]; then
				local content
				content="$(echo "$line" | jq -r '.params.content // empty')"
				if [ "$content" = "updated" ]; then
					update_seen=true
				fi
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

	wait "$server_pid"
	rm -f "$pipe_in" "$pipe_out"
}

run_subscription_test "${SUB_ROOT}"
