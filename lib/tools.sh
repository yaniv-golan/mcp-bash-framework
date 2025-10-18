#!/usr/bin/env bash
# Spec §8/§9/§11: tool discovery, registry generation, invocation helpers.

set -euo pipefail

MCP_TOOLS_REGISTRY_JSON=""
MCP_TOOLS_REGISTRY_HASH=""
MCP_TOOLS_REGISTRY_PATH=""
# shellcheck disable=SC2034
MCP_TOOLS_TOTAL=0
# shellcheck disable=SC2034
MCP_TOOLS_ERROR_CODE=0
# shellcheck disable=SC2034
MCP_TOOLS_ERROR_MESSAGE=""
MCP_TOOLS_TTL="${MCP_TOOLS_TTL:-5}"
MCP_TOOLS_LAST_SCAN=0
MCP_TOOLS_CHANGED=false
MCP_TOOLS_MANUAL_ACTIVE=false
MCP_TOOLS_MANUAL_BUFFER=""
MCP_TOOLS_MANUAL_DELIM=$'\036'
MCP_TOOLS_LOGGER="${MCP_TOOLS_LOGGER:-mcp.tools}"

mcp_tools_manual_begin() {
	MCP_TOOLS_MANUAL_ACTIVE=true
	MCP_TOOLS_MANUAL_BUFFER=""
}

mcp_tools_manual_abort() {
	MCP_TOOLS_MANUAL_ACTIVE=false
	MCP_TOOLS_MANUAL_BUFFER=""
}

mcp_tools_register_manual() {
	local payload="$1"
	if [ "${MCP_TOOLS_MANUAL_ACTIVE}" != "true" ]; then
		return 0
	fi
	if [ -z "${payload}" ]; then
		return 0
	fi
	if [ -n "${MCP_TOOLS_MANUAL_BUFFER}" ]; then
		MCP_TOOLS_MANUAL_BUFFER="${MCP_TOOLS_MANUAL_BUFFER}${MCP_TOOLS_MANUAL_DELIM}${payload}"
	else
		MCP_TOOLS_MANUAL_BUFFER="${payload}"
	fi
	return 0
}

mcp_tools_manual_finalize() {
	if [ "${MCP_TOOLS_MANUAL_ACTIVE}" != "true" ]; then
		return 0
	fi
	local py
	py="$(mcp_tools_python)" || {
		mcp_tools_manual_abort
		mcp_tools_error -32603 "Manual registration requires python"
		return 1
	}

	local registry_json
	if ! registry_json="$(
		ITEMS="${MCP_TOOLS_MANUAL_BUFFER}" ROOT="${MCPBASH_ROOT}" DELIM="${MCP_TOOLS_MANUAL_DELIM}" "${py}" <<'PY'
import json, os, hashlib, time, pathlib

def normalize_path(entry_path, root):
    if not entry_path:
        raise ValueError("Tool entry missing path")
    path_obj = pathlib.Path(entry_path)
    root_path = pathlib.Path(root).resolve()
    if path_obj.is_absolute():
        resolved = path_obj.resolve()
        try:
            resolved.relative_to(root_path)
        except ValueError:
            raise ValueError(f"Tool path {entry_path!r} must be inside server root")
        rel = resolved.relative_to(root_path)
    else:
        rel = (root_path / entry_path).resolve()
        try:
            rel.relative_to(root_path)
        except ValueError:
            raise ValueError(f"Tool path {entry_path!r} must not escape server root")
        rel = rel.relative_to(root_path)
    return str(rel).replace("\\", "/")

buffer = os.environ.get("ITEMS", "")
delimiter = os.environ.get("DELIM", "\x1e")
root = os.environ.get("ROOT", "")
if delimiter:
    raw_entries = [entry for entry in buffer.split(delimiter) if entry]
else:
    raw_entries = [buffer] if buffer else []
items = []
seen = set()
for raw in raw_entries:
    data = json.loads(raw)
    name = str(data.get("name") or "").strip()
    if not name:
        raise ValueError("Tool entry missing name")
    if name in seen:
        raise ValueError(f"Duplicate tool name {name!r} in manual registration")
    seen.add(name)
    description = str(data.get("description") or "")
    path = normalize_path(str(data.get("path") or ""), root)
    entry = dict(data)
    entry["name"] = name
    entry["description"] = description
    entry["path"] = path
    arguments = entry.get("arguments")
    if not isinstance(arguments, dict):
        entry["arguments"] = {"type": "object", "properties": {}}
    timeout = entry.get("timeoutSecs")
    if timeout is not None:
        try:
            entry["timeoutSecs"] = int(timeout)
        except Exception:
            entry.pop("timeoutSecs", None)
    items.append(entry)

items.sort(key=lambda x: x.get("name", ""))

hash_source = json.dumps(items, ensure_ascii=False, sort_keys=True, separators=(',', ':'))
hash_value = hashlib.sha256(hash_source.encode('utf-8')).hexdigest()
registry = {
    "version": 1,
    "generatedAt": time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime()),
    "items": items,
    "hash": hash_value,
    "total": len(items)
}
print(json.dumps(registry, ensure_ascii=False, separators=(',', ':')))
PY
	)"; then
		mcp_tools_manual_abort
		mcp_tools_error -32603 "Manual registration parsing failed"
		return 1
	fi

	local previous_hash="${MCP_TOOLS_REGISTRY_HASH}"
	MCP_TOOLS_REGISTRY_JSON="${registry_json}"
	MCP_TOOLS_REGISTRY_HASH="$(
		REGISTRY_JSON="${registry_json}" "${py}" <<'PY'
