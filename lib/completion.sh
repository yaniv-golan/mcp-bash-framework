#!/usr/bin/env bash
# Spec §§8/10/11: completion router helpers (manual registry, cursor management, script dispatch).

set -euo pipefail

MCP_COMPLETION_LOGGER="${MCP_COMPLETION_LOGGER:-mcp.completion}"

mcp_completion_suggestions="[]"
mcp_completion_has_more=false
mcp_completion_cursor=""

MCP_COMPLETION_MANUAL_ACTIVE=false
MCP_COMPLETION_MANUAL_BUFFER=""
MCP_COMPLETION_MANUAL_DELIM=$'\036'
MCP_COMPLETION_MANUAL_REGISTRY_JSON=""
MCP_COMPLETION_MANUAL_LOADED=false

MCP_COMPLETION_PROVIDER_TYPE=""
MCP_COMPLETION_PROVIDER_SCRIPT=""
MCP_COMPLETION_PROVIDER_METADATA=""
MCP_COMPLETION_PROVIDER_SCRIPT_KEY=""
MCP_COMPLETION_PROVIDER_TIMEOUT=""
MCP_COMPLETION_PROVIDER_PROMPT_TEMPLATE=""
MCP_COMPLETION_PROVIDER_RESOURCE_PATH=""
MCP_COMPLETION_PROVIDER_RESOURCE_URI=""
MCP_COMPLETION_PROVIDER_RESOURCE_PROVIDER=""
MCP_COMPLETION_PROVIDER_RESULT_SUGGESTIONS="[]"
MCP_COMPLETION_PROVIDER_RESULT_HAS_MORE="false"
MCP_COMPLETION_PROVIDER_RESULT_NEXT=""
MCP_COMPLETION_PROVIDER_RESULT_CURSOR=""
MCP_COMPLETION_PROVIDER_RESULT_ERROR=""

MCP_COMPLETION_CURSOR_OFFSET=0
MCP_COMPLETION_CURSOR_SCRIPT_KEY=""

mcp_completion_manual_begin() {
	MCP_COMPLETION_MANUAL_ACTIVE=true
	MCP_COMPLETION_MANUAL_BUFFER=""
}

mcp_completion_manual_abort() {
	MCP_COMPLETION_MANUAL_ACTIVE=false
	MCP_COMPLETION_MANUAL_BUFFER=""
}

mcp_completion_register_manual() {
	local payload="$1"
	if [ "${MCP_COMPLETION_MANUAL_ACTIVE}" != "true" ]; then
		return 0
	fi
	if [ -z "${payload}" ]; then
		return 0
	fi
	if [ -n "${MCP_COMPLETION_MANUAL_BUFFER}" ]; then
		MCP_COMPLETION_MANUAL_BUFFER="${MCP_COMPLETION_MANUAL_BUFFER}${MCP_COMPLETION_MANUAL_DELIM}${payload}"
	else
		MCP_COMPLETION_MANUAL_BUFFER="${payload}"
	fi
	return 0
}

