#!/usr/bin/env bash
# Compatibility: sanity-check handshake output expected by Inspector clients.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../common/env.sh
# shellcheck disable=SC1091
. "${SCRIPT_DIR}/../common/env.sh"
# shellcheck source=../common/assert.sh
# shellcheck disable=SC1091
. "${SCRIPT_DIR}/../common/assert.sh"

test_create_tmpdir
WORKSPACE="${TEST_TMPDIR}/workspace"
test_stage_workspace "${WORKSPACE}"
export WORKSPACE

# Bash implementation of inspector test
(
	cd "${WORKSPACE}"
	# Point project root at the staged workspace so the server can start.
	export MCPBASH_PROJECT_ROOT="${WORKSPACE}"
	# Enable startup logging for this test (disabled by default since b832516)
	export MCPBASH_LOG_STARTUP=true

	# Use FIFOs + file descriptors (Bash 3.2+; avoids coproc which is Bash 4+).

	# Launch server with pipes
	# We'll read from server_out and write to server_in

	# Create FIFOs
	mkfifo in_pipe
	mkfifo out_pipe

	./bin/mcp-bash <in_pipe >out_pipe 2>err_log &
	PID=$!

	# Keep pipe open
	exec 3>in_pipe
	exec 4<out_pipe

	send() {
		printf '%s\n' "$1" >&3
	}

	# init
	send '{"jsonrpc": "2.0", "id": "init", "method": "initialize", "params": {}}'

	# Read until we get init response
	got_init=false
	while read -r line <&4; do
		[ -z "${line}" ] && continue
		id=$(echo "${line}" | jq -r '.id // empty')
		if [ "${id}" = "init" ]; then
			protocol=$(echo "${line}" | jq -r '.result.protocolVersion')
			if [ "${protocol}" != "2025-11-25" ]; then
				echo "unexpected protocolVersion: ${protocol}" >&2
				kill "${PID}"
				exit 1
			fi
			for cap in logging tools resources prompts completions; do
				if ! echo "${line}" | jq -e ".result.capabilities.${cap}" >/dev/null; then
					echo "missing capability ${cap}" >&2
					kill "${PID}"
					exit 1
				fi
			done
			got_init=true
			break
		fi
	done

	if [ "${got_init}" != "true" ]; then
		echo "Failed to get init response" >&2
		kill "${PID}"
		exit 1
	fi

	send '{"jsonrpc": "2.0", "method": "notifications/initialized"}'
	send '{"jsonrpc": "2.0", "id": "shutdown", "method": "shutdown"}'

	got_shutdown=false
	while read -r line <&4; do
		[ -z "${line}" ] && continue
		id=$(echo "${line}" | jq -r '.id // empty')
		if [ "${id}" = "shutdown" ]; then
			res=$(echo "${line}" | jq -r '.result')
			if [ "${res}" != "{}" ]; then
				echo "shutdown acknowledgement missing" >&2
				kill "${PID}"
				exit 1
			fi
			got_shutdown=true
			break
		fi
	done

	if [ "${got_shutdown}" != "true" ]; then
		echo "Failed to get shutdown response" >&2
		kill "${PID}"
		exit 1
	fi

	send '{"jsonrpc": "2.0", "id": "exit", "method": "exit"}'

	# Wait for exit
	wait "${PID}" || true

	if ! grep -q "mcp-bash startup: transport=stdio" err_log 2>/dev/null; then
		echo "missing startup stderr log" >&2
		rm in_pipe out_pipe
		exit 1
	fi

	rm in_pipe out_pipe
)
