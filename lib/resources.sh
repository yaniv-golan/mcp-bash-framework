#!/usr/bin/env bash
# Spec §8/§9 resources discovery and providers.

set -euo pipefail

MCP_RESOURCES_REGISTRY_JSON=""
MCP_RESOURCES_REGISTRY_HASH=""
MCP_RESOURCES_REGISTRY_PATH=""
# shellcheck disable=SC2034
MCP_RESOURCES_TOTAL=0
# shellcheck disable=SC2034
MCP_RESOURCES_ERR_CODE=0
# shellcheck disable=SC2034
MCP_RESOURCES_ERR_MESSAGE=""
MCP_RESOURCES_TTL="${MCP_RESOURCES_TTL:-5}"
MCP_RESOURCES_LAST_SCAN=0
MCP_RESOURCES_CHANGED=false

mcp_resources_registry_max_bytes() {
  local limit="${MCPBASH_REGISTRY_MAX_BYTES:-104857600}"
  case "${limit}" in
    ''|*[!0-9]*) limit=104857600 ;;
  esac
  printf '%s' "${limit}"
}

mcp_resources_enforce_registry_limits() {
  local total="$1"
  local json_payload="$2"
  local limit
  local size
  limit="$(mcp_resources_registry_max_bytes)"
  size="$(LC_ALL=C printf '%s' "${json_payload}" | wc -c | tr -d ' ')"
  if [ "${size}" -gt "${limit}" ]; then
    mcp_resources_error -32603 "Resources registry exceeds ${limit} byte cap"
    return 1
  fi
  if [ "${total}" -gt 500 ]; then
    printf '%s\n' "mcp-bash WARNING: resources registry contains ${total} entries; consider manual registration (Spec §9 guardrail)." >&2
  fi
  return 0
}

mcp_resources_error() {
  MCP_RESOURCES_ERR_CODE="$1"
  MCP_RESOURCES_ERR_MESSAGE="$2"
}

mcp_resources_python() {
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

mcp_resources_init() {
  if [ -z "${MCP_RESOURCES_REGISTRY_PATH}" ]; then
    MCP_RESOURCES_REGISTRY_PATH="${MCPBASH_REGISTRY_DIR}/resources.json"
  fi
  mkdir -p "${MCPBASH_REGISTRY_DIR}"
  mkdir -p "${MCPBASH_ROOT}/resources" >/dev/null 2>&1 || true
}

mcp_resources_apply_manual() {
  local manual_json="$1"
  local py
  py="$(mcp_resources_python)" || {
    mcp_resources_error -32603 "Manual registration requires python"
    return 1
  }
  local registry_json
  if ! registry_json="$(
    INPUT="${manual_json}" "${py}" <<'PY'
import json, os, sys, hashlib, time
data = json.loads(os.environ.get("INPUT", "{}"))
resources = data.get("resources", [])
if not isinstance(resources, list):
    resources = []
now = time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime())
hash_source = json.dumps(resources, ensure_ascii=False, sort_keys=True, separators=(',', ':'))
hash_value = hashlib.sha256(hash_source.encode('utf-8')).hexdigest()
registry = {
    "version": 1,
    "generatedAt": now,
    "items": resources,
    "hash": hash_value,
    "total": len(resources)
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
  if [ "${new_hash}" != "${MCP_RESOURCES_REGISTRY_HASH}" ]; then
    MCP_RESOURCES_CHANGED=true
  fi
  MCP_RESOURCES_REGISTRY_JSON="${registry_json}"
  MCP_RESOURCES_REGISTRY_HASH="${new_hash}"
  # shellcheck disable=SC2034
  # shellcheck disable=SC2034
  # shellcheck disable=SC2034
  # shellcheck disable=SC2034
  MCP_RESOURCES_TOTAL="$(
    REGISTRY_JSON="${registry_json}" "${py}" <<'PY'
import json, os
print(json.loads(os.environ.get("REGISTRY_JSON", "{}")).get('total', 0))
PY
  )"
  if ! mcp_resources_enforce_registry_limits "${MCP_RESOURCES_TOTAL}" "${registry_json}"; then
    return 1
  fi
  MCP_RESOURCES_LAST_SCAN="$(date +%s)"
  printf '%s' "${registry_json}" >"${MCP_RESOURCES_REGISTRY_PATH}"
}