mcp_completion_apply_manual_json() {
	local manual_json="$1"
	local py
	py="$(mcp_tools_python)" || {
		MCP_COMPLETION_MANUAL_REGISTRY_JSON=""
		return 1
	}
	local registry_json
	if ! registry_json="$(
		INPUT="${manual_json}" ROOT="${MCPBASH_ROOT}" "${py}" <<'PY'
import json, os, hashlib, time, pathlib

def normalize_entries(entries, root):
    results = []
    seen = set()
    root_path = pathlib.Path(root).resolve()
    for raw in entries:
        data = json.loads(raw) if isinstance(raw, str) else raw
        name = str(data.get("name") or "").strip()
        if not name:
            raise ValueError("Completion entry missing name")
        if name in seen:
            raise ValueError(f"Duplicate completion name {name!r} in manual registration")
        seen.add(name)
        path = str(data.get("path") or "").strip()
        if not path:
            raise ValueError(f"Completion {name!r} missing path")
        candidate = pathlib.Path(path)
        if candidate.is_absolute():
            resolved = candidate.resolve()
        else:
            resolved = (root_path / candidate).resolve()
        try:
            rel = resolved.relative_to(root_path)
        except ValueError:
            raise ValueError(f"Completion path {path!r} must be inside server root")
        if not resolved.is_file():
            raise ValueError(f"Completion script {path!r} not found")
        entry = {
            "name": name,
            "path": str(rel).replace("\\", "/")
        }
        timeout = data.get("timeoutSecs")
        if timeout is not None:
            try:
                entry["timeoutSecs"] = int(timeout)
            except Exception:
                pass
        entry["kind"] = "shell"
        results.append(entry)
    results.sort(key=lambda x: x["name"])
    return results

data = json.loads(os.environ.get("INPUT", "{}"))
root = os.environ.get("ROOT", "")
items = data.get("completions", [])
if not isinstance(items, list):
    items = []
entries = normalize_entries(items, root)
hash_source = json.dumps(entries, ensure_ascii=False, sort_keys=True, separators=(',', ':'))
hash_value = hashlib.sha256(hash_source.encode('utf-8')).hexdigest()
registry = {
    "version": 1,
    "generatedAt": time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime()),
    "items": entries,
    "hash": hash_value,
    "total": len(entries)
}
print(json.dumps(registry, ensure_ascii=False, separators=(',', ':')))
PY
	)"; then
		return 1
	fi
	MCP_COMPLETION_MANUAL_REGISTRY_JSON="${registry_json}"
	MCP_COMPLETION_MANUAL_LOADED=true
	return 0
}

mcp_completion_manual_finalize() {
	if [ "${MCP_COMPLETION_MANUAL_ACTIVE}" != "true" ]; then
		return 0
	fi
	local py
	py="$(mcp_tools_python)" || {
		mcp_completion_manual_abort
		return 1
	}
	local manual_json
	if ! manual_json="$(
		ITEMS="${MCP_COMPLETION_MANUAL_BUFFER}" DELIM="${MCP_COMPLETION_MANUAL_DELIM}" "${py}" <<'PY'
import json, os
items = os.environ.get("ITEMS", "")
delimiter = os.environ.get("DELIM", "\x1e")
if delimiter:
    raw_entries = [entry for entry in items.split(delimiter) if entry]
else:
    raw_entries = [items] if items else []
print(json.dumps({"completions": [json.loads(entry) for entry in raw_entries]}, ensure_ascii=False, separators=(',', ':')))
PY
	)"; then
		mcp_completion_manual_abort
		return 1
	fi
	if ! mcp_completion_apply_manual_json "${manual_json}"; then
		mcp_completion_manual_abort
		return 1
	fi
	MCP_COMPLETION_MANUAL_ACTIVE=false
	MCP_COMPLETION_MANUAL_BUFFER=""
	return 0
}

mcp_completion_run_manual_script() {
	if [ ! -x "${MCPBASH_REGISTER_SCRIPT}" ]; then
		return 1
	fi

	mcp_completion_manual_begin

	local script_output_file
	script_output_file="$(mktemp "${MCPBASH_TMP_ROOT}/mcp-completion-manual-output.XXXXXX")"
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
		mcp_completion_manual_abort
		if [ -n "${script_output}" ]; then
			mcp_logging_error "${MCP_COMPLETION_LOGGER}" "Manual completion registry output: ${script_output}"
		fi
		return 1
	fi

	if [ -z "${MCP_COMPLETION_MANUAL_BUFFER}" ] && [ -n "${script_output}" ]; then
		mcp_completion_manual_abort
		if ! mcp_completion_apply_manual_json "${script_output}"; then
			return 1
		fi
		return 0
	fi

	if [ -n "${script_output}" ]; then
		mcp_logging_warning "${MCP_COMPLETION_LOGGER}" "Manual completion script output: ${script_output}"
	fi

	if ! mcp_completion_manual_finalize; then
		return 1
	fi
	return 0
}

mcp_completion_refresh_manual() {
	if [ "${MCP_COMPLETION_MANUAL_LOADED}" = true ]; then
		return 0
	fi
	if [ -x "${MCPBASH_REGISTER_SCRIPT}" ]; then
		if mcp_completion_run_manual_script; then
			MCP_COMPLETION_MANUAL_LOADED=true
			return 0
		fi
		mcp_logging_error "${MCP_COMPLETION_LOGGER}" "Manual completion registration failed"
		return 1
	fi
	MCP_COMPLETION_MANUAL_LOADED=true
	return 0
}

