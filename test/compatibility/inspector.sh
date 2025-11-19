#!/usr/bin/env bash
# Compatibility: sanity-check handshake output expected by Inspector clients.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/mcp-inspector.XXXXXX")"
cleanup() {
	if [ -n "${TMP_ROOT:-}" ] && [ -d "${TMP_ROOT}" ]; then
		rm -rf "${TMP_ROOT}"
	fi
}
trap cleanup EXIT

stage_workspace() {
	local dest="$1"
	mkdir -p "${dest}"
	cp -a "${REPO_ROOT}/bin" "${dest}/"
	cp -a "${REPO_ROOT}/lib" "${dest}/"
	cp -a "${REPO_ROOT}/handlers" "${dest}/"
	cp -a "${REPO_ROOT}/providers" "${dest}/"
	cp -a "${REPO_ROOT}/sdk" "${dest}/"
}

WORKSPACE="${TMP_ROOT}/workspace"
stage_workspace "${WORKSPACE}"
export WORKSPACE

# Bash implementation of inspector test
(
	cd "${WORKSPACE}"
	
	# Use a named pipe or coproc. coproc is bash 4+. 
	# Let's use a simple FIFO approach which works on older bash too if needed, but coproc is cleaner.
	# Assuming bash 4+ since we require bash 3.2+ but macOS bash 3.2 doesn't have coproc.
	# We'll use file descriptors redirect.
	
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
	
	recv() {
		local line
		if read -r line <&4; then
			printf '%s' "${line}"
		else
			return 1
		fi
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
			if [ "${protocol}" != "2025-06-18" ]; then
				echo "unexpected protocolVersion: ${protocol}" >&2
				kill "${PID}"
				exit 1
			fi
			for cap in logging tools resources prompts completion; do
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
	
	rm in_pipe out_pipe
)