import json, os
print(json.loads(os.environ.get("REGISTRY_JSON", "{}")).get('hash', ''))
PY
	)"
	MCP_TOOLS_TOTAL="$(
		REGISTRY_JSON="${registry_json}" "${py}" <<'PY'
import json, os
print(json.loads(os.environ.get("REGISTRY_JSON", "{}")).get('total', 0))
PY
	)"

	if ! mcp_tools_enforce_registry_limits "${MCP_TOOLS_TOTAL}" "${registry_json}"; then
		mcp_tools_manual_abort
		return 1
	fi

	MCP_TOOLS_MANUAL_ACTIVE=false
	MCP_TOOLS_MANUAL_BUFFER=""

	MCP_TOOLS_LAST_SCAN="$(date +%s)"
	if [ "${previous_hash}" != "${MCP_TOOLS_REGISTRY_HASH}" ]; then
		MCP_TOOLS_CHANGED=true
	fi
	printf '%s' "${registry_json}" >"${MCP_TOOLS_REGISTRY_PATH}"
	return 0
}

mcp_tools_registry_max_bytes() {
	local limit="${MCPBASH_REGISTRY_MAX_BYTES:-104857600}"
	case "${limit}" in
	'' | *[!0-9]*) limit=104857600 ;;
	esac
	printf '%s' "${limit}"
}

mcp_tools_enforce_registry_limits() {
	local total="$1"
	local json_payload="$2"
	local limit
	local size
	limit="$(mcp_tools_registry_max_bytes)"
	size="$(LC_ALL=C printf '%s' "${json_payload}" | wc -c | tr -d ' ')"
	if [ "${size}" -gt "${limit}" ]; then
		mcp_tools_error -32603 "Tool registry exceeds ${limit} byte cap"
		return 1
	fi
	if [ "${total}" -gt 500 ]; then
		mcp_logging_warning "${MCP_TOOLS_LOGGER}" "Tools registry contains ${total} entries; consider manual registration"
	fi
	return 0
}

mcp_tools_error() {
	MCP_TOOLS_ERROR_CODE="$1"
	MCP_TOOLS_ERROR_MESSAGE="$2"
}

mcp_tools_python() {
	if command -v python3 >/dev/null 2>&1; then
		printf 'python3'
		return 0
	fi
	if command -v python >/dev/null 2>&1; then
		printf 'python'
		return 0
	fi
	return 1
}

mcp_tools_init() {
	if [ -z "${MCP_TOOLS_REGISTRY_PATH}" ]; then
		MCP_TOOLS_REGISTRY_PATH="${MCPBASH_REGISTRY_DIR}/tools.json"
	fi
	mkdir -p "${MCPBASH_REGISTRY_DIR}"
}

mcp_tools_apply_manual_json() {
	local manual_json="$1"
	local py
	py="$(mcp_tools_python)" || {
		mcp_tools_error -32603 "Manual registration requires python"
		return 1
	}
	local registry_json
	if ! registry_json="$(
		INPUT="${manual_json}" "${py}" <<'PY'
import json, os, sys, hashlib, time
data = json.loads(os.environ.get("INPUT", "{}"))
tools = data.get("tools", [])
if not isinstance(tools, list):
    tools = []
now = time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime())
hash_source = json.dumps(tools, ensure_ascii=False, sort_keys=True, separators=(',', ':'))
hash_value = hashlib.sha256(hash_source.encode('utf-8')).hexdigest()
registry = {
    "version": 1,
    "generatedAt": now,
    "items": tools,
    "hash": hash_value,
    "total": len(tools)
}
print(json.dumps(registry, ensure_ascii=False, separators=(',', ':')))
PY
	)"; then
		return 1
	fi
	local new_hash
	new_hash="$(
		REGISTRY_JSON="${registry_json}" "${py}" <<'PY'