mcp_completion_lookup_manual() {
	local name="$1"
	mcp_completion_refresh_manual || return 1
	if [ -z "${MCP_COMPLETION_MANUAL_REGISTRY_JSON}" ]; then
		return 1
	fi
	local py
	py="$(mcp_tools_python)" || return 1
	local entry
	if ! entry="$(
		REGISTRY="${MCP_COMPLETION_MANUAL_REGISTRY_JSON}" TARGET="${name}" "${py}" <<'PY'
import json, os, sys
registry = json.loads(os.environ.get("REGISTRY", "{}"))
target = os.environ.get("TARGET")
for item in registry.get("items", []):
    if item.get("name") == target:
        print(json.dumps(item, ensure_ascii=False, separators=(',', ':')))
        sys.exit(0)
sys.exit(1)
PY
	)"; then
		return 1
	fi
	printf '%s' "${entry}"
	return 0
}

mcp_completion_args_hash() {
	local args_json="$1"
	local py
	py="$(mcp_tools_python)" || {
		printf ''
		return 1
	}
	printf '%s' "$(
		ARGS="${args_json:-{}}" "${py}" <<'PY'
import hashlib, json, os
try:
    data = json.loads(os.environ.get("ARGS", "{}"))
except Exception:
    data = {}
payload = json.dumps(data, sort_keys=True, separators=(',', ':')).encode('utf-8')
print(hashlib.sha256(payload).hexdigest())
PY
	)"
}

mcp_completion_encode_cursor() {
	local name="$1"
	local args_hash="$2"
	local offset="$3"
	local script_key="$4"
	local py
	py="$(mcp_tools_python)" || {
		printf ''
		return 1
	}
	printf '%s' "$(
		NAME="${name}" HASH="${args_hash}" OFFSET="${offset}" SCRIPT="${script_key}" "${py}" <<'PY'
import base64, json, os
cursor = {
    "ver": 1,
    "kind": "completion",
    "name": os.environ.get("NAME", ""),
    "args": os.environ.get("HASH", ""),
    "offset": int(os.environ.get("OFFSET", "0") or 0),
    "script": os.environ.get("SCRIPT", "")
}
payload = json.dumps(cursor, separators=(',', ':')).encode('utf-8')
print(base64.urlsafe_b64encode(payload).decode('utf-8').rstrip('='))
PY
	)"
}

mcp_completion_decode_cursor() {
	local cursor="$1"
	local expected_name="$2"
	local expected_hash="$3"
	local py
	py="$(mcp_tools_python)" || return 1
	local decoded
	if ! decoded="$(
		CURSOR_VALUE="${cursor}" EXPECTED_NAME="${expected_name}" EXPECTED_HASH="${expected_hash}" "${py}" <<'PY'
import base64, json, os, sys
cursor_value = os.environ.get("CURSOR_VALUE", "")
if not cursor_value:
    sys.exit(1)
padding = '=' * (-len(cursor_value) % 4)
try:
    data = json.loads(base64.urlsafe_b64decode(cursor_value + padding).decode('utf-8'))
except Exception:
    sys.exit(1)
if data.get("ver") != 1 or data.get("name") != os.environ.get("EXPECTED_NAME"):
    sys.exit(1)
if data.get("args") != os.environ.get("EXPECTED_HASH"):
    sys.exit(1)
offset = data.get("offset")
if not isinstance(offset, int) or offset < 0:
    sys.exit(1)
script = data.get("script") or ""
print(f"{offset}|{script}")
PY
	)"; then
		return 1
	fi
	# shellcheck disable=SC2034
	MCP_COMPLETION_CURSOR_OFFSET="${decoded%%|*}"
	# shellcheck disable=SC2034
	MCP_COMPLETION_CURSOR_SCRIPT_KEY="${decoded#*|}"
	return 0
}

