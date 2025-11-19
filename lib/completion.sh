#!/usr/bin/env bash
# Completion router helpers (manual registry, cursor management, script dispatch).

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

mcp_completion_hash_string() {
	local value="$1"
	if command -v sha256sum >/dev/null 2>&1; then
		printf '%s' "${value}" | sha256sum | awk '{print $1}'
		return 0
	fi
	if command -v shasum >/dev/null 2>&1; then
		printf '%s' "${value}" | shasum -a 256 | awk '{print $1}'
		return 0
	fi
	printf '%s' "${value}" | cksum | awk '{print $1}'
}

mcp_completion_hash_json() {
	local json_payload="$1"
	local compact
	if ! compact="$(printf '%s' "${json_payload}" | jq -c '.' 2>/dev/null)"; then
		compact="{}"
	fi
	mcp_completion_hash_string "${compact}"
}

mcp_completion_resolve_script_path() {
	local raw_path="$1"
	local root="${MCPBASH_ROOT%/}"
	local candidate=""
	if [ -z "${raw_path}" ]; then
		return 1
	fi
	if [ "${raw_path#/}" != "${raw_path}" ]; then
		candidate="${raw_path}"
	else
		candidate="${root}/${raw_path}"
	fi
	local dir base abs
	dir="$(dirname -- "${candidate}")"
	base="$(basename -- "${candidate}")"
	if ! dir="$(cd "${dir}" 2>/dev/null && pwd -P)"; then
		return 1
	fi
	abs="${dir}/${base}"
	case "${abs}" in
	"${root}" | "${root}/"*) ;;
	*) return 1 ;;
	esac
	if [ ! -f "${abs}" ]; then
		return 1
	fi
	printf '%s' "${abs#${root}/}"
}

mcp_completion_base64_urlencode() {
	tr '+/' '-_' | tr -d '='
}

mcp_completion_base64_urldecode() {
	local input="$1"
	if [ -z "${input}" ]; then
		return 1
	fi
	local converted="${input//-/+}"
	converted="${converted//_/\/}"
	local remainder=$(( ${#converted} % 4 ))
	if [ "${remainder}" -ne 0 ]; then
		local pad=$((4 - remainder))
		case "${pad}" in
		1) converted="${converted}=" ;;
		2) converted="${converted}==" ;;
		3) converted="${converted}===" ;;
		esac
	fi
	local decoded
	if decoded="$(printf '%s' "${converted}" | base64 --decode 2>/dev/null)"; then
		printf '%s' "${decoded}"
		return 0
	fi
	if decoded="$(printf '%s' "${converted}" | base64 -d 2>/dev/null)"; then
		printf '%s' "${decoded}"
		return 0
	fi
	if decoded="$(printf '%s' "${converted}" | base64 -D 2>/dev/null)"; then
		printf '%s' "${decoded}"
		return 0
	fi
	if command -v openssl >/dev/null 2>&1; then
		if decoded="$(printf '%s' "${converted}" | openssl base64 -d -A 2>/dev/null)"; then
			printf '%s' "${decoded}"
			return 0
		fi
	fi
	return 1
}

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
	local tmp_file
	tmp_file="$(mktemp "${MCPBASH_TMP_ROOT}/mcp-completions-manual.XXXXXX")"
	local seen_names=""
	local error=""

	local completion_entries
	if ! completion_entries="$(printf '%s' "${manual_json}" | jq -c '.completions // [] | .[]' 2>/dev/null)"; then
		rm -f "${tmp_file}"
		return 1
	fi

	while IFS= read -r entry || [ -n "${entry}" ]; do
		[ -z "${entry}" ] && continue
		local name path timeout rel_path
		if ! name="$(printf '%s' "${entry}" | jq -r '.name // ""' 2>/dev/null)"; then
			error="Completion entry missing name"
			break
		fi
		name="${name//[[:space:]]/ }"
		name="${name#"${name%%[![:space:]]*}"}"
		name="${name%"${name##*[![:space:]]}"}"
		if [ -z "${name}" ]; then
			error="Completion entry missing name"
			break
		fi
		if printf '%s\n' "${seen_names}" | grep -Fxq "${name}"; then
			error="Duplicate completion name ${name}"
			break
		fi
		if ! path="$(printf '%s' "${entry}" | jq -r '.path // ""' 2>/dev/null)"; then
			error="Completion ${name} missing path"
			break
		fi
		if ! rel_path="$(mcp_completion_resolve_script_path "${path}")"; then
			error="Completion path ${path} invalid or outside server root"
			break
		fi
		timeout="$(printf '%s' "${entry}" | jq -r '.timeoutSecs // ""' 2>/dev/null || printf '')"
		local timeout_arg=""
		if [ -n "${timeout}" ] && [[ "${timeout}" =~ ^-?[0-9]+$ ]]; then
			timeout_arg="true"
		else
			timeout=""
		fi
		if ! jq -n \
			--arg name "${name}" \
			--arg path "${rel_path}" \
			--arg timeout "${timeout}" \
			--arg timeout_flag "${timeout_arg}" \
			'{
				name: $name,
				path: $path,
				kind: "shell"
			}
			+ (if $timeout_flag == "true" then {timeoutSecs: ($timeout|tonumber)} else {} end)' >>"${tmp_file}"; then
			error="Unable to build completion entry"
			break
		fi
		seen_names="${seen_names}
