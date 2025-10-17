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

mcp_tools_registry_max_bytes() {
  local limit="${MCPBASH_REGISTRY_MAX_BYTES:-104857600}"
  case "${limit}" in
    ''|*[!0-9]*) limit=104857600 ;;
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
    printf '%s\n' "mcp-bash WARNING: tools registry contains ${total} entries; consider manual registration (Spec §9 guardrail)." >&2
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

mcp_tools_apply_manual() {
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

mcp_tools_refresh_registry() {
  mcp_tools_init
  if [ -x "${MCPBASH_REGISTER_SCRIPT}" ]; then
    local manual_json
    manual_json="$(${MCPBASH_REGISTER_SCRIPT} 2>/dev/null || true)"
    if [ -n "${manual_json}" ]; then
      mcp_tools_apply_manual "${manual_json}"
      return 0
    fi
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
import json, os, math

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
        return isinstance(value, (int, float)) and not isinstance(value, bool)
    if expected == "integer":
        return isinstance(value, int) and not isinstance(value, bool)
    if expected == "boolean":
        return isinstance(value, bool)
    if expected == "null":
        return value is None
    return True

def validate(schema, value, path="$", errors=None):
    if errors is None:
        errors = []
    if not isinstance(schema, dict):
        return errors
    schema_type = schema.get("type")
    if schema_type is not None and not type_matches(schema_type, value):
        errors.append(f"{path}: expected type {schema_type}, found {type(value).__name__}")
        return errors
    if isinstance(value, dict):
        required = schema.get("required", [])
        for key in required:
            if key not in value:
                errors.append(f"{path}: missing required property '{key}'")
        properties = schema.get("properties", {})
        for key, subschema in properties.items():
            if key in value:
                validate(subschema, value[key], path=f"{path}.{key}", errors=errors)
    if isinstance(value, list):
        items_schema = schema.get("items")
        if isinstance(items_schema, dict):
            for index, item in enumerate(value):
                validate(items_schema, item, path=f"{path}[{index}]", errors=errors)
    enum = schema.get("enum")
    if enum is not None and value not in enum:
        errors.append(f"{path}: value {value!r} not in enum {enum!r}")
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