mcp_completion_candidates_for_path() {
	local rel_path="$1"
	local base
	local candidates=()
	if [ -z "${rel_path}" ]; then
		printf ''
		return 0
	fi
	candidates+=("${rel_path}.completion.sh")
	candidates+=("${rel_path}.completion")
	base="${rel_path%.*}"
	if [ "${base}" != "${rel_path}" ]; then
		candidates+=("${base}.completion.sh")
		candidates+=("${base}.completion")
	fi
	printf '%s\n' "${candidates[@]}"
}

mcp_completion_prompt_script() {
	local metadata="$1"
	local py
	py="$(mcp_tools_python)" || return 1
	local rel_path
	if ! rel_path="$(
		METADATA="${metadata}" "${py}" <<'PY'
import json, os
print(json.loads(os.environ.get("METADATA", "{}")).get("path") or "")
PY
	)"; then
		return 1
	fi
	local candidate
	while IFS= read -r candidate; do
		[ -z "${candidate}" ] && continue
		if [ -x "${MCPBASH_ROOT}/${candidate}" ]; then
			printf '%s' "${candidate}"
			return 0
		fi
	done < <(mcp_completion_candidates_for_path "${rel_path}")
	return 1
}

mcp_completion_resource_script() {
	local metadata="$1"
	local py
	py="$(mcp_tools_python)" || return 1
	local rel_path
	if ! rel_path="$(
		METADATA="${metadata}" "${py}" <<'PY'
import json, os
print(json.loads(os.environ.get("METADATA", "{}")).get("path") or "")
PY
	)"; then
		return 1
	fi
	local candidate
	while IFS= read -r candidate; do
		[ -z "${candidate}" ] && continue
		if [ -x "${MCPBASH_ROOT}/${candidate}" ]; then
			printf '%s' "${candidate}"
			return 0
		fi
	done < <(mcp_completion_candidates_for_path "${rel_path}")
	return 1
}

mcp_completion_select_provider() {
	local name="$1"
	local args_json="$2"

	MCP_COMPLETION_PROVIDER_TYPE=""
	MCP_COMPLETION_PROVIDER_SCRIPT=""
	MCP_COMPLETION_PROVIDER_METADATA=""
	MCP_COMPLETION_PROVIDER_SCRIPT_KEY=""
	MCP_COMPLETION_PROVIDER_TIMEOUT=""
	MCP_COMPLETION_PROVIDER_PROMPT_TEMPLATE=""
	MCP_COMPLETION_PROVIDER_RESOURCE_PATH=""
	MCP_COMPLETION_PROVIDER_RESOURCE_URI=""
	MCP_COMPLETION_PROVIDER_RESOURCE_PROVIDER=""

	mcp_completion_refresh_manual || return 1

	local entry metadata script_rel

	if entry="$(mcp_completion_lookup_manual "${name}")"; then
		local py
		py="$(mcp_tools_python)" || return 1
		if ! script_rel="$(
			ENTRY="${entry}" "${py}" <<'PY'
import json, os
entry = json.loads(os.environ.get("ENTRY", "{}"))
path = entry.get("path")
if not path:
    raise SystemExit(1)
print(path)
PY
		)"; then
			return 1
		fi
		MCP_COMPLETION_PROVIDER_TYPE="manual"
		MCP_COMPLETION_PROVIDER_SCRIPT="${script_rel}"
		MCP_COMPLETION_PROVIDER_SCRIPT_KEY="manual:${script_rel}"
		MCP_COMPLETION_PROVIDER_TIMEOUT="$(
			ENTRY="${entry}" "${py}" <<'PY'
import json, os
entry = json.loads(os.environ.get("ENTRY", "{}"))
timeout = entry.get("timeoutSecs")
if timeout is None:
    print("")
else:
    try:
        print(str(int(timeout)))
    except Exception:
        print("")
PY
		)"
		return 0
	fi

	if metadata="$(mcp_prompts_metadata_for_name "${name}")"; then
		if script_rel="$(mcp_completion_prompt_script "${metadata}")"; then
			local py
			py="$(mcp_tools_python)" || return 1
			MCP_COMPLETION_PROVIDER_TYPE="prompt"
			MCP_COMPLETION_PROVIDER_METADATA="${metadata}"
			MCP_COMPLETION_PROVIDER_SCRIPT="${script_rel}"
			MCP_COMPLETION_PROVIDER_PROMPT_TEMPLATE="$(
				METADATA="${metadata}" "${py}" <<'PY'