import json, os
print(json.loads(os.environ.get("REGISTRY_JSON", "{}")).get('hash', ''))
PY
	)"
	if [ "${new_hash}" != "${MCP_TOOLS_REGISTRY_HASH}" ]; then
		MCP_TOOLS_CHANGED=true
	fi
	MCP_TOOLS_REGISTRY_JSON="${registry_json}"
	MCP_TOOLS_REGISTRY_HASH="${new_hash}"
	# shellcheck disable=SC2034
	MCP_TOOLS_TOTAL="$(
		REGISTRY_JSON="${registry_json}" "${py}" <<'PY'
import json, os
print(json.loads(os.environ.get("REGISTRY_JSON", "{}")).get('total', 0))
PY
	)"
	if ! mcp_tools_enforce_registry_limits "${MCP_TOOLS_TOTAL}" "${registry_json}"; then
		return 1
	fi
	MCP_TOOLS_LAST_SCAN="$(date +%s)"
	printf '%s' "${registry_json}" >"${MCP_TOOLS_REGISTRY_PATH}"
}

mcp_tools_run_manual_script() {
	if [ ! -x "${MCPBASH_REGISTER_SCRIPT}" ]; then
		return 1
	fi

	mcp_tools_manual_begin

	local script_output_file
	script_output_file="$(mktemp "${MCPBASH_TMP_ROOT}/mcp-tools-manual-output.XXXXXX")"
	local script_status=0

	set +e
	# shellcheck disable=SC1090
	. "${MCPBASH_REGISTER_SCRIPT}" >"${script_output_file}" 2>&1
	script_status=$?
	set -e

	local script_output
	script_output="$(cat "${script_output_file}" 2>/dev/null || true)"
	rm -f "${script_output_file}"

	if [ "${script_status}" -ne 0 ]; then
		mcp_tools_manual_abort
		mcp_tools_error -32603 "Manual registration script failed"
		if [ -n "${script_output}" ]; then
			mcp_logging_error "${MCP_TOOLS_LOGGER}" "Manual registration script output: ${script_output}"
		fi
		return 1
	fi

	if [ -z "${MCP_TOOLS_MANUAL_BUFFER}" ] && [ -n "${script_output}" ]; then
		mcp_tools_manual_abort
		if ! mcp_tools_apply_manual_json "${script_output}"; then
			return 1
		fi
		return 0
	fi

	if [ -n "${script_output}" ]; then
		mcp_logging_warning "${MCP_TOOLS_LOGGER}" "Manual registration script output: ${script_output}"
	fi

	if ! mcp_tools_manual_finalize; then
		return 1
	fi
	return 0
}

mcp_tools_refresh_registry() {
	mcp_tools_init
	if [ -x "${MCPBASH_REGISTER_SCRIPT}" ]; then
		if mcp_tools_run_manual_script; then
			return 0
		fi
		return 1
	fi
	local now
	now="$(date +%s)"
	local py
	py="$(mcp_tools_python 2>/dev/null)" || true
	if [ -z "${MCP_TOOLS_REGISTRY_JSON}" ] && [ -f "${MCP_TOOLS_REGISTRY_PATH}" ]; then
		MCP_TOOLS_REGISTRY_JSON="$(cat "${MCP_TOOLS_REGISTRY_PATH}")"
		if [ -n "${py}" ]; then
			MCP_TOOLS_REGISTRY_HASH="$(
				REGISTRY_JSON="${MCP_TOOLS_REGISTRY_JSON}" "${py}" <<'PY'
import json, os
print(json.loads(os.environ.get("REGISTRY_JSON", "{}")).get('hash', ''))
PY
			)"
			MCP_TOOLS_TOTAL="$(
				REGISTRY_JSON="${MCP_TOOLS_REGISTRY_JSON}" "${py}" <<'PY'