${name}"
	done <<<"${completion_entries}"

	if [ -n "${error}" ]; then
		rm -f "${tmp_file}"
		mcp_logging_error "${MCP_COMPLETION_LOGGER}" "${error}"
		return 1
	fi

	local items_json
	items_json="$(jq -s 'sort_by(.name)' "${tmp_file}")" || {
		rm -f "${tmp_file}"
		return 1
	}
	rm -f "${tmp_file}"

	local timestamp hash total
	timestamp="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
	hash="$(mcp_completion_hash_string "${items_json}")"
	total="$(printf '%s' "${items_json}" | jq 'length')"

	MCP_COMPLETION_MANUAL_REGISTRY_JSON="$(jq -n \
		--arg ts "${timestamp}" \
		--arg hash "${hash}" \
		--argjson items "${items_json}" \
		--argjson total "${total}" \
		'{version: 1, generatedAt: $ts, items: $items, hash: $hash, total: $total}')"
	MCP_COMPLETION_MANUAL_LOADED=true
	return 0
}

mcp_completion_manual_finalize() {
	if [ "${MCP_COMPLETION_MANUAL_ACTIVE}" != "true" ]; then
		return 0
	fi
	local manual_json
	if [ -z "${MCP_COMPLETION_MANUAL_BUFFER}" ]; then
		manual_json='{"completions":[]}'
	else
		local manual_entries
		manual_entries="$(printf '%s' "${MCP_COMPLETION_MANUAL_BUFFER}" | tr "${MCP_COMPLETION_MANUAL_DELIM}" '\n')"
		if ! manual_json="$(printf '%s' "${manual_entries}" | jq -s '{completions: .}' 2>/dev/null)"; then
			mcp_completion_manual_abort
			return 1
		fi
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
	local entry
	if ! entry="$(printf '%s' "${MCP_COMPLETION_MANUAL_REGISTRY_JSON}" | jq -c --arg name "${name}" '.items[] | select(.name == $name)' | head -n 1)"; then
		return 1
	fi
	[ -z "${entry}" ] && return 1
	printf '%s' "${entry}"
	return 0
}

mcp_completion_args_hash() {
	local args_json="$1"
	local normalized
	if ! normalized="$(printf '%s' "${args_json:-{}}" | jq -S -c '.' 2>/dev/null)"; then
		normalized="{}"
	fi
	mcp_completion_hash_string "${normalized}"
}