import json, os
print(json.loads(os.environ.get("METADATA", "{}")).get("path") or "")
PY
			)"
			MCP_COMPLETION_PROVIDER_SCRIPT_KEY="prompt:${script_rel}"
			return 0
		fi
	fi

	if metadata="$(mcp_resources_metadata_for_name "${name}")"; then
		if script_rel="$(mcp_completion_resource_script "${metadata}")"; then
			local py
			py="$(mcp_tools_python)" || return 1
			MCP_COMPLETION_PROVIDER_TYPE="resource"
			MCP_COMPLETION_PROVIDER_METADATA="${metadata}"
			MCP_COMPLETION_PROVIDER_SCRIPT="${script_rel}"
			MCP_COMPLETION_PROVIDER_RESOURCE_PATH="$(
				METADATA="${metadata}" "${py}" <<'PY'
import json, os
print(json.loads(os.environ.get("METADATA", "{}")).get("path") or "")
PY
			)"
			MCP_COMPLETION_PROVIDER_RESOURCE_URI="$(
				METADATA="${metadata}" "${py}" <<'PY'
import json, os
print(json.loads(os.environ.get("METADATA", "{}")).get("uri") or "")
PY
			)"
			MCP_COMPLETION_PROVIDER_RESOURCE_PROVIDER="$(
				METADATA="${metadata}" "${py}" <<'PY'
import json, os
print(json.loads(os.environ.get("METADATA", "{}")).get("provider") or "")
PY
			)"
			MCP_COMPLETION_PROVIDER_SCRIPT_KEY="resource:${script_rel}"
			return 0
		fi
	fi

	MCP_COMPLETION_PROVIDER_TYPE="builtin"
	# shellcheck disable=SC2034
	MCP_COMPLETION_PROVIDER_SCRIPT_KEY="builtin:${name}"
	return 0
}

mcp_completion_normalize_output() {
	local script_output="$1"
	local limit="$2"
	local start="$3"
	local py
	py="$(mcp_tools_python)" || return 1
	printf '%s' "$(
		OUTPUT="${script_output}" LIMIT="${limit}" START="${start}" "${py}" <<'PY'
import json, os

raw = os.environ.get("OUTPUT", "").strip()
limit = int(os.environ.get("LIMIT", "5") or 5)
start = int(os.environ.get("START", "0") or 0)

suggestions = []
has_more = False
next_index = None
cursor = None

if raw:
    parsed = json.loads(raw)
    if isinstance(parsed, list):
        suggestions = parsed
    elif isinstance(parsed, dict):
        suggestions = parsed.get("suggestions", [])
        has_more = bool(parsed.get("hasMore"))
        next_candidate = parsed.get("next")
        if isinstance(next_candidate, int):
            next_index = next_candidate
        custom_cursor = parsed.get("cursor")
        if isinstance(custom_cursor, str):
            cursor = custom_cursor
    else:
        suggestions = []

limited = suggestions[:limit]
if len(suggestions) > limit:
    has_more = True

if next_index is None:
    if has_more:
        next_index = start + len(limited)
    else:
        next_index = None

print(json.dumps({
    "suggestions": limited,
    "hasMore": has_more,
    "next": next_index,
    "cursor": cursor
}, ensure_ascii=False, separators=(',', ':')))
PY
	)"
}

mcp_completion_builtin_generate() {
	local name="$1"
	local args_json="$2"
	local limit="$3"
	local offset="$4"
	local py
	py="$(mcp_tools_python)" || return 1
	printf '%s' "$(
		NAME="${name}" ARGS="${args_json}" LIMIT="${limit}" OFFSET="${offset}" "${py}" <<'PY'
import json, os

name = os.environ.get("NAME", "")
try:
    args = json.loads(os.environ.get("ARGS", "{}"))
except Exception:
    args = {}
limit = int(os.environ.get("LIMIT", "5") or 5)
offset = int(os.environ.get("OFFSET", "0") or 0)
query = (args.get("query") or args.get("prefix") or "").strip()
base = query or name.strip() or "suggestion"
candidates = [
    {"type": "text", "text": base},
    {"type": "text", "text": f"{base} snippet"},
    {"type": "text", "text": f"{base} example"}
]
limited = candidates[offset:offset + limit]
has_more = offset + limit < len(candidates)
next_index = offset + len(limited) if has_more else None
print(json.dumps({"suggestions": limited, "hasMore": has_more, "next": next_index}, ensure_ascii=False, separators=(',', ':')))
PY
	)"
}

