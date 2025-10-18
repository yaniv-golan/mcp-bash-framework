#!/usr/bin/env bash
set -euo pipefail

if [ -z "${MCP_SDK:-}" ] || [ ! -f "${MCP_SDK}/tool-sdk.sh" ]; then
	printf 'mcp: SDK helpers not found (expected $MCP_SDK/tool-sdk.sh)\\n' >&2
	exit 1
fi

# shellcheck source=../../sdk/tool-sdk.sh
. "${MCP_SDK}/tool-sdk.sh"

json_escape() {
	local value="$1"
	if command -v python3 >/dev/null 2>&1; then
		python3 - "$value" <<'PY' 2>/dev/null
import json, sys
print(json.dumps(sys.argv[1]))
PY
		return 0
	fi
	if command -v python >/dev/null 2>&1; then
		python - "$value" <<'PY' 2>/dev/null
import json, sys
print(json.dumps(sys.argv[1]))
PY
		return 0
	fi
	local escaped="${value//\\/\\\\}"
	escaped="${escaped//\"/\\\"}"
	escaped="${escaped//$'\n'/\\n}"
	escaped="${escaped//$'\r'/\\r}"
	printf '"%s"' "${escaped}"
}

name="$(mcp_args_get '.name // empty' 2>/dev/null || true)"
if [ -z "${name}" ]; then
	raw="$(mcp_args_raw)"
	if command -v python3 >/dev/null 2>&1; then
		name="$(printf '%s' "${raw}" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("name",""))' 2>/dev/null || true)"
	elif command -v python >/dev/null 2>&1; then
		name="$(printf '%s' "${raw}" | python -c 'import json,sys; print(json.load(sys.stdin).get("name",""))' 2>/dev/null || true)"
	fi
fi
if [ -z "${name}" ]; then
	name="there"
fi

# Uncomment to demonstrate progress and logging helpers.
# mcp_progress 25 "Preparing response"
# mcp_log info "__NAME__" '{"type":"text","text":"Responding to completion"}'

message_json="$(json_escape "Hello ${name}")"
mcp_emit_json "{\"message\":${message_json}}"