mcp_resources_refresh_registry() {
  mcp_resources_init
  if [ -x "${MCPBASH_REGISTER_SCRIPT}" ]; then
    local manual_json
    manual_json="$(${MCPBASH_REGISTER_SCRIPT} 2>/dev/null || true)"
    if [ -n "${manual_json}" ]; then
      mcp_resources_apply_manual "${manual_json}"
      return 0
    fi
  fi
  local now
  now="$(date +%s)"
  local py
  py="$(mcp_resources_python 2>/dev/null)" || true
  if [ -z "${MCP_RESOURCES_REGISTRY_JSON}" ] && [ -f "${MCP_RESOURCES_REGISTRY_PATH}" ]; then
    MCP_RESOURCES_REGISTRY_JSON="$(cat "${MCP_RESOURCES_REGISTRY_PATH}")"
    if [ -n "${py}" ]; then
      MCP_RESOURCES_REGISTRY_HASH="$(
        REGISTRY_JSON="${MCP_RESOURCES_REGISTRY_JSON}" "${py}" <<'PY'
import json, os
print(json.loads(os.environ.get("REGISTRY_JSON", "{}")).get('hash', ''))
PY
      )"
    fi
  fi
  if [ -n "${MCP_RESOURCES_REGISTRY_JSON}" ] && [ $((now - MCP_RESOURCES_LAST_SCAN)) -lt "${MCP_RESOURCES_TTL}" ]; then
    return 0
  fi
  local previous_hash="${MCP_RESOURCES_REGISTRY_HASH}"
  mcp_resources_scan || return 1
  MCP_RESOURCES_LAST_SCAN="${now}"
  if [ "${previous_hash}" != "${MCP_RESOURCES_REGISTRY_HASH}" ]; then
    MCP_RESOURCES_CHANGED=true
  fi
}

mcp_resources_scan() {
  local py
  py="$(mcp_resources_python)" || {
    MCP_RESOURCES_REGISTRY_JSON='{"version":1,"generatedAt":"'$(date -u +%Y-%m-%dT%H:%M:%SZ)'","items":[],"hash":"","total":0}'
    MCP_RESOURCES_REGISTRY_HASH=""
    MCP_RESOURCES_TOTAL=0
    printf '%s' "${MCP_RESOURCES_REGISTRY_JSON}" >"${MCP_RESOURCES_REGISTRY_PATH}"
    return 0
  }

  local registry_json
  registry_json="$(
    ROOT="${MCPBASH_ROOT}" RES_DIR="${MCPBASH_ROOT}/resources" "${py}" <<'PY'
import os, json, sys, hashlib, time
root = os.environ["ROOT"]
resources_dir = os.environ["RES_DIR"]
items = []
if os.path.isdir(resources_dir):
    for dirpath, dirnames, filenames in os.walk(resources_dir):
        dirnames[:] = [d for d in dirnames if not d.startswith('.')]
        rel_depth = os.path.relpath(dirpath, resources_dir)
        if rel_depth != '.' and rel_depth.count(os.sep) >= 3:
            dirnames[:] = []
            continue
        for filename in filenames:
            if filename.startswith('.'):
                continue
            path = os.path.join(dirpath, filename)
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
                    parsed = None
                if isinstance(parsed, dict):
                    meta = parsed
            name = str(meta.get('name') or base)
            description = meta.get('description') or ''
            uri = meta.get('uri') or ''
            mime = meta.get('mimeType') or 'text/plain'
            item = {
                "name": name,
                "description": description,
                "path": rel,
                "provider": meta.get('provider', 'file'),
                "uri": uri,
                "mimeType": mime
            }
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

  MCP_RESOURCES_REGISTRY_JSON="${registry_json}"
  MCP_RESOURCES_REGISTRY_HASH="$(
    REGISTRY_JSON="${registry_json}" "${py}" <<'PY'
import json, os
print(json.loads(os.environ.get("REGISTRY_JSON", "{}")).get('hash', ''))
PY
  )"
  # shellcheck disable=SC2034
  MCP_RESOURCES_TOTAL="$(
    REGISTRY_JSON="${registry_json}" "${py}" <<'PY'