import json, os
print(json.loads(os.environ.get("REGISTRY_JSON", "{}")).get('total', 0))
PY
			)"
			if ! mcp_tools_enforce_registry_limits "${MCP_TOOLS_TOTAL}" "${MCP_TOOLS_REGISTRY_JSON}"; then
				return 1
			fi
		fi
	fi
	if [ -n "${MCP_TOOLS_REGISTRY_JSON}" ] && [ $((now - MCP_TOOLS_LAST_SCAN)) -lt "${MCP_TOOLS_TTL}" ]; then
		return 0
	fi
	local previous_hash="${MCP_TOOLS_REGISTRY_HASH}"
	mcp_tools_scan || return 1
	MCP_TOOLS_LAST_SCAN="${now}"
	if [ "${previous_hash}" != "${MCP_TOOLS_REGISTRY_HASH}" ]; then
		MCP_TOOLS_CHANGED=true
	fi
}

mcp_tools_scan() {
	local py
	py="$(mcp_tools_python)" || {
		MCP_TOOLS_REGISTRY_JSON='{"version":1,"generatedAt":"'$(date -u +%Y-%m-%dT%H:%M:%SZ)'","items":[],"hash":"","total":0}'
		MCP_TOOLS_REGISTRY_HASH=""
		MCP_TOOLS_TOTAL=0
		printf '%s' "${MCP_TOOLS_REGISTRY_JSON}" >"${MCP_TOOLS_REGISTRY_PATH}"
		return 0
	}

	local registry_json
	registry_json="$(
		ROOT="${MCPBASH_ROOT}" TOOLS_DIR="${MCPBASH_TOOLS_DIR}" "${py}" <<'PY'
import os, json, sys, hashlib, time
root = os.environ["ROOT"]
tools_dir = os.environ["TOOLS_DIR"]
items = []
if os.path.isdir(tools_dir):
    for dirpath, dirnames, filenames in os.walk(tools_dir):
        dirnames[:] = [d for d in dirnames if not d.startswith('.')]
        rel_depth = os.path.relpath(dirpath, tools_dir)
        if rel_depth != '.' and rel_depth.count(os.sep) >= 3:
            dirnames[:] = []
            continue
        for filename in filenames:
            if filename.startswith('.'):
                continue
            path = os.path.join(dirpath, filename)
            if not os.access(path, os.X_OK):
                continue
            rel = os.path.relpath(path, root)
            base = os.path.splitext(os.path.basename(path))[0]
            meta = {}
            meta_path = os.path.join(dirpath, f"{base}.meta.yaml")
            text = None
            if os.path.isfile(meta_path):
                try:
                    with open(meta_path, 'r', encoding='utf-8') as fh:
                        text = fh.read()
                except Exception:
                    text = None
            if text:
                parsed = None
                try:
                    parsed = json.loads(text)
                except Exception:
                    try:
                        import yaml  # type: ignore
                    except Exception:
                        parsed = None
                    else:
                        try:
                            parsed = yaml.safe_load(text)
                        except Exception:
                            parsed = None
                if isinstance(parsed, dict):
                    meta = parsed
            if not meta:
                try:
                    with open(path, 'r', encoding='utf-8', errors='ignore') as fh:
                        for _ in range(8):
                            line = fh.readline()
                            if not line:
                                break
                            if line.lstrip().startswith('#'):
                                marker = line.lstrip()[1:].strip()
                                if marker.startswith('mcp:'):
                                    payload = marker[4:].strip()
                                    try:
                                        meta = json.loads(payload)
                                    except Exception:
                                        meta = {}
                                    break
                except Exception:
                    meta = {}
            name = str(meta.get('name') or base)
            description = meta.get('description') or ''
            arguments = meta.get('arguments') or {"type": "object", "properties": {}}
            output_schema = meta.get('outputSchema')
            timeout_secs = meta.get('timeoutSecs')
            item = {
                "name": name,
                "description": description,
                "path": rel,
                "arguments": arguments,
            }
            if output_schema is not None:
                item["outputSchema"] = output_schema
            if timeout_secs is not None:
                try:
                    item["timeoutSecs"] = int(timeout_secs)
                except Exception:
                    pass
            items.append(item)
items.sort(key=lambda x: x["name"])
hash_source = json.dumps(items, ensure_ascii=False, sort_keys=True, separators=(',', ':'))
hash_value = hashlib.sha256(hash_source.encode('utf-8')).hexdigest()
registry = {
    "version": 1,
    "generatedAt": time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime()),
    "items": items,
    "hash": hash_value,
    "total": len(items)
}
print(json.dumps(registry, ensure_ascii=False, separators=(',', ':')))
PY
	)"

	MCP_TOOLS_REGISTRY_JSON="${registry_json}"
	MCP_TOOLS_REGISTRY_HASH="$(
		REGISTRY_JSON="${registry_json}" "${py}" <<'PY'
