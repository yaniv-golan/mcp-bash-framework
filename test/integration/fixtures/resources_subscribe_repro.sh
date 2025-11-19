#!/usr/bin/env bash
# Resources handler & fixture guidance: minimal subscribe handshake reproducer.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"

TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/mcp-subscribe.XXXXXX")"
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
mkdir -p "${WORKSPACE}/resources"
export WORKSPACE

cat <<EOF >"${WORKSPACE}/resources/live.txt"
original
EOF

cat <<EOF >"${WORKSPACE}/resources/live.meta.json"
{"name": "file.live", "description": "Live file", "uri": "file://${WORKSPACE}/resources/live.txt", "mimeType": "text/plain"}
EOF

printf 'Repro workspace: %s\n' "${WORKSPACE}"
printf 'Enable payload logging via MCPBASH_DEBUG_PAYLOADS=true for stdout traces.\n'

(
	cd "${WORKSPACE}" || exit 1
	
	# Start server
	coproc SERVER { ./bin/mcp-bash; }
	
	# Capture PID
	SERVER_PID="${SERVER_PID}"
	
	send() {
		local payload="$1"
		printf '%s\n' "${payload}" >&"${SERVER[1]}"
		printf '>> %s\n' "${payload}"
	}
	
	read_response() {
		local line
		if read -r -u "${SERVER[0]}" line; then
			printf '<< %s\n' "${line}"
			printf '%s' "${line}"
		else
			return 1
		fi
	}
	
	wait_for() {
		local match_key="$1"
		local match_val="$2"
		local timeout="${3:-5}"
		local end_time=$(( $(date +%s) + timeout ))
		
		while [ "$(date +%s)" -lt "${end_time}" ]; do
			local response
			if ! response="$(read_response)"; then
				return 1
			fi
			if [ -z "${response}" ]; then continue; fi
			
			local val
			val="$(printf '%s' "${response}" | jq -r ".${match_key} // empty")"
			if [ "${val}" = "${match_val}" ]; then
				return 0
			fi
		done
		return 1
	}
	
	send '{"jsonrpc": "2.0", "id": "init", "method": "initialize", "params": {}}'
	wait_for "id" "init" || { printf 'Init timeout\n' >&2; exit 1; }
	
	send '{"jsonrpc": "2.0", "method": "notifications/initialized"}'
	
	send '{"jsonrpc": "2.0", "id": "sub", "method": "resources/subscribe", "params": {"name": "file.live"}}'
	wait_for "id" "sub" || { printf 'Subscribe timeout\n' >&2; exit 1; }
	
	# Expect update notification
	end_time=$(( $(date +%s) + 5 ))
	seen_update=false
	while [ "$(date +%s)" -lt "${end_time}" ]; do
		response="$(read_response)" || break
		if [ -z "${response}" ]; then continue; fi
		
		method="$(printf '%s' "${response}" | jq -r '.method // empty')"
		if [ "${method}" = "notifications/resources/updated" ]; then
			seen_update=true
			break
		fi
	done
	
	if [ "${seen_update}" != "true" ]; then
		printf 'Missing update notification\n' >&2
		kill "${SERVER_PID}" 2>/dev/null || true
		exit 1
	fi
	
	kill "${SERVER_PID}" 2>/dev/null || true
	wait "${SERVER_PID}" 2>/dev/null || true
)
