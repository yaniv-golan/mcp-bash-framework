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
MCP_RESOURCES_MANUAL_ACTIVE=false
MCP_RESOURCES_MANUAL_BUFFER=""
MCP_RESOURCES_MANUAL_DELIM=$'\036'
MCP_RESOURCES_LOGGER="${MCP_RESOURCES_LOGGER:-mcp.resources}"

mcp_resources_manual_begin() {
	MCP_RESOURCES_MANUAL_ACTIVE=true
	MCP_RESOURCES_MANUAL_BUFFER=""
}

mcp_resources_manual_abort() {
	MCP_RESOURCES_MANUAL_ACTIVE=false
	MCP_RESOURCES_MANUAL_BUFFER=""
}

mcp_resources_manual_finalize() {
	if [ "${MCP_RESOURCES_MANUAL_ACTIVE}" != "true" ]; then
		return 0
	fi
	local py
	py="$(mcp_resources_python)" || {
		mcp_resources_manual_abort
		mcp_resources_error -32603 "Manual registration requires python"
		return 1
	}

	local registry_json
	if ! registry_json="$(
		ITEMS="${MCP_RESOURCES_MANUAL_BUFFER}" ROOT="${MCPBASH_ROOT}" DELIM="${MCP_RESOURCES_MANUAL_DELIM}" "${py}" <<'PY'
import json, os, hashlib, time, pathlib

def default_provider(uri):
    if uri.startswith("git://"):
        return "git"
    if uri.startswith("https://"):
        return "https"
    if uri.startswith("file://") or uri.startswith("file:/"):
        return "file"
    return "file"

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
        raise ValueError("Resource entry missing name")
    if name in seen:
        raise ValueError(f"Duplicate resource name {name!r} in manual registration")
    seen.add(name)
    description = str(data.get("description") or "")
    arguments = data.get("arguments")
    if not isinstance(arguments, dict):
        arguments = {"type": "object", "properties": {}}
    uri = str(data.get("uri") or "").strip()
    if not uri:
        raise ValueError(f"Resource {name!r} missing uri")
    provider = str(data.get("provider") or "").strip()
    if not provider:
        provider = default_provider(uri)
    if provider not in {"file", "git", "https"}:
        raise ValueError(f"Unsupported provider {provider!r} for resource {name!r}")
    mime = str(data.get("mimeType") or "text/plain")
    path = str(data.get("path") or "")
    item = dict(data)
    item["name"] = name
    item["description"] = description
    item["arguments"] = arguments
    item["uri"] = uri
    item["provider"] = provider
    item["mimeType"] = mime
    if path:
        item["path"] = path
    items.append(item)

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
		mcp_resources_manual_abort
		mcp_resources_error -32603 "Manual registration parsing failed"
		return 1
	fi

	local previous_hash="${MCP_RESOURCES_REGISTRY_HASH}"
	MCP_RESOURCES_REGISTRY_JSON="${registry_json}"
	MCP_RESOURCES_REGISTRY_HASH="$(
		REGISTRY_JSON="${registry_json}" "${py}" <<'PY'
import json, os
print(json.loads(os.environ.get("REGISTRY_JSON", "{}")).get('hash', ''))
PY
	)"
	MCP_RESOURCES_TOTAL="$(
		REGISTRY_JSON="${registry_json}" "${py}" <<'PY'
import json, os
print(json.loads(os.environ.get("REGISTRY_JSON", "{}")).get('total', 0))
PY
	)"

	if ! mcp_resources_enforce_registry_limits "${MCP_RESOURCES_TOTAL}" "${registry_json}"; then
		mcp_resources_manual_abort
		return 1
	fi

	MCP_RESOURCES_LAST_SCAN="$(date +%s)"
	if [ "${previous_hash}" != "${MCP_RESOURCES_REGISTRY_HASH}" ]; then
		MCP_RESOURCES_CHANGED=true
	fi
	printf '%s' "${registry_json}" >"${MCP_RESOURCES_REGISTRY_PATH}"
	MCP_RESOURCES_MANUAL_ACTIVE=false
	MCP_RESOURCES_MANUAL_BUFFER=""
	return 0
}
mcp_resources_register_manual() {
	local payload="$1"
	if [ "${MCP_RESOURCES_MANUAL_ACTIVE}" != "true" ]; then
		return 0
	fi
	if [ -z "${payload}" ]; then
		return 0
	fi
	if [ -n "${MCP_RESOURCES_MANUAL_BUFFER}" ]; then
		MCP_RESOURCES_MANUAL_BUFFER="${MCP_RESOURCES_MANUAL_BUFFER}${MCP_RESOURCES_MANUAL_DELIM}${payload}"
	else
		MCP_RESOURCES_MANUAL_BUFFER="${payload}"
	fi
	return 0
}