import json, os
print(json.loads(os.environ.get("REGISTRY_JSON", "{}")).get('hash', ''))
PY
	)"
	# shellcheck disable=SC2034
	MCP_TOOLS_TOTAL="$(
		REGISTRY_JSON="${registry_json}" "${py}" <<'PY'
import json, os
print(json.loads(os.environ.get("REGISTRY_JSON", "{}")).get('total', 0))
PY
	)"
	if ! mcp_tools_enforce_registry_limits "${MCP_TOOLS_TOTAL}" "${registry_json}"; then
		return 1
	fi

	printf '%s' "${registry_json}" >"${MCP_TOOLS_REGISTRY_PATH}"
}

mcp_tools_consume_notification() {
	if [ "${MCP_TOOLS_CHANGED}" = true ]; then
		MCP_TOOLS_CHANGED=false
		printf '{"jsonrpc":"2.0","method":"notifications/tools/list_changed","params":{}}'
	else
		printf ''
	fi
}

mcp_tools_poll() {
	if mcp_runtime_is_minimal_mode; then
		return 0
	fi
	local ttl="${MCP_TOOLS_TTL:-5}"
	case "${ttl}" in
	'' | *[!0-9]*) ttl=5 ;;
	esac
	local now
	now="$(date +%s)"
	if [ "${MCP_TOOLS_LAST_SCAN}" -eq 0 ] || [ $((now - MCP_TOOLS_LAST_SCAN)) -ge "${ttl}" ]; then
		mcp_tools_refresh_registry || true
	fi
	return 0
}

mcp_tools_decode_cursor() {
	local cursor="$1"
	local hash="$2"
	local offset
	if ! offset="$(mcp_paginate_decode "${cursor}" "tools" "${hash}")"; then
		return 1
	fi
	printf '%s' "${offset}"
}

mcp_tools_list() {
	local limit="$1"
	local cursor="$2"
	# shellcheck disable=SC2034
	MCP_TOOLS_ERROR_CODE=0
	# shellcheck disable=SC2034
	MCP_TOOLS_ERROR_MESSAGE=""

	mcp_tools_refresh_registry || {
		mcp_tools_error -32603 "Unable to load tool registry"
		return 1
	}

	local py
	if ! py="$(mcp_tools_python)"; then
		mcp_tools_error -32603 "Python interpreter required for tool listing"
		return 1
	fi

	local numeric_limit
	if [ -z "${limit}" ]; then
		numeric_limit=50
	else
		case "${limit}" in
		'' | *[!0-9]*) numeric_limit=50 ;;
		0) numeric_limit=50 ;;
		*) numeric_limit="${limit}" ;;
		esac
	fi
	if [ "${numeric_limit}" -gt 200 ]; then
		numeric_limit=200
	fi

	local offset=0
	if [ -n "${cursor}" ]; then
		if ! offset="$(mcp_tools_decode_cursor "${cursor}" "${MCP_TOOLS_REGISTRY_HASH}")"; then
			mcp_tools_error -32602 "Invalid cursor"
			return 1
		fi
	fi

	local result_json
	if ! result_json="$(
		REGISTRY="${MCP_TOOLS_REGISTRY_JSON}" OFFSET="${offset}" LIMIT="${numeric_limit}" PYTHONIOENCODING="utf-8" "${py}" <<'PY'
import json, os, base64, sys
registry = json.loads(os.environ["REGISTRY"])
items = registry.get("items", [])
offset = int(os.environ["OFFSET"])
limit = int(os.environ["LIMIT"])
slice_items = items[offset:offset + limit]
result = {"items": slice_items, "total": len(items)}
if offset + limit < len(items):
    payload = json.dumps({"ver": 1, "collection": "tools", "offset": offset + limit, "hash": registry.get("hash", ""), "timestamp": registry.get("generatedAt")}, separators=(',', ':'))
    encoded = base64.urlsafe_b64encode(payload.encode('utf-8')).decode('utf-8').rstrip('=')
    result["nextCursor"] = encoded
print(json.dumps(result, ensure_ascii=False, separators=(',', ':')))
PY
	)"; then
		mcp_tools_error -32603 "Unable to paginate tools"
		return 1
	fi

	printf '%s' "${result_json}"
}

