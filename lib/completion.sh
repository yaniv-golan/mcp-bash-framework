#!/usr/bin/env bash
# Completion router helpers (manual registry, cursor management, script dispatch).

set -euo pipefail

MCP_COMPLETION_LOGGER="${MCP_COMPLETION_LOGGER:-mcp.completion}"

if ! command -v mcp_env_run_curated >/dev/null 2>&1; then
	# shellcheck source=lib/runtime.sh disable=SC1090,SC1091
	. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/runtime.sh"
fi

mcp_completion_suggestions="[]"
mcp_completion_has_more=false
mcp_completion_cursor=""

MCP_COMPLETION_MANUAL_ACTIVE=false
MCP_COMPLETION_MANUAL_BUFFER=""
MCP_COMPLETION_MANUAL_DELIM=$'\036'
MCP_COMPLETION_MANUAL_REGISTRY_JSON=""
MCP_COMPLETION_MANUAL_LOADED=false

mcp_completion_manual_buffer_limit() {
	local limit="${MCPBASH_MANUAL_BUFFER_MAX_BYTES:-1048576}"
	case "${limit}" in
	'' | *[!0-9]*) limit=1048576 ;;
	esac
	printf '%s' "${limit}"
}

MCP_COMPLETION_PROVIDER_TYPE=""
MCP_COMPLETION_PROVIDER_SCRIPT=""
MCP_COMPLETION_PROVIDER_METADATA=""
MCP_COMPLETION_PROVIDER_SCRIPT_KEY=""
MCP_COMPLETION_PROVIDER_TIMEOUT=""
MCP_COMPLETION_PROVIDER_PROMPT_TEMPLATE=""
MCP_COMPLETION_PROVIDER_RESOURCE_PATH=""
MCP_COMPLETION_PROVIDER_RESOURCE_URI=""
MCP_COMPLETION_PROVIDER_RESOURCE_PROVIDER=""
# shellcheck disable=SC2034
MCP_COMPLETION_PROVIDER_RESULT_SUGGESTIONS="[]"
# shellcheck disable=SC2034
MCP_COMPLETION_PROVIDER_RESULT_HAS_MORE="false"
# shellcheck disable=SC2034
MCP_COMPLETION_PROVIDER_RESULT_NEXT=""
# shellcheck disable=SC2034
MCP_COMPLETION_PROVIDER_RESULT_CURSOR=""
# shellcheck disable=SC2034
MCP_COMPLETION_PROVIDER_RESULT_ERROR=""

MCP_COMPLETION_CURSOR_OFFSET=0
MCP_COMPLETION_CURSOR_SCRIPT_KEY=""

mcp_completion_hash_string() {
	local value="$1"
	mcp_hash_string "${value}"
}

mcp_completion_hash_json() {
	local json_payload="$1"
	local compact
	compact="$(printf '%s' "${json_payload}" | "${MCPBASH_JSON_TOOL_BIN}" -c '.' 2>/dev/null || printf '{}')"
	mcp_hash_json_payload "${compact}"
}