mcp_completion_run_provider() {
	local name="$1"
	local args_json="$2"
	local limit="$3"
	local offset="$4"
	local args_hash="$5"

	MCP_COMPLETION_PROVIDER_RESULT_SUGGESTIONS="[]"
	MCP_COMPLETION_PROVIDER_RESULT_HAS_MORE="false"
	MCP_COMPLETION_PROVIDER_RESULT_NEXT=""
	MCP_COMPLETION_PROVIDER_RESULT_CURSOR=""
	MCP_COMPLETION_PROVIDER_RESULT_ERROR=""

	local normalized py script_output stderr_output status abs_script

	py="$(mcp_tools_python)" || {
		MCP_COMPLETION_PROVIDER_RESULT_ERROR="Python interpreter required for completion handling"
		return 1
	}

	case "${MCP_COMPLETION_PROVIDER_TYPE}" in
	builtin)
		if ! normalized="$(mcp_completion_builtin_generate "${name}" "${args_json}" "${limit}" "${offset}")"; then
			# shellcheck disable=SC2034
			MCP_COMPLETION_PROVIDER_RESULT_ERROR="Builtin completion generator failed"
			return 1
		fi
		;;
	manual | prompt | resource)
		abs_script="${MCP_COMPLETION_PROVIDER_SCRIPT}"
		if [ -z "${abs_script}" ]; then
			MCP_COMPLETION_PROVIDER_RESULT_ERROR="Completion script not defined"
			return 1
		fi
		case "${MCP_COMPLETION_PROVIDER_TYPE}" in
		manual | prompt | resource)
			abs_script="${MCPBASH_ROOT}/${abs_script}"
			;;
		esac
		if [ ! -f "${abs_script}" ]; then
			# shellcheck disable=SC2034
			MCP_COMPLETION_PROVIDER_RESULT_ERROR="Completion script not found"
			return 1
		fi
		if [ ! -x "${abs_script}" ]; then
			# shellcheck disable=SC2034
			MCP_COMPLETION_PROVIDER_RESULT_ERROR="Completion script not executable"
			return 1
		fi
		local tmp_out tmp_err
		tmp_out="$(mktemp "${MCPBASH_TMP_ROOT}/mcp-completion.out.XXXXXX")"
		tmp_err="$(mktemp "${MCPBASH_TMP_ROOT}/mcp-completion.err.XXXXXX")"
		local timeout="${MCP_COMPLETION_PROVIDER_TIMEOUT}"
		if [ "${MCP_COMPLETION_PROVIDER_TYPE}" = "prompt" ]; then
			local prompt_rel="${MCP_COMPLETION_PROVIDER_PROMPT_TEMPLATE}"
			local prompt_abs=""
			if [ -n "${prompt_rel}" ]; then
				prompt_abs="${MCPBASH_ROOT}/${prompt_rel}"
			fi
			(
				cd "${MCPBASH_ROOT}" || exit 1
				# shellcheck disable=SC2030,SC2031
				export \
					MCP_COMPLETION_NAME="${name}" \
					MCP_COMPLETION_ARGS_JSON="${args_json}" \
					MCP_COMPLETION_LIMIT="${limit}" \
					MCP_COMPLETION_OFFSET="${offset}" \
					MCP_COMPLETION_ARGS_HASH="${args_hash}" \
					MCP_PROMPT_REL_PATH="${prompt_rel}" \
					MCP_PROMPT_PATH="${prompt_abs}" \
					MCP_PROMPT_METADATA="${MCP_COMPLETION_PROVIDER_METADATA}"
				if [ -n "${timeout}" ]; then
					with_timeout "${timeout}" -- "${abs_script}"
				else
					"${abs_script}"
				fi
			) >"${tmp_out}" 2>"${tmp_err}"
		elif [ "${MCP_COMPLETION_PROVIDER_TYPE}" = "resource" ]; then
			local res_rel="${MCP_COMPLETION_PROVIDER_RESOURCE_PATH}"
			local res_abs=""
			if [ -n "${res_rel}" ]; then
				res_abs="${MCPBASH_ROOT}/${res_rel}"
			fi
			(
				cd "${MCPBASH_ROOT}" || exit 1
				# shellcheck disable=SC2030,SC2031
				export \
					MCP_COMPLETION_NAME="${name}" \
					MCP_COMPLETION_ARGS_JSON="${args_json}" \
					MCP_COMPLETION_LIMIT="${limit}" \
					MCP_COMPLETION_OFFSET="${offset}" \
					MCP_COMPLETION_ARGS_HASH="${args_hash}" \
					MCP_RESOURCE_REL_PATH="${res_rel}" \
					MCP_RESOURCE_PATH="${res_abs}" \
					MCP_RESOURCE_URI="${MCP_COMPLETION_PROVIDER_RESOURCE_URI}" \
					MCP_RESOURCE_PROVIDER="${MCP_COMPLETION_PROVIDER_RESOURCE_PROVIDER}" \
					MCP_RESOURCE_METADATA="${MCP_COMPLETION_PROVIDER_METADATA}"
				if [ -n "${timeout}" ]; then
					with_timeout "${timeout}" -- "${abs_script}"
				else
					"${abs_script}"
				fi
			) >"${tmp_out}" 2>"${tmp_err}"
		else
			(
				cd "${MCPBASH_ROOT}" || exit 1
				# shellcheck disable=SC2030,SC2031
				export \
					MCP_COMPLETION_NAME="${name}" \
					MCP_COMPLETION_ARGS_JSON="${args_json}" \
					MCP_COMPLETION_LIMIT="${limit}" \
					MCP_COMPLETION_OFFSET="${offset}" \
					MCP_COMPLETION_ARGS_HASH="${args_hash}"
				if [ -n "${timeout}" ]; then
					with_timeout "${timeout}" -- "${abs_script}"
				else
					"${abs_script}"
				fi
			) >"${tmp_out}" 2>"${tmp_err}"
		fi
		status=$?
		script_output="$(cat "${tmp_out}" 2>/dev/null || true)"
		stderr_output="$(cat "${tmp_err}" 2>/dev/null || true)"
		rm -f "${tmp_out}" "${tmp_err}"
		if [ "${status}" -ne 0 ]; then
			# shellcheck disable=SC2034
			MCP_COMPLETION_PROVIDER_RESULT_ERROR="${stderr_output:-Completion provider failed}"
			return 1
		fi
		if ! normalized="$(mcp_completion_normalize_output "${script_output}" "${limit}" "${offset}")"; then
			# shellcheck disable=SC2034
			MCP_COMPLETION_PROVIDER_RESULT_ERROR="Completion provider emitted invalid JSON"
			return 1
		fi
		;;
	*)
		MCP_COMPLETION_PROVIDER_RESULT_ERROR="Unknown completion provider"
		return 1
		;;
	esac

	local suggestions_json has_more_flag next_index cursor_value
	if ! suggestions_json="$(
		NORMALIZED="${normalized}" "${py}" <<'PY'