mcp_tools_metadata_for_name() {
	local name="$1"
	mcp_tools_refresh_registry || return 1
	local py
	py="$(mcp_tools_python)" || return 1
	local metadata
	if ! metadata="$(
		REGISTRY="${MCP_TOOLS_REGISTRY_JSON}" TARGET="${name}" "${py}" <<'PY'
import json, os, sys
registry = json.loads(os.environ["REGISTRY"])
target = os.environ["TARGET"]
for item in registry.get("items", []):
    if item.get("name") == target:
        print(json.dumps(item, ensure_ascii=False, separators=(',', ':')))
        sys.exit(0)
sys.exit(1)
PY
	)"; then
		return 1
	fi

	printf '%s' "${metadata}"
}

mcp_tools_call() {
	local name="$1"
	local args_json="$2"
	local timeout_override="$3"
	# shellcheck disable=SC2034
	MCP_TOOLS_ERROR_CODE=0
	# shellcheck disable=SC2034
	MCP_TOOLS_ERROR_MESSAGE=""

	local metadata
	if ! metadata="$(mcp_tools_metadata_for_name "${name}")"; then
		mcp_tools_error -32601 "Tool not found"
		return 1
	fi

	local py
	if ! py="$(mcp_tools_python)"; then
		mcp_tools_error -32603 "Python interpreter required for tool execution"
		return 1
	fi

	local info_json
	if ! info_json="$(
		TOOL_METADATA="${metadata}" "${py}" <<'PY'
import json, os
metadata = json.loads(os.environ["TOOL_METADATA"])
print(json.dumps({
    "path": metadata.get("path"),
    "outputSchema": metadata.get("outputSchema"),
    "timeoutSecs": metadata.get("timeoutSecs")
}, ensure_ascii=False, separators=(',', ':')))
PY
	)"; then
		mcp_tools_error -32603 "Unable to prepare tool metadata"
		return 1
	fi

	local tool_path
	tool_path="$(
		INFO="${info_json}" "${py}" <<'PY'
import json, os
info = json.loads(os.environ["INFO"])
print(info.get("path") or "")
PY
	)"

	if [ -z "${tool_path}" ]; then
		mcp_tools_error -32601 "Tool path unavailable"
		return 1
	fi

	local absolute_path="${MCPBASH_ROOT}/${tool_path}"
	if [ ! -x "${absolute_path}" ]; then
		mcp_tools_error -32601 "Tool executable missing"
		return 1
	fi

	local metadata_timeout
	metadata_timeout="$(
		INFO="${info_json}" "${py}" <<'PY'
import json, os
info = json.loads(os.environ["INFO"])
value = info.get("timeoutSecs")
print("" if value is None else str(int(value)))
PY
	)"

	local output_schema
	output_schema="$(
		INFO="${info_json}" "${py}" <<'PY'
import json, os
info = json.loads(os.environ["INFO"])
value = info.get("outputSchema")
print("" if value is None else json.dumps(value, ensure_ascii=False, separators=(',', ':')))
PY
	)"

	local effective_timeout="${timeout_override}"
	if [ -z "${effective_timeout}" ] && [ -n "${metadata_timeout}" ]; then
		effective_timeout="${metadata_timeout}"
	fi

	local stdout_file stderr_file
	stdout_file="$(mktemp "${MCPBASH_TMP_ROOT}/mcp-tools-stdout.XXXXXX")"
	stderr_file="$(mktemp "${MCPBASH_TMP_ROOT}/mcp-tools-stderr.XXXXXX")"

	local has_json_tool="false"
	if [ "${MCPBASH_MODE}" != "minimal" ] && [ "${MCPBASH_JSON_TOOL}" != "none" ]; then
		has_json_tool="true"
	fi

	local exit_code
	(
		cd "${MCPBASH_ROOT}" || exit 1
		MCP_SDK="${MCPBASH_ROOT}/sdk"
		MCP_TOOL_NAME="${name}"
		MCP_TOOL_PATH="${absolute_path}"
		MCP_TOOL_ARGS_JSON="${args_json}"
		MCP_TOOL_METADATA_JSON="${metadata}"
		export MCP_SDK MCP_TOOL_NAME MCP_TOOL_PATH MCP_TOOL_ARGS_JSON MCP_TOOL_METADATA_JSON
		if [ -n "${effective_timeout}" ]; then
			with_timeout "${effective_timeout}" -- "${absolute_path}"
		else
			"${absolute_path}"
		fi
	) >"${stdout_file}" 2>"${stderr_file}" || exit_code=$?
	exit_code=${exit_code:-0}

	local stdout_content
	stdout_content="$(cat "${stdout_file}")"
	local stderr_content
	stderr_content="$(cat "${stderr_file}")"
	rm -f "${stdout_file}" "${stderr_file}"

	local result_json
	if ! result_json="$(
		TOOL_STDOUT="${stdout_content}" TOOL_STDERR="${stderr_content}" TOOL_METADATA="${metadata}" TOOL_ARGS_JSON="${args_json}" TOOL_NAME="${name}" OUTPUT_SCHEMA="${output_schema}" EXIT_CODE="${exit_code}" HAS_JSON_TOOL="${has_json_tool}" "${py}" <<'PY'