mcp_resources_hash_payload() {
	local payload="$1"
	if command -v python3 >/dev/null 2>&1; then
		python3 -c 'import hashlib, sys; sys.stdout.write(hashlib.sha256(sys.stdin.buffer.read()).hexdigest())' <<<"${payload}"
		return
	fi
	if command -v python >/dev/null 2>&1; then
		python -c 'import hashlib, sys; sys.stdout.write(hashlib.sha256(sys.stdin.buffer.read()).hexdigest())' <<<"${payload}"
		return
	fi
	if command -v sha256sum >/dev/null 2>&1; then
		printf '%s' "${payload}" | sha256sum | awk '{print $1}'
		return
	fi
	if command -v shasum >/dev/null 2>&1; then
		printf '%s' "${payload}" | shasum -a 256 | awk '{print $1}'
		return
	fi
	printf '%s' "${payload}" | cksum | awk '{print $1}'
}

mcp_resources_subscription_store() {
	local subscription_id="$1"
	local name="$2"
	local uri="$3"
	local fingerprint="$4"
	local path="${MCPBASH_STATE_DIR}/resource_subscription.${subscription_id}"
	printf '%s\n%s\n%s\n' "${name}" "${uri}" "${fingerprint}" >"${path}.tmp"
	mv "${path}.tmp" "${path}"
}

mcp_resources_subscription_store_payload() {
	local subscription_id="$1"
	local name="$2"
	local uri="$3"
	local payload="$4"
	local fingerprint
	fingerprint="$(mcp_resources_hash_payload "${payload}")"
	mcp_resources_subscription_store "${subscription_id}" "${name}" "${uri}" "${fingerprint}"
}

mcp_resources_subscription_store_error() {
	local subscription_id="$1"
	local name="$2"
	local uri="$3"
	local code="$4"
	local message="$5"
	local fingerprint
	fingerprint="ERROR:${code}:$(mcp_resources_hash_payload "${message}")"
	mcp_resources_subscription_store "${subscription_id}" "${name}" "${uri}" "${fingerprint}"
}

mcp_resources_emit_update() {
	local subscription_id="$1"
	local payload="$2"
	local py
	py="$(mcp_resources_python)" || return 0
	mcp_logging_debug "${MCP_RESOURCES_LOGGER}" "Emit update subscription=${subscription_id}"
	local enriched
	enriched="$(
		PAYLOAD="${payload}" SUBSCRIPTION_ID="${subscription_id}" "${py}" <<'PY'
import json, os, sys
data = json.loads(os.environ["PAYLOAD"])
sub = os.environ.get("SUBSCRIPTION_ID")
if sub:
    data["subscriptionId"] = sub
sys.stdout.write(json.dumps(data, ensure_ascii=False, separators=(',', ':')))
PY
	)"
	local safe_enriched="${enriched//\\/\\\\}"
	rpc_send_line_direct "$(printf '{"jsonrpc":"2.0","method":"notifications/resources/updated","params":%s}' "${safe_enriched}")"
}

mcp_resources_emit_error() {
	local subscription_id="$1"
	local code="$2"
	local message="$3"
	local py
	py="$(mcp_resources_python)" || return 0
	local payload
	payload="$(
		CODE="${code}" MESSAGE="${message}" SUBSCRIPTION_ID="${subscription_id}" "${py}" <<'PY'
import json, os, sys
code = int(os.environ.get("CODE", "-32603"))
message = os.environ.get("MESSAGE", "")
sys.stdout.write(json.dumps({
    "subscriptionId": os.environ.get("SUBSCRIPTION_ID"),
    "error": {"code": code, "message": message}
}, ensure_ascii=False, separators=(',', ':')))
PY
	)"
	local safe_payload="${payload//\\/\\\\}"
	rpc_send_line_direct "$(printf '{"jsonrpc":"2.0","method":"notifications/resources/updated","params":%s}' "${safe_payload}")"
}