import json, os
print(json.loads(os.environ.get("REGISTRY_JSON", "{}")).get('total', 0))
PY
  )"
  if ! mcp_resources_enforce_registry_limits "${MCP_RESOURCES_TOTAL}" "${registry_json}"; then
    return 1
  fi

  printf '%s' "${registry_json}" >"${MCP_RESOURCES_REGISTRY_PATH}"
}

mcp_resources_decode_cursor() {
  local cursor="$1"
  local hash="$2"
  local offset
  if ! offset="$(mcp_paginate_decode "${cursor}" "resources" "${hash}")"; then
    return 1
  fi
  printf '%s' "${offset}"
}

mcp_resources_list() {
  local limit="$1"
  local cursor="$2"
  # shellcheck disable=SC2034
  MCP_RESOURCES_ERR_CODE=0
  # shellcheck disable=SC2034
  MCP_RESOURCES_ERR_MESSAGE=""

  mcp_resources_refresh_registry || {
    mcp_resources_error -32603 "Unable to load resources registry"
    return 1
  }

  local py
  if ! py="$(mcp_resources_python)"; then
    mcp_resources_error -32603 "Python interpreter required for resources listing"
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
    if ! offset="$(mcp_resources_decode_cursor "${cursor}" "${MCP_RESOURCES_REGISTRY_HASH}")"; then
      mcp_resources_error -32602 "Invalid cursor"
      return 1
    fi
  fi

  local result_json
  if ! result_json="$(
    REGISTRY="${MCP_RESOURCES_REGISTRY_JSON}" OFFSET="${offset}" LIMIT="${numeric_limit}" PYTHONIOENCODING="utf-8" "${py}" <<'PY'
import json, os, base64, sys
registry = json.loads(os.environ["REGISTRY"])
items = registry.get("items", [])
offset = int(os.environ["OFFSET"])
limit = int(os.environ["LIMIT"])
slice_items = items[offset:offset + limit]
result = {"items": slice_items, "total": len(items)}
if offset + limit < len(items):
    payload = json.dumps({"ver": 1, "collection": "resources", "offset": offset + limit, "hash": registry.get("hash", ""), "timestamp": registry.get("generatedAt")}, separators=(',', ':'))
    encoded = base64.urlsafe_b64encode(payload.encode('utf-8')).decode('utf-8').rstrip('=')
    result["nextCursor"] = encoded
print(json.dumps(result, ensure_ascii=False, separators=(',', ':')))
PY
  )"; then
    mcp_resources_error -32603 "Unable to paginate resources"
    return 1
  fi

  printf '%s' "${result_json}"
}

mcp_resources_consume_notification() {
  if [ "${MCP_RESOURCES_CHANGED}" = true ]; then
    MCP_RESOURCES_CHANGED=false
    printf '{"jsonrpc":"2.0","method":"notifications/resources/list_changed","params":{}}'
  else
    printf ''
  fi
}

mcp_resources_metadata_for_name() {
  local name="$1"
  mcp_resources_refresh_registry || return 1
  local py
  py="$(mcp_resources_python)" || return 1
  local metadata
  if ! metadata="$(
    REGISTRY="${MCP_RESOURCES_REGISTRY_JSON}" TARGET="${name}" "${py}" <<'PY'
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

mcp_resources_provider_from_uri() {
  local uri="$1"
  case "${uri}" in
    file://*) echo "file" ;;
    git://* | https://*) echo "stub" ;;
    *) echo "" ;;
  esac
}