import json, os, math, re

def is_number(value):
    return isinstance(value, (int, float)) and not isinstance(value, bool) and not math.isnan(value) and not math.isinf(value)

def type_matches(expected, value):
    if isinstance(expected, list):
        return any(type_matches(item, value) for item in expected)
    if expected == "object":
        return isinstance(value, dict)
    if expected == "array":
        return isinstance(value, list)
    if expected == "string":
        return isinstance(value, str)
    if expected == "number":
        return is_number(value)
    if expected == "integer":
        return isinstance(value, int) and not isinstance(value, bool)
    if expected == "boolean":
        return isinstance(value, bool)
    if expected == "null":
        return value is None
    return True

def validate_numeric(schema, value, path, errors):
    exclusive_min = schema.get("exclusiveMinimum")
    exclusive_max = schema.get("exclusiveMaximum")
    minimum = schema.get("minimum")
    maximum = schema.get("maximum")
    multiple_of = schema.get("multipleOf")
    if minimum is not None and value < minimum:
        errors.append(f"{path}: value {value} < minimum {minimum}")
    if maximum is not None and value > maximum:
        errors.append(f"{path}: value {value} > maximum {maximum}")
    if exclusive_min is not None and value <= exclusive_min:
        errors.append(f"{path}: value {value} <= exclusiveMinimum {exclusive_min}")
    if exclusive_max is not None and value >= exclusive_max:
        errors.append(f"{path}: value {value} >= exclusiveMaximum {exclusive_max}")
    if multiple_of is not None:
        try:
            if multiple_of == 0 or not math.isclose((value / multiple_of) % 1, 0, rel_tol=1e-9, abs_tol=1e-9):
                errors.append(f"{path}: value {value} not multiple of {multiple_of}")
        except Exception:
            errors.append(f"{path}: unable to evaluate multipleOf {multiple_of}")

def validate_string(schema, value, path, errors):
    min_length = schema.get("minLength")
    max_length = schema.get("maxLength")
    pattern = schema.get("pattern")
    if min_length is not None and len(value) < min_length:
        errors.append(f"{path}: string shorter than minLength {min_length}")
    if max_length is not None and len(value) > max_length:
        errors.append(f"{path}: string longer than maxLength {max_length}")
    if pattern is not None:
        try:
            if re.search(pattern, value) is None:
                errors.append(f"{path}: string does not match pattern {pattern!r}")
        except re.error as exc:
            errors.append(f"{path}: invalid pattern {pattern!r}: {exc}")

def validate_array(schema, value, path, errors):
    min_items = schema.get("minItems")
    max_items = schema.get("maxItems")
    unique_items = schema.get("uniqueItems")
    if min_items is not None and len(value) < min_items:
        errors.append(f"{path}: array has fewer than minItems {min_items}")
    if max_items is not None and len(value) > max_items:
        errors.append(f"{path}: array has more than maxItems {max_items}")
    if unique_items:
        seen = set()
        for index, item in enumerate(value):
            marker = json.dumps(item, sort_keys=True, ensure_ascii=False)
            if marker in seen:
                errors.append(f"{path}[{index}]: duplicate item violates uniqueItems")
                break
            seen.add(marker)