mcp_completion_encode_cursor() {
	local name="$1"
	local args_hash="$2"
	local offset="$3"
	local script_key="$4"
	local offset_value="${offset:-0}"
	case "${offset_value}" in
	'' | *[!0-9]*) offset_value=0 ;;
	esac
	local payload
	if ! payload="$(jq -n \
		--arg name "${name}" \
		--arg hash "${args_hash}" \
		--argjson offset "${offset_value}" \
		--arg script "${script_key}" \
		'{ver: 1, kind: "completion", name: $name, args: $hash, offset: ($offset|tonumber), script: $script}')"; then
		return 1
	fi
	printf '%s' "${payload}" | base64 | tr -d '\n' | mcp_completion_base64_urlencode
}

mcp_completion_decode_cursor() {
	local cursor="$1"
	local expected_name="$2"
	local expected_hash="$3"
	local decoded payload offset script hash name
	if ! decoded="$(mcp_completion_base64_urldecode "${cursor}")"; then
		return 1
	fi
	if ! payload="$(printf '%s' "${decoded}" | jq -c '.' 2>/dev/null)"; then
		return 1
	fi
	name="$(printf '%s' "${payload}" | jq -r '.name // empty')" || return 1
	hash="$(printf '%s' "${payload}" | jq -r '.args // empty')" || return 1
	if [ -z "${name}" ] || [ "${name}" != "${expected_name}" ]; then
		return 1
	fi
	if [ -n "${expected_hash}" ] && [ "${hash}" != "${expected_hash}" ]; then
		return 1
	fi
	offset="$(printf '%s' "${payload}" | jq -r '.offset // 0')" || return 1
	if ! [[ "${offset}" =~ ^[0-9]+$ ]]; then
		return 1
	fi
	script="$(printf '%s' "${payload}" | jq -r '.script // ""')" || script=""
	# shellcheck disable=SC2034
	MCP_COMPLETION_CURSOR_OFFSET="${offset}"
	# shellcheck disable=SC2034
	MCP_COMPLETION_CURSOR_SCRIPT_KEY="${script}"
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
	local rel_path
	if ! rel_path="$(printf '%s' "${metadata}" | jq -r '.path // ""' 2>/dev/null)"; then
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
	local rel_path
	if ! rel_path="$(printf '%s' "${metadata}" | jq -r '.path // ""' 2>/dev/null)"; then
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
		if ! script_rel="$(printf '%s' "${entry}" | jq -r '.path // ""' 2>/dev/null)"; then
			return 1
		fi
		[ -z "${script_rel}" ] && return 1
		MCP_COMPLETION_PROVIDER_TYPE="manual"
		MCP_COMPLETION_PROVIDER_SCRIPT="${script_rel}"
		MCP_COMPLETION_PROVIDER_SCRIPT_KEY="manual:${script_rel}"
		MCP_COMPLETION_PROVIDER_TIMEOUT="$(printf '%s' "${entry}" | jq -r '.timeoutSecs // ""' 2>/dev/null)"
		return 0
	fi

	if metadata="$(mcp_prompts_metadata_for_name "${name}")"; then
		if script_rel="$(mcp_completion_prompt_script "${metadata}")"; then
			MCP_COMPLETION_PROVIDER_TYPE="prompt"
			MCP_COMPLETION_PROVIDER_METADATA="${metadata}"
			MCP_COMPLETION_PROVIDER_SCRIPT="${script_rel}"
			MCP_COMPLETION_PROVIDER_PROMPT_TEMPLATE="$(printf '%s' "${metadata}" | jq -r '.path // ""' 2>/dev/null)"
			MCP_COMPLETION_PROVIDER_SCRIPT_KEY="prompt:${script_rel}"
			return 0
		fi
	fi

	if metadata="$(mcp_resources_metadata_for_name "${name}")"; then
		if script_rel="$(mcp_completion_resource_script "${metadata}")"; then
			MCP_COMPLETION_PROVIDER_TYPE="resource"
			MCP_COMPLETION_PROVIDER_METADATA="${metadata}"
			MCP_COMPLETION_PROVIDER_SCRIPT="${script_rel}"
			MCP_COMPLETION_PROVIDER_RESOURCE_PATH="$(printf '%s' "${metadata}" | jq -r '.path // ""' 2>/dev/null)"
			MCP_COMPLETION_PROVIDER_RESOURCE_URI="$(printf '%s' "${metadata}" | jq -r '.uri // ""' 2>/dev/null)"
			MCP_COMPLETION_PROVIDER_RESOURCE_PROVIDER="$(printf '%s' "${metadata}" | jq -r '.provider // ""' 2>/dev/null)"
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
	local limit="${2:-5}"
	local start="${3:-0}"
	printf '%s' "$(
		jq -n \
			--arg raw "${script_output}" \
			--argjson limit "${limit}" \
			--argjson start "${start}" '
				def parse($text):
					if ($text | length) == 0 then null
					else (try ($text | fromjson) catch null)
					end;
				def bool($value):
					if ($value | type) == "boolean" then $value else false end;
				def numeric_or_null($value):
					try ($value | tonumber) catch null end;

				(parse($raw)) as $payload
				| if $payload == null then
					{suggestions: [], hasMore: false, next: null, cursor: ""}
				elif ($payload | type) == "array" then
					{suggestions: $payload, hasMore: false, next: null, cursor: ""}
				else
					{
						suggestions: ($payload.suggestions // []),
						hasMore: bool($payload.hasMore),
						next: $payload.next,
						cursor: ($payload.cursor // "")
					}
				end
				| .suggestions as $all
				| ($all | length) as $total
				| (.suggestions = $all[0:$limit])
				| (.hasMore = (bool(.hasMore) or ($total > $limit)))
				| (.next = (
					if .next == null then
						if .hasMore then ($start + (.suggestions | length)) else null end
					else
						numeric_or_null(.next)
					end))
				| (.cursor = (if (.cursor | type) == "string" then .cursor else "" end))
			'
	)"
}

mcp_completion_builtin_generate() {
	local name="$1"
	local args_json="$2"
	local limit="${3:-5}"
	local offset="${4:-0}"
	local parsed_args
	if ! parsed_args="$(printf '%s' "${args_json:-{}}" | jq -c '.' 2>/dev/null)"; then
		parsed_args="{}"
	fi
	printf '%s' "$(
		jq -n \
			--arg name "${name}" \
			--argjson args "${parsed_args}" \
			--argjson limit "${limit}" \
			--argjson offset "${offset}" '
				def trim($s):
					$s | gsub("^[[:space:]]+";"") | gsub("[[:space:]]+$";"");

				($args.query // $args.prefix // "") as $query
				| (trim($query | tostring)) as $trimmed_query
				| (trim($name | tostring)) as $trimmed_name
				| ($trimmed_query | if . == "" then $trimmed_name else . end) as $base_candidate
				| ($base_candidate | if . == "" then "suggestion" else . end) as $base
				| [
					{type: "text", text: $base},
					{type: "text", text: ($base + " snippet")},
					{type: "text", text: ($base + " example")}
				] as $candidates
				| ($candidates[$offset:$offset+$limit]) as $limited
				| ($limited | length) as $count
				| ($offset + $limit < ($candidates | length)) as $has_more
				| {
					suggestions: $limited,
					hasMore: $has_more,
					next: (if $has_more then $offset + $count else null end)
				}
			'
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

	local normalized script_output stderr_output status abs_script

	case "${MCP_COMPLETION_PROVIDER_TYPE}" in
	builtin)
		if ! normalized="$(mcp_completion_builtin_generate "${name}" "${args_json}" "${limit}" "${offset}")"; then
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
		abs_script="${MCPBASH_ROOT}/${abs_script}"
		if [ ! -f "${abs_script}" ]; then
			MCP_COMPLETION_PROVIDER_RESULT_ERROR="Completion script not found"
			return 1
		fi
		if [ ! -x "${abs_script}" ]; then
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
			MCP_COMPLETION_PROVIDER_RESULT_ERROR="${stderr_output:-Completion provider failed}"
			return 1
		fi
		if ! normalized="$(mcp_completion_normalize_output "${script_output}" "${limit}" "${offset}")"; then
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
	if ! suggestions_json="$(printf '%s' "${normalized}" | jq -c '.suggestions // []' 2>/dev/null)"; then
		MCP_COMPLETION_PROVIDER_RESULT_ERROR="Unable to parse completion suggestions"
		return 1
	fi
	if ! has_more_flag="$(printf '%s' "${normalized}" | jq -r '.hasMore // false' 2>/dev/null)"; then
		MCP_COMPLETION_PROVIDER_RESULT_ERROR="Unable to parse completion hasMore flag"
		return 1
	fi
	if ! next_index="$(printf '%s' "${normalized}" | jq -r '.next // ""' 2>/dev/null)"; then
		next_index=""
	fi
	if ! cursor_value="$(printf '%s' "${normalized}" | jq -r '.cursor // ""' 2>/dev/null)"; then
		cursor_value=""
	fi

	MCP_COMPLETION_PROVIDER_RESULT_SUGGESTIONS="${suggestions_json}"
	MCP_COMPLETION_PROVIDER_RESULT_HAS_MORE="${has_more_flag}"
	MCP_COMPLETION_PROVIDER_RESULT_NEXT="${next_index}"
	MCP_COMPLETION_PROVIDER_RESULT_CURSOR="${cursor_value}"
	return 0
}

mcp_completion_reset() {
	mcp_completion_suggestions="[]"
	mcp_completion_has_more=false
	mcp_completion_cursor=""
}

mcp_completion_suggestions_count() {
	local count
	if ! count="$(printf '%s' "${mcp_completion_suggestions}" | jq 'length' 2>/dev/null)"; then
		count=0
	fi
	printf '%s' "${count}"
}

mcp_completion_add_text() {
	local text="$1"
	local count
	count="$(mcp_completion_suggestions_count)"
	if [ "${count}" -ge 100 ]; then
		mcp_completion_has_more=true
		return 1
	fi
	if ! mcp_completion_suggestions="$(printf '%s' "${mcp_completion_suggestions}" | jq -c --arg text "${text}" '. + [{type: "text", text: $text}]' 2>/dev/null)"; then
		mcp_completion_suggestions="[]"
		return 1
	fi
	return 0
}

mcp_completion_add_json() {
	local json_payload="$1"
	local count
	count="$(mcp_completion_suggestions_count)"
	if [ "${count}" -ge 100 ]; then
		mcp_completion_has_more=true
		return 1
	fi
	if ! mcp_completion_suggestions="$(printf '%s' "${mcp_completion_suggestions}" | jq -c --argjson payload "${json_payload:-{}}" '. + [$payload]' 2>/dev/null)"; then
		mcp_completion_suggestions="[]"
		return 1
	fi
	return 0
}

mcp_completion_finalize() {
	local has_more_json="false"
	if [ "${mcp_completion_has_more}" = true ]; then
		has_more_json="true"
	fi
	local cursor="${mcp_completion_cursor}"
	printf '%s' "$(
		jq -n \
			--argjson suggestions "${mcp_completion_suggestions}" \
			--argjson has_more "${has_more_json}" \
			--arg cursor "${cursor}" '
				{
					suggestions: $suggestions,
					hasMore: ($has_more == true)
				}
				+ (if $cursor != "" then {cursor: $cursor} else {} end)
			'
	)"
}