import json, os
data = json.loads(os.environ.get("NORMALIZED", "{}"))
print(json.dumps(data.get("suggestions", []), ensure_ascii=False, separators=(',', ':')))
PY
	)"; then
		# shellcheck disable=SC2034
		MCP_COMPLETION_PROVIDER_RESULT_ERROR="Unable to parse completion suggestions"
		return 1
	fi
	if ! has_more_flag="$(
		NORMALIZED="${normalized}" "${py}" <<'PY'
import json, os
data = json.loads(os.environ.get("NORMALIZED", "{}"))
print("true" if data.get("hasMore") else "false")
PY
	)"; then
		# shellcheck disable=SC2034
		MCP_COMPLETION_PROVIDER_RESULT_ERROR="Unable to parse completion hasMore flag"
		return 1
	fi
	if ! next_index="$(
		NORMALIZED="${normalized}" "${py}" <<'PY'
import json, os
data = json.loads(os.environ.get("NORMALIZED", "{}"))
value = data.get("next")
if value is None:
    print("")
else:
    print(str(int(value)))
PY
	)"; then
		next_index=""
	fi
	if ! cursor_value="$(
		NORMALIZED="${normalized}" "${py}" <<'PY'
import json, os
data = json.loads(os.environ.get("NORMALIZED", "{}"))
cursor = data.get("cursor")
print(cursor if isinstance(cursor, str) else "")
PY
	)"; then
		cursor_value=""
	fi

	# shellcheck disable=SC2034
	MCP_COMPLETION_PROVIDER_RESULT_SUGGESTIONS="${suggestions_json}"
	# shellcheck disable=SC2034
	MCP_COMPLETION_PROVIDER_RESULT_HAS_MORE="${has_more_flag}"
	# shellcheck disable=SC2034
	MCP_COMPLETION_PROVIDER_RESULT_NEXT="${next_index}"
	# shellcheck disable=SC2034
	MCP_COMPLETION_PROVIDER_RESULT_CURSOR="${cursor_value}"
	return 0
}