mcp_completion_resolve_script_path() {
	local raw_path="$1"
	local root="${MCPBASH_PROJECT_ROOT%/}"
	# Normalize project root to a physical path (macOS: /tmp -> /private/tmp).
	# Otherwise, later prefix checks can fail when the candidate resolves via pwd -P.
	local root_phys=""
	if root_phys="$(cd "${root}" 2>/dev/null && pwd -P)"; then
		root="${root_phys}"
	fi
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
	printf '%s' "${abs#"${root}"/}"
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
	local remainder=$((${#converted} % 4))
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
	local new_buffer
	if [ -n "${MCP_COMPLETION_MANUAL_BUFFER}" ]; then
		new_buffer="${MCP_COMPLETION_MANUAL_BUFFER}${MCP_COMPLETION_MANUAL_DELIM}${payload}"
	else
		new_buffer="${payload}"
	fi
	local limit
	limit="$(mcp_completion_manual_buffer_limit)"
	if [ "${limit}" -gt 0 ] && [ "${#new_buffer}" -gt "${limit}" ]; then
		mcp_completion_manual_abort
		mcp_logging_error "${MCP_COMPLETION_LOGGER}" "Manual completion buffer exceeded ${limit} bytes"
		return 1
	fi
	MCP_COMPLETION_MANUAL_BUFFER="${new_buffer}"
	return 0
}

mcp_completion_apply_manual_json() {
	local manual_json="$1"
	local tmp_file
	tmp_file="$(mktemp "${MCPBASH_TMP_ROOT}/mcp-completions-manual.XXXXXX")"
	local seen_names=""
	local error=""

	local completion_entries
	if ! completion_entries="$(printf '%s' "${manual_json}" | "${MCPBASH_JSON_TOOL_BIN}" -c '.completions // [] | .[]' 2>/dev/null)"; then
		rm -f "${tmp_file}"
		return 1
	fi

	while IFS= read -r entry || [ -n "${entry}" ]; do
		[ -z "${entry}" ] && continue
		local name path timeout rel_path
		if ! name="$(printf '%s' "${entry}" | "${MCPBASH_JSON_TOOL_BIN}" -r '.name // ""' 2>/dev/null)"; then
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
		if ! path="$(printf '%s' "${entry}" | "${MCPBASH_JSON_TOOL_BIN}" -r '.path // ""' 2>/dev/null)"; then
			error="Completion ${name} missing path"
			break
		fi
		if ! rel_path="$(mcp_completion_resolve_script_path "${path}")"; then
			error="Completion path ${path} invalid or outside server root"
			break
		fi
		timeout="$(printf '%s' "${entry}" | "${MCPBASH_JSON_TOOL_BIN}" -r '.timeoutSecs // ""' 2>/dev/null || printf '')"
		local timeout_arg=""
		if [ -n "${timeout}" ] && [[ "${timeout}" =~ ^-?[0-9]+$ ]]; then
			timeout_arg="true"
		else
			timeout=""
		fi
		if ! "${MCPBASH_JSON_TOOL_BIN}" -n \
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
	items_json="$("${MCPBASH_JSON_TOOL_BIN}" -s 'sort_by(.name)' "${tmp_file}" 2>/dev/null)" || {
		rm -f "${tmp_file}"
		return 1
	}
	rm -f "${tmp_file}"

	local timestamp hash total
	timestamp="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
	hash="$(mcp_completion_hash_string "${items_json}")"
	total="$(printf '%s' "${items_json}" | "${MCPBASH_JSON_TOOL_BIN}" 'length' 2>/dev/null)" || total=0
	# Ensure total is a valid number
	case "${total}" in
	'' | *[!0-9]*) total=0 ;;
	esac

	MCP_COMPLETION_MANUAL_REGISTRY_JSON="$("${MCPBASH_JSON_TOOL_BIN}" -n \
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
		if ! manual_json="$(printf '%s' "${manual_entries}" | "${MCPBASH_JSON_TOOL_BIN}" -s '{completions: .}' 2>/dev/null)"; then
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

mcp_completion_refresh_manual() {
	if [ "${MCP_COMPLETION_MANUAL_LOADED}" = true ]; then
		return 0
	fi
	if mcp_registry_register_apply "completions"; then
		MCP_COMPLETION_MANUAL_LOADED=true
		return 0
	else
		local manual_status=$?
		if [ "${manual_status}" -eq 2 ]; then
			local err
			err="$(mcp_registry_register_error_for_kind "completions")"
			if [ -z "${err}" ]; then
				err="Manual completion registration failed"
			fi
			mcp_logging_error "${MCP_COMPLETION_LOGGER}" "${err}"
			return 1
		fi
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
	if ! entry="$(printf '%s' "${MCP_COMPLETION_MANUAL_REGISTRY_JSON}" | "${MCPBASH_JSON_TOOL_BIN}" -c --arg name "${name}" '.items[] | select(.name == $name)' | head -n 1)"; then
		return 1
	fi
	[ -z "${entry}" ] && return 1
	printf '%s' "${entry}"
	return 0
}

mcp_completion_args_hash() {
	local args_json="$1"
	local normalized
	if ! normalized="$(printf '%s' "${args_json:-"{}"}" | "${MCPBASH_JSON_TOOL_BIN}" -S -c '.' 2>/dev/null)"; then
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
	if ! payload="$("${MCPBASH_JSON_TOOL_BIN}" -n \
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
	local allow_hash_mismatch="${4:-false}"
	local decoded payload offset script hash name
	if ! decoded="$(mcp_completion_base64_urldecode "${cursor}")"; then
		return 1
	fi
	if ! payload="$(printf '%s' "${decoded}" | "${MCPBASH_JSON_TOOL_BIN}" -c '.' 2>/dev/null)"; then
		return 1
	fi
	name="$(printf '%s' "${payload}" | "${MCPBASH_JSON_TOOL_BIN}" -r '.name // empty')" || return 1
	hash="$(printf '%s' "${payload}" | "${MCPBASH_JSON_TOOL_BIN}" -r '.args // empty')" || return 1
	if [ -z "${name}" ] || [ "${name}" != "${expected_name}" ]; then
		return 1
	fi
	if [ "${allow_hash_mismatch}" != "true" ] && [ -n "${expected_hash}" ] && [ "${hash}" != "${expected_hash}" ]; then
		return 1
	fi
	offset="$(printf '%s' "${payload}" | "${MCPBASH_JSON_TOOL_BIN}" -r '.offset // 0')" || return 1
	if ! [[ "${offset}" =~ ^[0-9]+$ ]]; then
		return 1
	fi
	script="$(printf '%s' "${payload}" | "${MCPBASH_JSON_TOOL_BIN}" -r '.script // ""')" || script=""
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
	if ! rel_path="$(printf '%s' "${metadata}" | "${MCPBASH_JSON_TOOL_BIN}" -r '.path // ""' 2>/dev/null)"; then
		return 1
	fi
	local candidate
	while IFS= read -r candidate; do
		[ -z "${candidate}" ] && continue
		if [ -x "${MCPBASH_PROMPTS_DIR}/${candidate}" ]; then
			printf '%s' "${candidate}"
			return 0
		fi
	done < <(mcp_completion_candidates_for_path "${rel_path}")
	return 1
}

mcp_completion_resource_script() {
	local metadata="$1"
	local rel_path
	if ! rel_path="$(printf '%s' "${metadata}" | "${MCPBASH_JSON_TOOL_BIN}" -r '.path // ""' 2>/dev/null)"; then
		return 1
	fi
	local candidate
	while IFS= read -r candidate; do
		[ -z "${candidate}" ] && continue
		if [ -x "${MCPBASH_RESOURCES_DIR}/${candidate}" ]; then
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
		if ! script_rel="$(printf '%s' "${entry}" | "${MCPBASH_JSON_TOOL_BIN}" -r '.path // ""' 2>/dev/null)"; then
			return 1
		fi
		[ -z "${script_rel}" ] && return 1
		MCP_COMPLETION_PROVIDER_TYPE="manual"
		MCP_COMPLETION_PROVIDER_SCRIPT="${script_rel}"
		MCP_COMPLETION_PROVIDER_SCRIPT_KEY="manual:${script_rel}"
		MCP_COMPLETION_PROVIDER_TIMEOUT="$(printf '%s' "${entry}" | "${MCPBASH_JSON_TOOL_BIN}" -r '.timeoutSecs // ""' 2>/dev/null)"
		return 0
	fi

	if metadata="$(mcp_prompts_metadata_for_name "${name}")"; then
		if script_rel="$(mcp_completion_prompt_script "${metadata}")"; then
			MCP_COMPLETION_PROVIDER_TYPE="prompt"
			MCP_COMPLETION_PROVIDER_METADATA="${metadata}"
			MCP_COMPLETION_PROVIDER_SCRIPT="${script_rel}"
			MCP_COMPLETION_PROVIDER_PROMPT_TEMPLATE="$(printf '%s' "${metadata}" | "${MCPBASH_JSON_TOOL_BIN}" -r '.path // ""' 2>/dev/null)"
			MCP_COMPLETION_PROVIDER_SCRIPT_KEY="prompt:${script_rel}"
			return 0
		fi
	fi

	if metadata="$(mcp_resources_metadata_for_name "${name}")"; then
		if script_rel="$(mcp_completion_resource_script "${metadata}")"; then
			MCP_COMPLETION_PROVIDER_TYPE="resource"
			MCP_COMPLETION_PROVIDER_METADATA="${metadata}"
			MCP_COMPLETION_PROVIDER_SCRIPT="${script_rel}"
			MCP_COMPLETION_PROVIDER_RESOURCE_PATH="$(printf '%s' "${metadata}" | "${MCPBASH_JSON_TOOL_BIN}" -r '.path // ""' 2>/dev/null)"
			MCP_COMPLETION_PROVIDER_RESOURCE_URI="$(printf '%s' "${metadata}" | "${MCPBASH_JSON_TOOL_BIN}" -r '.uri // ""' 2>/dev/null)"
			MCP_COMPLETION_PROVIDER_RESOURCE_PROVIDER="$(printf '%s' "${metadata}" | "${MCPBASH_JSON_TOOL_BIN}" -r '.provider // ""' 2>/dev/null)"
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
	local out=""
	if ! out="$(
		"${MCPBASH_JSON_TOOL_BIN}" -n -c \
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
					(try ($value | tonumber) catch null);
				def ensure_string_array($value):
					if ($value | type) != "array" then error("suggestions must be an array")
					elif ([ $value[] | type ] | all(. == "string")) then $value
					else error("suggestions must be string[]")
					end;

				(parse($raw)) as $payload
				| if $payload == null then
					{suggestions: [], hasMore: false, next: null, cursor: ""}
				elif ($payload | type) == "array" then
					{suggestions: ensure_string_array($payload), hasMore: false, next: null, cursor: ""}
				else
					{
						suggestions: ensure_string_array(($payload.suggestions // [])),
						hasMore: bool($payload.hasMore),
						next: $payload.next,
						cursor: ($payload.nextCursor // $payload.cursor // "")
					}
				end
				| .suggestions as $all
				| ($all | length) as $total
				| (.suggestions = $all[0:$limit])
				| (.hasMore = (bool(.hasMore) or ($total > $limit) or ((.cursor // "") | length > 0)))
				| (.next = (
					if .next == null then
						if .hasMore then ($start + (.suggestions | length)) else null end
					else
						numeric_or_null(.next)
					end))
				| (.cursor = (if (.cursor | type) == "string" then .cursor else "" end))
			'
	)"; then
		return 1
	fi
	printf '%s' "${out}"
}

mcp_completion_builtin_generate() {
	local name="$1"
	local query_value="$2"
	local limit="${3:-5}"
	local offset="${4:-0}"
	local trimmed_query trimmed_name base_candidate base

	trimmed_query="$(printf '%s' "${query_value}" | sed -e 's/^[[:space:]]\+//' -e 's/[[:space:]]\+$//')"
	trimmed_name="$(printf '%s' "${name}" | sed -e 's/^[[:space:]]\+//' -e 's/[[:space:]]\+$//')"
	if [ -n "${trimmed_query}" ]; then
		base_candidate="${trimmed_query}"
	else
		base_candidate="${trimmed_name}"
	fi
	if [ -z "${base_candidate}" ]; then
		base_candidate="suggestion"
	fi
	base="${base_candidate}"

	printf '%s' "$(
		"${MCPBASH_JSON_TOOL_BIN}" -n -c \
			--arg base "${base}" \
			--arg base_snippet "${base} snippet" \
			--arg base_example "${base} example" \
			--argjson limit "${limit}" \
			--argjson offset "${offset}" '
				[
					$base,
					$base_snippet,
					$base_example
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
	local query_value="$3"
	local limit="$4"
	local offset="$5"
	local args_hash="$6"

	MCP_COMPLETION_PROVIDER_RESULT_SUGGESTIONS="[]"
	MCP_COMPLETION_PROVIDER_RESULT_HAS_MORE="false"
	MCP_COMPLETION_PROVIDER_RESULT_NEXT=""
	MCP_COMPLETION_PROVIDER_RESULT_CURSOR=""
	MCP_COMPLETION_PROVIDER_RESULT_ERROR=""

	local normalized script_output stderr_output status abs_script

	case "${MCP_COMPLETION_PROVIDER_TYPE}" in
	builtin)
		if ! normalized="$(mcp_completion_builtin_generate "${name}" "${query_value}" "${limit}" "${offset}")"; then
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
		# Resolve absolute path based on provider type:
		# - manual: paths are relative to PROJECT_ROOT
		# - prompt: paths are relative to PROMPTS_DIR
		# - resource: paths are relative to RESOURCES_DIR
		case "${MCP_COMPLETION_PROVIDER_TYPE}" in
		manual) abs_script="${MCPBASH_PROJECT_ROOT}/${abs_script}" ;;
		prompt) abs_script="${MCPBASH_PROMPTS_DIR}/${abs_script}" ;;
		resource) abs_script="${MCPBASH_RESOURCES_DIR}/${abs_script}" ;;
		esac
		if [ ! -f "${abs_script}" ]; then
			MCP_COMPLETION_PROVIDER_RESULT_ERROR="Completion script not found"
			return 1
		fi
		# On Windows (Git Bash/MSYS), -x test is unreliable. If the completion script
		# exists but isn't executable, fall back to invoking it via bash when it
		# looks like a script (shebang or .sh/.bash extension).
		local provider_runner=("${abs_script}")
		if [ ! -x "${abs_script}" ]; then
			local first_line=""
			IFS= read -r first_line <"${abs_script}" 2>/dev/null || first_line=""
			case "${abs_script}" in
			*.sh | *.bash)
				provider_runner=(bash "${abs_script}")
				;;
			*)
				case "${first_line}" in
				'#!'*)
					provider_runner=(bash "${abs_script}")
					;;
				*)
					MCP_COMPLETION_PROVIDER_RESULT_ERROR="Completion script not executable"
					return 1
					;;
				esac
				;;
			esac
		fi
		local tmp_out tmp_err
		tmp_out="$(mktemp "${MCPBASH_TMP_ROOT}/mcp-completion.out.XXXXXX")"
		tmp_err="$(mktemp "${MCPBASH_TMP_ROOT}/mcp-completion.err.XXXXXX")"
		local timeout="${MCP_COMPLETION_PROVIDER_TIMEOUT}"
		if [ "${MCP_COMPLETION_PROVIDER_TYPE}" = "prompt" ]; then
			local prompt_rel="${MCP_COMPLETION_PROVIDER_PROMPT_TEMPLATE}"
			local prompt_abs=""
			if [ -n "${prompt_rel}" ]; then
				prompt_abs="${MCPBASH_PROMPTS_DIR}/${prompt_rel}"
			fi
			(
				cd "${MCPBASH_PROJECT_ROOT}" || exit 1
				local env_pairs=(
					"MCPBASH_JSON_TOOL_BIN=${MCPBASH_JSON_TOOL_BIN}"
					"MCPBASH_JSON_TOOL=${MCPBASH_JSON_TOOL}"
					"MCP_COMPLETION_NAME=${name}"
					"MCP_COMPLETION_ARGS_JSON=${args_json}"
					"MCP_COMPLETION_LIMIT=${limit}"
					"MCP_COMPLETION_OFFSET=${offset}"
					"MCP_COMPLETION_ARGS_HASH=${args_hash}"
					"MCP_PROMPT_REL_PATH=${prompt_rel}"
					"MCP_PROMPT_PATH=${prompt_abs}"
					"MCP_PROMPT_METADATA=${MCP_COMPLETION_PROVIDER_METADATA}"
				)
				if [ -n "${timeout}" ]; then
					with_timeout "${timeout}" -- mcp_env_run_curated provider "${env_pairs[@]}" -- "${provider_runner[@]}"
				else
					mcp_env_run_curated provider "${env_pairs[@]}" -- "${provider_runner[@]}"
				fi
			) >"${tmp_out}" 2>"${tmp_err}"
		elif [ "${MCP_COMPLETION_PROVIDER_TYPE}" = "resource" ]; then
			local res_rel="${MCP_COMPLETION_PROVIDER_RESOURCE_PATH}"
			local res_abs=""
			if [ -n "${res_rel}" ]; then
				res_abs="${MCPBASH_RESOURCES_DIR}/${res_rel}"
			fi
			(
				cd "${MCPBASH_PROJECT_ROOT}" || exit 1
				local env_pairs=(
					"MCPBASH_JSON_TOOL_BIN=${MCPBASH_JSON_TOOL_BIN}"
					"MCPBASH_JSON_TOOL=${MCPBASH_JSON_TOOL}"
					"MCP_COMPLETION_NAME=${name}"
					"MCP_COMPLETION_ARGS_JSON=${args_json}"
					"MCP_COMPLETION_LIMIT=${limit}"
					"MCP_COMPLETION_OFFSET=${offset}"
					"MCP_COMPLETION_ARGS_HASH=${args_hash}"
					"MCP_RESOURCE_REL_PATH=${res_rel}"
					"MCP_RESOURCE_PATH=${res_abs}"
					"MCP_RESOURCE_URI=${MCP_COMPLETION_PROVIDER_RESOURCE_URI}"
					"MCP_RESOURCE_PROVIDER=${MCP_COMPLETION_PROVIDER_RESOURCE_PROVIDER}"
					"MCP_RESOURCE_METADATA=${MCP_COMPLETION_PROVIDER_METADATA}"
				)
				if [ -n "${timeout}" ]; then
					with_timeout "${timeout}" -- mcp_env_run_curated provider "${env_pairs[@]}" -- "${provider_runner[@]}"
				else
					mcp_env_run_curated provider "${env_pairs[@]}" -- "${provider_runner[@]}"
				fi
			) >"${tmp_out}" 2>"${tmp_err}"
		else
			(
				cd "${MCPBASH_PROJECT_ROOT}" || exit 1
				local env_pairs=(
					"MCPBASH_JSON_TOOL_BIN=${MCPBASH_JSON_TOOL_BIN}"
					"MCPBASH_JSON_TOOL=${MCPBASH_JSON_TOOL}"
					"MCP_COMPLETION_NAME=${name}"
					"MCP_COMPLETION_ARGS_JSON=${args_json}"
					"MCP_COMPLETION_LIMIT=${limit}"
					"MCP_COMPLETION_OFFSET=${offset}"
					"MCP_COMPLETION_ARGS_HASH=${args_hash}"
				)
				if [ -n "${timeout}" ]; then
					with_timeout "${timeout}" -- mcp_env_run_curated provider "${env_pairs[@]}" -- "${provider_runner[@]}"
				else
					mcp_env_run_curated provider "${env_pairs[@]}" -- "${provider_runner[@]}"
				fi
			) >"${tmp_out}" 2>"${tmp_err}"
		fi
		status=$?
		script_output="$(cat "${tmp_out}" 2>/dev/null || true)"
		stderr_output="$(cat "${tmp_err}" 2>/dev/null || true)"
		if [ "${MCPBASH_PRESERVE_STATE:-false}" = "true" ] && [ -n "${MCPBASH_STATE_DIR:-}" ]; then
			local safe_name="${name}"
			safe_name="${safe_name//[^a-zA-Z0-9._-]/_}"
			cp -f "${tmp_out}" "${MCPBASH_STATE_DIR}/completion.${safe_name}.${RANDOM}.stdout" 2>/dev/null || true
			cp -f "${tmp_err}" "${MCPBASH_STATE_DIR}/completion.${safe_name}.${RANDOM}.stderr" 2>/dev/null || true
		fi
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
		# shellcheck disable=SC2034
		MCP_COMPLETION_PROVIDER_RESULT_ERROR="Unknown completion provider"
		return 1
		;;
	esac

	local suggestions_json has_more_flag next_index cursor_value
	if ! suggestions_json="$(printf '%s' "${normalized}" | "${MCPBASH_JSON_TOOL_BIN}" -c '.suggestions // []' 2>/dev/null)"; then
		# shellcheck disable=SC2034
		MCP_COMPLETION_PROVIDER_RESULT_ERROR="Unable to parse completion suggestions"
		return 1
	fi
	if ! has_more_flag="$(printf '%s' "${normalized}" | "${MCPBASH_JSON_TOOL_BIN}" -r '.hasMore // false' 2>/dev/null)"; then
		# shellcheck disable=SC2034
		MCP_COMPLETION_PROVIDER_RESULT_ERROR="Unable to parse completion hasMore flag"
		return 1
	fi
	if ! next_index="$(printf '%s' "${normalized}" | "${MCPBASH_JSON_TOOL_BIN}" -r '.next // ""' 2>/dev/null)"; then
		next_index=""
	fi
	if ! cursor_value="$(printf '%s' "${normalized}" | "${MCPBASH_JSON_TOOL_BIN}" -r '.nextCursor // .cursor // ""' 2>/dev/null)"; then
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
	local count
	if ! count="$(printf '%s' "${mcp_completion_suggestions}" | "${MCPBASH_JSON_TOOL_BIN}" 'length' 2>/dev/null)"; then
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
	if ! mcp_completion_suggestions="$(printf '%s' "${mcp_completion_suggestions}" | "${MCPBASH_JSON_TOOL_BIN}" -c --arg text "${text}" '. + [$text]' 2>/dev/null)"; then
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
	# Legacy internal completion items were content objects; completions are now string-only.
	# Accept only JSON strings here (callers should use mcp_completion_add_text for plain strings).
	if ! mcp_completion_suggestions="$(
		"${MCPBASH_JSON_TOOL_BIN}" -n -c \
			--argjson list "${mcp_completion_suggestions}" \
			--arg raw "${json_payload:-""}" '
				(try ($raw | fromjson) catch null) as $payload
				| if $payload == null then error("invalid json") else . end
				| if ($payload | type) != "string" then error("completion items must be strings") else . end
				| ($list // []) + [$payload]
			' 2>/dev/null
	)"; then
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
	local out=""
	if ! out="$(
		"${MCPBASH_JSON_TOOL_BIN}" -n -c \
			--argjson suggestions "${mcp_completion_suggestions}" \
			--argjson has_more "${has_more_json}" \
			--arg cursor "${cursor}" '
				def base:
					{completion: {values: $suggestions, hasMore: ($has_more == true)}};
				if $cursor == "" then
					base
				else
					(base | .completion.nextCursor = $cursor)
				end
			'
	)"; then
		# Never emit malformed JSON; fall back to an empty completion result.
		out='{"completion":{"values":[],"hasMore":false}}'
	fi
	printf '%s' "${out}"
}
mcp_completion_wait_for_pid() {
	local pid="$1"
	local timeout="$2"
	local waited=0
	while kill -0 "${pid}" 2>/dev/null; do
		if [ "${timeout}" -gt 0 ] && [ "${waited}" -ge "${timeout}" ]; then
			return 1
		fi
		sleep 1
		waited=$((waited + 1))
	done
	return 0
}