mcp_resources_read_file() {
  local uri="$1"
  local path="${uri#file://}"
  if command -v realpath >/dev/null 2>&1; then
    path="$(realpath -m "${path}")"
  fi
  local roots
  roots="${MCP_RESOURCES_ROOTS:-${MCPBASH_ROOT}}"
  local allowed=false
  for root in ${roots}; do
    if command -v realpath >/dev/null 2>&1; then
      local real_root
      real_root="$(realpath -m "${root}")"
      case "${path}" in
        "${real_root}" | "${real_root}"/*)
          allowed=true
          break
          ;;
      esac
    else
      case "${path}" in
        "${root}" | "${root}"/*)
          allowed=true
          break
          ;;
      esac
    fi
  done
  if [ "${allowed}" != true ]; then
    mcp_resources_error -32603 "Resource outside allowed roots"
    return 1
  fi
  if [ ! -f "${path}" ]; then
    mcp_resources_error -32601 "Resource not found"
    return 1
  fi
  cat "${path}"
}

mcp_resources_read_via_provider() {
  local provider="$1"
  local uri="$2"
  case "${provider}" in
    file)
      mcp_resources_read_file "${uri}"
      ;;
    stub)
      mcp_resources_error -32603 "Resource provider not yet implemented"
      return 1
      ;;
    *)
      mcp_resources_error -32603 "Unsupported resource provider"
      return 1
      ;;
  esac
}

mcp_resources_read() {
  local name="$1"
  local explicit_uri="$2"
  mcp_resources_refresh_registry || {
    mcp_resources_error -32603 "Unable to load resources registry"
    return 1
  }
  local metadata
  if ! metadata="$(mcp_resources_metadata_for_name "${name}")"; then
    if [ -z "${explicit_uri}" ]; then
      mcp_resources_error -32601 "Resource not found"
      return 1
    fi
    metadata='{}'
  fi
  local py
  py="$(mcp_resources_python)" || return 1
  local info_json
  info_json="$(
    METADATA="${metadata}" URI_OVERRIDE="${explicit_uri}" "${py}" <<'PY'
import json, os
metadata = json.loads(os.environ.get("METADATA", "{}"))
uri = os.environ.get("URI_OVERRIDE") or metadata.get("uri") or ""
provider = metadata.get("provider", "file")
mime = metadata.get("mimeType", "text/plain")
print(json.dumps({
    "uri": uri,
    "provider": provider,
    "mimeType": mime
}, ensure_ascii=False, separators=(',', ':')))
PY
  )"
  local uri provider mime
  uri="$(
    INFO="${info_json}" "${py}" <<'PY'
import json, os
info = json.loads(os.environ["INFO"])
print(info.get("uri") or "")
PY
  )"
  provider="$(
    INFO="${info_json}" "${py}" <<'PY'
import json, os
info = json.loads(os.environ["INFO"])
print(info.get("provider") or "file")
PY
  )"
  mime="$(
    INFO="${info_json}" "${py}" <<'PY'
import json, os
info = json.loads(os.environ["INFO"])
print(info.get("mimeType") or "text/plain")
PY
  )"
  if [ -z "${uri}" ]; then
    mcp_resources_error -32602 "Resource URI missing"
    return 1
  fi
  local content
  if ! content="$(mcp_resources_read_via_provider "${provider}" "${uri}")"; then
    return 1
  fi
  local result
  result="$(
    CONTENT="${content}" MIME="${mime}" URI="${uri}" "${py}" <<'PY'
import json, os
content = os.environ.get("CONTENT", "")
mime = os.environ.get("MIME", "text/plain")
print(json.dumps({
    "uri": os.environ.get("URI"),
    "mimeType": mime,
    "base64": False,
    "content": content
}, ensure_ascii=False, separators=(',', ':')))
PY
  )"
  printf '%s' "${result}"
}