mcp_completion_reset() {
	mcp_completion_suggestions="[]"
	mcp_completion_has_more=false
	mcp_completion_cursor=""
}

mcp_completion_suggestions_count() {
	local py
	if ! py="$(mcp_tools_python 2>/dev/null)"; then
		printf '0'
		return 0
	fi
	printf '%s' "$(
		SUGGESTIONS="${mcp_completion_suggestions}" "${py}" <<'PY'
import json, os
try:
    print(len(json.loads(os.environ.get("SUGGESTIONS", "[]"))))
except Exception:
    print(0)
PY
	)"
}

mcp_completion_add_text() {
	local text="$1"
	local py
	local count
	count="$(mcp_completion_suggestions_count)"
	if [ "${count}" -ge 100 ]; then
		mcp_completion_has_more=true
		return 1
	fi
	if ! py="$(mcp_tools_python 2>/dev/null)"; then
		mcp_completion_suggestions="[]"
		return 1
	fi
	mcp_completion_suggestions="$(
		SUGGESTIONS="${mcp_completion_suggestions}" TEXT="${text}" "${py}" <<'PY'
import json, os
suggestions = json.loads(os.environ.get("SUGGESTIONS", "[]"))
text = os.environ.get("TEXT", "")
suggestions.append({"type": "text", "text": text})
print(json.dumps(suggestions, ensure_ascii=False, separators=(',', ':')))
PY
	)"
	return 0
}

mcp_completion_add_json() {
	local json_payload="$1"
	local py
	local count
	count="$(mcp_completion_suggestions_count)"
	if [ "${count}" -ge 100 ]; then
		mcp_completion_has_more=true
		return 1
	fi
	if ! py="$(mcp_tools_python 2>/dev/null)"; then
		mcp_completion_suggestions="[]"
		return 1
	fi
	mcp_completion_suggestions="$(
		SUGGESTIONS="${mcp_completion_suggestions}" PAYLOAD="${json_payload}" "${py}" <<'PY'
import json, os
suggestions = json.loads(os.environ.get("SUGGESTIONS", "[]"))
payload = json.loads(os.environ.get("PAYLOAD", "{}"))
suggestions.append(payload)
print(json.dumps(suggestions, ensure_ascii=False, separators=(',', ':')))
PY
	)"
	return 0
}

mcp_completion_finalize() {
	local py
	if ! py="$(mcp_tools_python 2>/dev/null)"; then
		printf '{"suggestions":[],"hasMore":false}'
		return 0
	fi
	local has_more_json="false"
	if [ "${mcp_completion_has_more}" = true ]; then
		has_more_json="true"
	fi
	printf '%s' "$(
		SUGGESTIONS="${mcp_completion_suggestions}" HAS_MORE="${has_more_json}" CURSOR="${mcp_completion_cursor}" "${py}" <<'PY'
import json, os
suggestions = json.loads(os.environ.get("SUGGESTIONS", "[]"))
has_more = os.environ.get("HAS_MORE", "false") == "true"
cursor = os.environ.get("CURSOR", "")
result = {"suggestions": suggestions, "hasMore": has_more}
if cursor:
    result["cursor"] = cursor
print(json.dumps(result, ensure_ascii=False, separators=(',', ':')))
PY
	)"
}