mcp_resources_poll_subscriptions() {
	if mcp_runtime_is_minimal_mode; then
		return 0
	fi
	[ -n "${MCPBASH_STATE_DIR:-}" ] || return 0
	local path
	for path in "${MCPBASH_STATE_DIR}"/resource_subscription.*; do
		if [ ! -f "${path}" ]; then
			continue
		fi
		local subscription_id name uri fingerprint
		subscription_id="${path##*.}"
		name=""
		uri=""
		fingerprint=""
		{
			IFS= read -r name || true
			IFS= read -r uri || true
			IFS= read -r fingerprint || true
		} <"${path}"
		local result
		if result="$(mcp_resources_read "${name}" "${uri}")"; then
			local new_fingerprint
			new_fingerprint="$(mcp_resources_hash_payload "${result}")"
			if [ "${new_fingerprint}" != "${fingerprint}" ]; then
				mcp_resources_subscription_store "${subscription_id}" "${name}" "${uri}" "${new_fingerprint}"
				mcp_resources_emit_update "${subscription_id}" "${result}"
			fi
		else
			local code message error_fingerprint
			code="${MCP_RESOURCES_ERR_CODE:- -32603}"
			message="${MCP_RESOURCES_ERR_MESSAGE:-Unable to read resource}"
			error_fingerprint="ERROR:${code}:$(mcp_resources_hash_payload "${message}")"
			if [ "${error_fingerprint}" != "${fingerprint}" ]; then
				mcp_resources_subscription_store "${subscription_id}" "${name}" "${uri}" "${error_fingerprint}"
				mcp_resources_emit_error "${subscription_id}" "${code}" "${message}"
			fi
		fi
	done
}
mcp_resources_registry_max_bytes() {
	local limit="${MCPBASH_REGISTRY_MAX_BYTES:-104857600}"
	case "${limit}" in
	'' | *[!0-9]*) limit=104857600 ;;
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
		mcp_logging_warning "${MCP_RESOURCES_LOGGER}" "Resources registry contains ${total} entries; consider manual registration"
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

mcp_resources_apply_manual_json() {
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

mcp_resources_run_manual_script() {
	if [ ! -x "${MCPBASH_REGISTER_SCRIPT}" ]; then
		return 1
	fi

	mcp_resources_manual_begin

	local script_output_file
	script_output_file="$(mktemp "${MCPBASH_TMP_ROOT}/mcp-resources-manual-output.XXXXXX")"
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
		mcp_resources_manual_abort
		mcp_resources_error -32603 "Manual registration script failed"
		if [ -n "${script_output}" ]; then
			mcp_logging_error "${MCP_RESOURCES_LOGGER}" "Manual registration script output: ${script_output}"
		fi
		return 1
	fi

	if [ -z "${MCP_RESOURCES_MANUAL_BUFFER}" ] && [ -n "${script_output}" ]; then
		mcp_resources_manual_abort
		if ! mcp_resources_apply_manual_json "${script_output}"; then
			return 1
		fi
		return 0
	fi

	if [ -n "${script_output}" ]; then
		mcp_logging_warning "${MCP_RESOURCES_LOGGER}" "Manual registration script output: ${script_output}"
	fi

	if ! mcp_resources_manual_finalize; then
		return 1
	fi
	return 0
}

mcp_resources_refresh_registry() {
	mcp_resources_init
	mcp_logging_debug "${MCP_RESOURCES_LOGGER}" "Refresh start register=${MCPBASH_REGISTER_SCRIPT} exists=$([[ -x ${MCPBASH_REGISTER_SCRIPT} ]] && echo yes || echo no) ttl=${MCP_RESOURCES_TTL:-5}"
	if [ -x "${MCPBASH_REGISTER_SCRIPT}" ]; then
		mcp_logging_debug "${MCP_RESOURCES_LOGGER}" "Invoking manual registration script"
		if mcp_resources_run_manual_script; then
			mcp_logging_debug "${MCP_RESOURCES_LOGGER}" "Refresh satisfied by manual script"
			return 0
		fi
		mcp_logging_error "${MCP_RESOURCES_LOGGER}" "Manual registration script returned empty output or non-zero"
		return 1
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
			MCP_RESOURCES_TOTAL="$(
				REGISTRY_JSON="${MCP_RESOURCES_REGISTRY_JSON}" "${py}" <<'PY'
import json, os
print(json.loads(os.environ.get("REGISTRY_JSON", "{}")).get('total', 0))
PY
			)"
			if ! mcp_resources_enforce_registry_limits "${MCP_RESOURCES_TOTAL}" "${MCP_RESOURCES_REGISTRY_JSON}"; then
				return 1
			fi
		fi
	fi
	if [ -n "${MCP_RESOURCES_REGISTRY_JSON}" ] && [ $((now - MCP_RESOURCES_LAST_SCAN)) -lt "${MCP_RESOURCES_TTL}" ]; then
		mcp_logging_debug "${MCP_RESOURCES_LOGGER}" "Refresh skipped due to ttl (last=${MCP_RESOURCES_LAST_SCAN})"
		return 0
	fi
	local previous_hash="${MCP_RESOURCES_REGISTRY_HASH}"
	mcp_resources_scan || return 1
	MCP_RESOURCES_LAST_SCAN="${now}"
	mcp_logging_debug "${MCP_RESOURCES_LOGGER}" "Refresh completed scan hash=${MCP_RESOURCES_REGISTRY_HASH}"
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
            if filename.endswith('.meta.yaml'):
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
            if not uri:
                continue
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

mcp_resources_poll() {
	if mcp_runtime_is_minimal_mode; then
		return 0
	fi
	local ttl="${MCP_RESOURCES_TTL:-5}"
	case "${ttl}" in
	'' | *[!0-9]*) ttl=5 ;;
	esac
	local now
	now="$(date +%s)"
	if [ "${MCP_RESOURCES_LAST_SCAN}" -eq 0 ] || [ $((now - MCP_RESOURCES_LAST_SCAN)) -ge "${ttl}" ]; then
		mcp_resources_refresh_registry || true
	fi
	return 0
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
	git://*) echo "git" ;;
	https://*) echo "https" ;;
	*) echo "" ;;
	esac
}

