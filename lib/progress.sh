#!/usr/bin/env bash
# Progress notification helpers for long-running handlers and standalone scripts.
# These helpers mirror the worker environment wiring in lib/core.sh and the
# tool-facing SDK. They can be sourced by custom providers without pulling in
# the full SDK.

set -euo pipefail

if ! command -v mcp_json_quote_text >/dev/null 2>&1; then
	mcp_json_quote_text() {
		local text="${1:-}"
		text="${text//\\/\\\\}"
		text="${text//\"/\\\"}"
		text="${text//$'\n'/\\n}"
		text="${text//$'\r'/\\r}"
		printf '"%s"' "${text}"
	}
fi

mcp_progress_is_configured() {
	[ -n "${MCP_PROGRESS_STREAM:-}" ] && [ -n "${MCP_PROGRESS_TOKEN:-}" ]
}

mcp_progress_emit_notification() {
	local percent="$1"
	local message="$2"
	local total="${3:-}"
	if ! mcp_progress_is_configured; then
		return 0
	fi
	case "${percent}" in
	'' | *[!0-9]*) percent="0" ;;
	*)
		if [ "${percent}" -lt 0 ]; then
			percent=0
		elif [ "${percent}" -gt 100 ]; then
			percent=100
		fi
		;;
	esac
	local token_json message_json
	if printf '%s' "${MCP_PROGRESS_TOKEN}" | LC_ALL=C grep -Eq '^[-+]?[0-9]+(\.[0-9]+)?$'; then
		token_json="${MCP_PROGRESS_TOKEN}"
	else
		token_json="$(mcp_json_quote_text "${MCP_PROGRESS_TOKEN}")"
	fi
	message_json="$(mcp_json_quote_text "${message}")"
	# total is a number when known and absent otherwise (the schema has no null).
	local total_kv=""
	if [ -n "${total}" ] && printf '%s' "${total}" | LC_ALL=C grep -Eq '^[0-9]+$'; then
		total_kv=',"total":'"${total}"
	fi
	printf '{"jsonrpc":"2.0","method":"notifications/progress","params":{"progressToken":%s,"progress":%s%s,"message":%s}}\n' "${token_json}" "${percent}" "${total_kv}" "${message_json}" >>"${MCP_PROGRESS_STREAM}" 2>/dev/null || true
}

mcp_progress_env_help() {
	cat <<'EOF'
mcp-bash progress streaming:
- `MCP_PROGRESS_STREAM` and `MCP_PROGRESS_TOKEN` are injected per-request by lib/core.sh.
- Set `MCPBASH_ENABLE_LIVE_PROGRESS=true` to stream progress logs as they arrive; otherwise they flush after the handler completes.
- Tune flush cadence with `MCPBASH_PROGRESS_FLUSH_INTERVAL` (seconds).
EOF
}
