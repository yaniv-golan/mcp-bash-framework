#!/usr/bin/env bash
# Spec §8 completion handler implementation.

set -euo pipefail

mcp_completion_quote() {
	local text="$1"
	local py
	if py="$(mcp_tools_python 2>/dev/null)"; then
		TEXT="${text}" "${py}" <<'PY'
import json, os
print(json.dumps(os.environ.get("TEXT", "")))
PY
	else
		printf '"%s"' "$(printf '%s' "${text}" | sed 's/\\/\\\\/g; s/"/\\"/g')"
	fi
}

mcp_handle_completion() {
	local method="$1"
	local json_payload="$2"
	local id
	if ! id="$(mcp_json_extract_id "${json_payload}")"; then
		id="null"
	fi

	if mcp_runtime_is_minimal_mode; then
		local message
		message=$(mcp_completion_quote "Completion capability unavailable in minimal mode")
		printf '{"jsonrpc":"2.0","id":%s,"error":{"code":-32601,"message":%s}}' "${id}" "${message}"
		return 0
	fi

	case "${method}" in
	completion/complete)
		local name
		name="$(mcp_json_extract_completion_name "${json_payload}")"
		if [ -z "${name}" ]; then
			local message
			message=$(mcp_completion_quote "Completion name is required")
			printf '{"jsonrpc":"2.0","id":%s,"error":{"code":-32602,"message":%s}}' "${id}" "${message}"
			return 0
		fi
		mcp_completion_reset
		local limit
		limit="$(mcp_json_extract_limit "${json_payload}")"
		case "${limit}" in
		'' | *[!0-9]*) limit=5 ;;
		0) limit=5 ;;
		esac
		if [ "${limit}" -gt 100 ]; then
			limit=100
		fi
		local args_json
		args_json="$(mcp_json_extract_completion_arguments "${json_payload}")"
		local py
		py="$(mcp_tools_python 2>/dev/null || true)"
		if [ -z "${py}" ]; then
			local message
			message=$(mcp_completion_quote "Completion requires JSON tooling")
			printf '{"jsonrpc":"2.0","id":%s,"error":{"code":-32603,"message":%s}}' "${id}" "${message}"
			return 0
		fi
		local cursor start_offset
		cursor="$(mcp_json_extract_cursor "${json_payload}")"
		start_offset=0
		if [ -n "${cursor}" ]; then
			start_offset="$(
				env CURSOR_VALUE="${cursor}" "${py}" <<'PY'
import base64, json, os
try:
    padding = '=' * (-len(os.environ["CURSOR_VALUE"]) % 4)
    data = json.loads(base64.urlsafe_b64decode(os.environ["CURSOR_VALUE"] + padding).decode('utf-8'))
    print(int(data.get("next", 0)))
except Exception:
    print("0")
PY
			)"
		fi
		local prepared limited_json has_more_flag next_index
		prepared="$(
			env NAME="${name}" ARGS_JSON="${args_json}" LIMIT="${limit}" START="${start_offset}" "${py}" <<'PY'
import json, os
name = os.environ.get("NAME", "")
args = json.loads(os.environ.get("ARGS_JSON", "{}"))
limit = int(os.environ.get("LIMIT", "5") or 5)
limit = max(1, min(limit, 100))
start = int(os.environ.get("START", "0") or 0)
start = max(0, start)
query = (args.get("query") or args.get("prefix") or "").strip()
base = query or name.strip() or "suggestion"
candidates = [
    {"type": "text", "text": base},
    {"type": "text", "text": f"{base} snippet"},
    {"type": "text", "text": f"{base} example"}
]
limited = candidates[start:start + limit]
has_more = start + limit < len(candidates)
next_index = start + limit if has_more else None
print(json.dumps({"limited": limited, "hasMore": has_more, "next": next_index}, ensure_ascii=False, separators=(',', ':')))
PY
		)"
		limited_json="$(
			env PREPARED="${prepared}" "${py}" <<'PY'
import json, os
data = json.loads(os.environ["PREPARED"])
print(json.dumps(data.get("limited", []), ensure_ascii=False, separators=(',', ':')))
PY
		)"
		has_more_flag="$(
			env PREPARED="${prepared}" "${py}" <<'PY'
import json, os
data = json.loads(os.environ["PREPARED"])
print("true" if data.get("hasMore") else "false")
PY
		)"
		next_index="$(
			env PREPARED="${prepared}" "${py}" <<'PY'
import json, os
data = json.loads(os.environ["PREPARED"])
value = data.get("next")
print("" if value is None else str(value))
PY
		)"
		if [ "${has_more_flag}" = "true" ]; then
			# shellcheck disable=SC2034
			mcp_completion_has_more=true
			if [ -n "${next_index}" ]; then
				mcp_completion_cursor="$(
					env NAME="${name}" NEXT="${next_index}" ARGS_JSON="${args_json}" "${py}" <<'PY'
import base64, json, os
payload = json.dumps({
    "name": os.environ.get("NAME"),
    "next": int(os.environ.get("NEXT", "0")),
    "args": json.loads(os.environ.get("ARGS_JSON", "{}"))
}, separators=(',', ':')).encode('utf-8')
print(base64.urlsafe_b64encode(payload).decode('utf-8').rstrip('='))
PY
				)"
			fi
		fi
		local added=0
		while IFS= read -r suggestion; do
			[ -z "${suggestion}" ] && continue
			if ! mcp_completion_add_json "${suggestion}"; then
				# shellcheck disable=SC2034
				mcp_completion_has_more=true
				if [ -z "${mcp_completion_cursor}" ]; then
					local next_offset
					next_offset=$((start_offset + added))
					mcp_completion_cursor="$(
						env NAME="${name}" NEXT="${next_offset}" ARGS_JSON="${args_json}" "${py}" <<'PY'
import base64, json, os
payload = json.dumps({
    "name": os.environ.get("NAME"),
    "next": int(os.environ.get("NEXT", "0")),
    "args": json.loads(os.environ.get("ARGS_JSON", "{}"))
}, separators=(',', ':')).encode('utf-8')
print(base64.urlsafe_b64encode(payload).decode('utf-8').rstrip('='))
PY
					)"
				fi
				break
			fi
			added=$((added + 1))
		done < <(
			env PAYLOAD="${limited_json}" "${py}" <<'PY'
import json, os
items = json.loads(os.environ.get("PAYLOAD", "[]"))
for item in items:
    print(json.dumps(item, separators=(',', ':')))
PY
		)
		local result_json
		result_json="$(mcp_completion_finalize)"
		printf '{"jsonrpc":"2.0","id":%s,"result":%s}' "${id}" "${result_json}"
		;;
	*)
		local message
		message=$(mcp_completion_quote "Unknown completion method")
		printf '{"jsonrpc":"2.0","id":%s,"error":{"code":-32601,"message":%s}}' "${id}" "${message}"
		;;
	esac
}