def validate(schema, value, path="$", errors=None):
    if errors is None:
        errors = []
    if not isinstance(schema, dict):
        return errors

    schema_type = schema.get("type")
    if schema_type is not None and not type_matches(schema_type, value):
        errors.append(f"{path}: expected type {schema_type}, found {type(value).__name__}")
        return errors

    enum = schema.get("enum")
    if enum is not None and value not in enum:
        errors.append(f"{path}: value {value!r} not in enum {enum!r}")

    const = schema.get("const")
    if const is not None and value != const:
        errors.append(f"{path}: value {value!r} not equal to const {const!r}")

    if is_number(value):
        validate_numeric(schema, value, path, errors)

    if isinstance(value, str):
        validate_string(schema, value, path, errors)

    if isinstance(value, list):
        validate_array(schema, value, path, errors)
        items_schema = schema.get("items")
        if isinstance(items_schema, dict):
            for index, item in enumerate(value):
                validate(items_schema, item, f"{path}[{index}]", errors)
        elif isinstance(items_schema, list):
            for index, item_schema in enumerate(items_schema):
                if index < len(value):
                    validate(item_schema, value[index], f"{path}[{index}]", errors)

    if isinstance(value, dict):
        required = schema.get("required", [])
        for key in required:
            if key not in value:
                errors.append(f"{path}: missing required property '{key}'")

        properties = schema.get("properties", {})
        pattern_properties = schema.get("patternProperties", {})
        additional = schema.get("additionalProperties", True)

        matched_keys = set()
        for key, subschema in properties.items():
            if key in value:
                matched_keys.add(key)
                validate(subschema, value[key], f"{path}.{key}", errors)

        for pattern, subschema in pattern_properties.items():
            try:
                regex = re.compile(pattern)
            except re.error as exc:
                errors.append(f"{path}: invalid patternProperties regex {pattern!r}: {exc}")
                continue
            for key, subvalue in value.items():
                if regex.search(key):
                    matched_keys.add(key)
                    validate(subschema, subvalue, f"{path}.{key}", errors)

        if additional is False:
            for key in value:
                if key not in matched_keys:
                    errors.append(f"{path}: additional property '{key}' not permitted")
        elif isinstance(additional, dict):
            for key in value:
                if key not in matched_keys:
                    validate(additional, value[key], f"{path}.{key}", errors)

        dependent_required = schema.get("dependentRequired") or schema.get("dependencies", {})
        if isinstance(dependent_required, dict):
            for parent, children in dependent_required.items():
                if parent in value:
                    for child in children:
                        if child not in value:
                            errors.append(f"{path}: presence of '{parent}' requires '{child}'")

    # combinators
    all_of = schema.get("allOf")
    if isinstance(all_of, list):
        for subschema in all_of:
            validate(subschema, value, path, errors)

    any_of = schema.get("anyOf")
    if isinstance(any_of, list) and any_of:
        matches = 0
        for subschema in any_of:
            sub_errors = validate(subschema, value, path, [])
            if not sub_errors:
                matches += 1
        if matches == 0:
            errors.append(f"{path}: value must satisfy at least one schema in anyOf")

    one_of = schema.get("oneOf")
    if isinstance(one_of, list) and one_of:
        matches = 0
        for subschema in one_of:
            sub_errors = validate(subschema, value, path, [])
            if not sub_errors:
                matches += 1
        if matches != 1:
            errors.append(f"{path}: value must satisfy exactly one schema in oneOf (matched {matches})")

    not_schema = schema.get("not")
    if isinstance(not_schema, dict):
        if not validate(not_schema, value, path, []):
            errors.append(f"{path}: value matches forbidden schema in not")

    return errors

stdout = os.environ.get("TOOL_STDOUT", "")
stderr = os.environ.get("TOOL_STDERR", "")
metadata = json.loads(os.environ.get("TOOL_METADATA", "{}"))
args = json.loads(os.environ.get("TOOL_ARGS_JSON", "{}"))
name = os.environ.get("TOOL_NAME")
output_schema_text = os.environ.get("OUTPUT_SCHEMA") or ""
exit_code = int(os.environ.get("EXIT_CODE", "0"))
has_json_tool = os.environ.get("HAS_JSON_TOOL") == "true"
structured = None
structured_errors = []

if has_json_tool and stdout.strip():
    try:
        structured = json.loads(stdout)
    except Exception as exc:
        structured_errors.append(f"stdout is not valid JSON: {exc}")

schema = None
if output_schema_text:
    try:
        schema = json.loads(output_schema_text)
    except Exception as exc:
        structured_errors.append(f"Invalid outputSchema: {exc}")

validation_errors = []
if structured is not None and schema is not None:
    validation_errors = validate(schema, structured)
    if validation_errors:
        structured = None

result = {"name": name, "content": []}
meta = {"exitCode": exit_code}

if structured is not None:
    result["structuredContent"] = structured
    result["content"].append({"type": "json", "json": structured})

result["content"].append({"type": "text", "text": stdout})

if stderr:
    meta["stderr"] = stderr

if structured_errors or validation_errors:
    meta["validationErrors"] = structured_errors + validation_errors
    result["isError"] = True

result["_meta"] = meta

if exit_code != 0:
    result["isError"] = True

print(json.dumps(result, ensure_ascii=False, separators=(',', ':')))
PY
	)"; then
		mcp_tools_error -32603 "Unable to format tool result"
		return 1
	fi

	printf '%s' "${result_json}"
}