mcp_resources_read_file() {
	local uri="$1"
	local script="${MCPBASH_ROOT}/providers/file.sh"
	local tmp_err
	tmp_err="$(mktemp "${MCPBASH_TMP_ROOT}/mcp-resource-file.XXXXXX")"
	local output status
	if output="$(
		env \
			MCPBASH_ROOT="${MCPBASH_ROOT}" \
			MCP_RESOURCES_ROOTS="${MCP_RESOURCES_ROOTS:-${MCPBASH_ROOT}}" \
			"${script}" "${uri}" 2>"${tmp_err}"
	)"; then
		rm -f "${tmp_err}"
		printf '%s' "${output}"
		return 0
	fi
	status=$?
	local message
	message="$(cat "${tmp_err}" 2>/dev/null || true)"
	rm -f "${tmp_err}"
	case "${status}" in
	2)
		mcp_resources_error -32603 "Resource outside allowed roots"
		;;
	3)
		mcp_resources_error -32601 "Resource not found"
		;;
	*)
		mcp_resources_error -32603 "${message:-Resource provider failed}"
		;;
	esac
	return 1
}

mcp_resources_read_via_provider() {
	local provider="$1"
	local uri="$2"
	local script="${MCPBASH_ROOT}/providers/${provider}.sh"
	if [ -x "${script}" ]; then
		local tmp_err
		tmp_err="$(mktemp "${MCPBASH_TMP_ROOT}/mcp-resource-provider.XXXXXX")"
		local output status
		if output="$(
			env \
				MCPBASH_ROOT="${MCPBASH_ROOT}" \
				MCP_RESOURCES_ROOTS="${MCP_RESOURCES_ROOTS:-${MCPBASH_ROOT}}" \
				"${script}" "${uri}" 2>"${tmp_err}"
		)"; then
			rm -f "${tmp_err}"
			printf '%s' "${output}"
			return 0
		fi
		status=$?
		local message
		message="$(cat "${tmp_err}" 2>/dev/null || true)"
		rm -f "${tmp_err}"
		case "${status}" in
		2)
			mcp_resources_error -32603 "Resource outside allowed roots"
			;;
		3)
			mcp_resources_error -32601 "Resource not found"
			;;
		4)
			mcp_resources_error -32602 "${message:-Invalid resource specification}"
			;;
		5)
			mcp_resources_error -32603 "${message:-Resource fetch failed}"
			;;
		*)
			mcp_resources_error -32603 "${message:-Resource provider failed}"
			;;
		esac
		return 1
	fi

	case "${provider}" in
	file)
		mcp_resources_read_file "${uri}"
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
	mcp_logging_debug "${MCP_RESOURCES_LOGGER}" "Metadata resolved for name=${name:-<direct>} uri=${explicit_uri}"
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
	mcp_logging_debug "${MCP_RESOURCES_LOGGER}" "Reading provider=${provider} uri=${uri}"
	local content
	if ! content="$(mcp_resources_read_via_provider "${provider}" "${uri}")"; then
		return 1
	fi
	mcp_logging_debug "${MCP_RESOURCES_LOGGER}" "Provider returned ${#content} bytes"
	local result
	result="$(
		CONTENT="${content}" MIME="${mime}" URI="${uri}" "${py}" <<'PY'
import json, os, sys
content = os.environ.get("CONTENT", "")
mime = os.environ.get("MIME", "text/plain")
sys.stdout.write(json.dumps({
    "uri": os.environ.get("URI"),
    "mimeType": mime,
    "base64": False,
    "content": content
}, ensure_ascii=False, separators=(',', ':')))
PY
	)"
	local safe_result="${result//\\/\\\\}"
	printf '%s' "${safe_result}"
}
