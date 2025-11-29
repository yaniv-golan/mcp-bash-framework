#!/usr/bin/env bash
# JSON normalization, tokenizer fallbacks, and field extraction.

# shellcheck disable=SC1003
set -euo pipefail

MCP_JSON_BOM=$'\xEF\xBB\xBF'
MCP_JSON_CACHE_LINE=""
MCP_JSON_CACHE_METHOD=""
MCP_JSON_CACHE_ID=""
MCP_JSON_CACHE_HAS_ID="false"
MCP_JSON_CACHE_PARAMS=""
MCP_JSON_CACHE_HAS_PARAMS="false"

mcp_json_quote_text() {
	local input="$1"
	local length=${#input}
	local i
	local char
	local code
	local hex
	local -a parts=()
	for ((i = 0; i < length; i++)); do
		char="${input:i:1}"
		case "${char}" in
		'"')
			parts+=('\"')
			;;
		'\\')
			parts+=('\\\\')
			;;
		$'\b')
			parts+=('\\b')
			;;
		$'\f')
			parts+=('\\f')
			;;
		$'\n')
			parts+=('\\n')
			;;
		$'\r')
			parts+=('\\r')
			;;
		$'\t')
			parts+=('\\t')
			;;
		*)
			LC_ALL=C printf -v code '%d' "'${char}"
			if [ "${code}" -lt 32 ]; then
				LC_ALL=C printf -v hex '%02X' "${code}"
				parts+=("\\u00${hex}")
			else
				parts+=("${char}")
			fi
			;;
		esac
	done
	local joined=""
	printf -v joined '%s' "${parts[@]}"
	printf '"%s"' "${joined}"
}

mcp_json_escape_string() {
	local value="$1"

	if [ "${MCPBASH_JSON_TOOL:-none}" != "none" ]; then
		"${MCPBASH_JSON_TOOL_BIN}" -n --arg v "${value}" '$v'
		return 0
	fi

	local escaped="${value//\\/\\\\}"
	escaped="${escaped//\"/\\\"}"
	escaped="${escaped//$'\n'/\\n}"
	escaped="${escaped//$'\r'/\\r}"
	escaped="${escaped//$'\t'/\\t}"
	printf '"%s"' "${escaped}"
}

mcp_json_normalize_line() {
	local line="$1"
	line="$(mcp_json_strip_bom "${line}")"
	line="$(mcp_json_trim "${line}")"

	if [ -z "${line}" ]; then
		printf ''
		return 0
	fi

	if mcp_runtime_is_minimal_mode; then
		if [ "${line#\{}" = "${line}" ] || [ "${line%\}}" = "${line}" ]; then
			return 1
		fi
		# Minimal mode keeps input as-is after validation.
		if ! mcp_json_minimal_parse "${line}"; then
			return 1
		fi
		printf '%s' "${line}"
		return 0
	fi

	case "${MCPBASH_JSON_TOOL}" in
	gojq | jq)
		mcp_json_normalize_with_jq "${line}"
		;;
	*)
		return 1
		;;
	esac
}

mcp_json_normalize_with_jq() {
	local line="$1"
	local compact
	local -a jq_args=("-c" ".")
	# gojq always sorts keys; add -S for jq to match ordering across tools.
	if [ "${MCPBASH_JSON_TOOL}" = "jq" ]; then
		jq_args=("-cS" ".")
	fi
	if ! compact="$(printf '%s' "${line}" | "${MCPBASH_JSON_TOOL_BIN}" "${jq_args[@]}" 2>/dev/null)"; then
		printf 'JSON normalization failed for: %s using %s\n' "${line}" "${MCPBASH_JSON_TOOL_BIN}" >&2
		return 1
	fi
	printf '%s' "${compact}"
}

mcp_json_strip_bom() {
	local value="$1"
	case "${value}" in
	"${MCP_JSON_BOM}"*)
		printf '%s' "${value#"${MCP_JSON_BOM}"}"
		;;
	*)
		printf '%s' "${value}"
		;;
	esac
}

mcp_json_trim() {
	local value="$1"
	while [ -n "${value}" ]; do
		case "${value}" in
		$'\r'* | $'\n'* | $'\t'* | ' '*)
			value="${value#?}"
			;;
		*)
			break
			;;
		esac
	done

	while [ -n "${value}" ]; do
		case "${value}" in
		*$'\r' | *$'\n' | *$'\t' | *' ')
			value="${value%?}"
			;;
		*)
			break
			;;
		esac
	done

	printf '%s' "${value}"
}

mcp_json_is_array() {
	case "$1" in
	\[*)
		return 0
		;;
	*)
		return 1
		;;
	esac
}

mcp_json_extract_method() {
	local json="$1"
	if mcp_runtime_is_minimal_mode; then
		if ! mcp_json_minimal_parse "${json}"; then
			return 1
		fi
		if [ -z "${MCP_JSON_CACHE_METHOD}" ]; then
			return 1
		fi
		printf '%s' "${MCP_JSON_CACHE_METHOD}"
		return 0
	fi

	case "${MCPBASH_JSON_TOOL}" in
	gojq | jq)
		if ! printf '%s' "${json}" | "${MCPBASH_JSON_TOOL_BIN}" -er '.method | strings' 2>/dev/null; then
			printf 'Method extraction failed for: %s using %s\n' "${json}" "${MCPBASH_JSON_TOOL_BIN}" >&2
			return 1
		fi
		;;
	*)
		return 1
		;;
	esac
}

mcp_json_extract_id() {
	local json="$1"
	if mcp_runtime_is_minimal_mode; then
		if ! mcp_json_minimal_parse "${json}"; then
			return 1
		fi
		if [ "${MCP_JSON_CACHE_HAS_ID}" = "true" ]; then
			printf '%s' "${MCP_JSON_CACHE_ID}"
		fi
		return 0
	fi

	case "${MCPBASH_JSON_TOOL}" in
	gojq | jq)
		if ! printf '%s' "${json}" | "${MCPBASH_JSON_TOOL_BIN}" -c '.id' 2>/dev/null; then
			printf 'ID extraction failed for: %s using %s\n' "${json}" "${MCPBASH_JSON_TOOL_BIN}" >&2
			return 1
		fi
		;;
	*)
		return 1
		;;
	esac
}

mcp_json_minimal_parse() {
	local json="$1"

	if [ "${MCP_JSON_CACHE_LINE}" = "${json}" ]; then
		return 0
	fi

	MCP_JSON_CACHE_LINE="${json}"
	MCP_JSON_CACHE_METHOD=""
	MCP_JSON_CACHE_ID=""
	MCP_JSON_CACHE_HAS_ID="false"
	MCP_JSON_CACHE_PARAMS=""
	MCP_JSON_CACHE_HAS_PARAMS="false"

	local len=${#json}
	if [ "${len}" -lt 2 ]; then
		return 1
	fi

	if [ "${json:0:1}" != "{" ] || [ "${json:len-1:1}" != "}" ]; then
		return 1
	fi

	local content="${json:1:len-2}"
	local pairs
	if ! pairs="$(mcp_json_minimal_split_pairs "${content}")"; then
		return 1
	fi

	local IFS=$'\n'
	local pair
	local found_method=false
	for pair in ${pairs}; do
		[ -z "${pair}" ] && continue
		if ! mcp_json_minimal_process_pair "${pair}"; then
			return 1
		fi
		if [ -n "${MCP_JSON_CACHE_METHOD}" ]; then
			found_method=true
		fi
	done
	IFS=$' \t\n'

	if [ "${found_method}" != "true" ]; then
		return 1
	fi

	return 0
}

mcp_json_has_key() {
	local json="$1"
	local key="$2"
	if [ -z "${key}" ]; then
		return 1
	fi

	if mcp_runtime_is_minimal_mode; then
		if ! mcp_json_minimal_parse "${json}"; then
			return 1
		fi
		case "${key}" in
		method)
			[ -n "${MCP_JSON_CACHE_METHOD}" ] && return 0
			return 1
			;;
		id)
			[ "${MCP_JSON_CACHE_HAS_ID}" = "true" ] && return 0
			return 1
			;;
		*)
			# Lightweight check for other keys in minimal mode
			case "${json}" in
			*\"${key}\"*) return 0 ;;
			esac
			return 1
			;;
		esac
	fi

	case "${MCPBASH_JSON_TOOL}" in
	gojq | jq)
		if printf '%s' "${json}" | "${MCPBASH_JSON_TOOL_BIN}" -e --arg key "${key}" 'has($key)' >/dev/null 2>&1; then
			return 0
		fi
		;;
	esac
	return 1
}

mcp_json_minimal_split_pairs() {
	local content="$1"
	local length=${#content}
	local i=0
	local char
	local depth=0
	local in_string=0
	local escape=0
	local current=""
	local result=""

	while [ "${i}" -lt "${length}" ]; do
		char="${content:i:1}"
		if [ "${escape}" = "1" ]; then
			current="${current}${char}"
			escape=0
			i=$((i + 1))
			continue
		fi
		if [ "${char}" = "\\" ]; then
			current="${current}${char}"
			escape=1
			i=$((i + 1))
			continue
		fi
		# shellcheck disable=SC1003 # manual escape handling keeps parser dependency-free
		case "${char}" in
		'"')
			current="${current}${char}"
			if [ "${in_string}" = "1" ]; then
				in_string=0
			else
				in_string=1
			fi
			;;
		'{' | '[')
			current="${current}${char}"
			if [ "${in_string}" = "0" ]; then
				depth=$((depth + 1))
			fi
			;;
		'}' | ']')
			current="${current}${char}"
			if [ "${in_string}" = "0" ]; then
				depth=$((depth - 1))
				if [ "${depth}" -lt 0 ]; then
					return 1
				fi
			fi
			;;
		',')
			if [ "${in_string}" = "0" ] && [ "${depth}" -eq 0 ]; then
				result="${result}$(mcp_json_trim "${current}")"$'\n'
				current=""
			else
				current="${current}${char}"
			fi
			;;
		*)
			current="${current}${char}"
			;;
		esac
		i=$((i + 1))
	done

	if [ "${escape}" = "1" ] || [ "${in_string}" = "1" ] || [ "${depth}" -ne 0 ]; then
		return 1
	fi

	result="${result}$(mcp_json_trim "${current}")"
	printf '%s' "${result}"
}

mcp_json_minimal_process_pair() {
	local pair="$1"
	if [ -z "${pair}" ]; then
		return 0
	fi

	local colon_index
	colon_index="$(mcp_json_minimal_find_colon "${pair}")" || return 1
	if [ "${colon_index}" -lt 0 ]; then
		return 1
	fi

	local key="${pair:0:colon_index}"
	local value="${pair:colon_index+1}"
	key="$(mcp_json_trim "${key}")"
	value="$(mcp_json_trim "${value}")"

	if [ "${key:0:1}" != "\"" ] || [ "${key:${#key}-1:1}" != "\"" ]; then
		return 1
	fi

	local key_name="${key:1:${#key}-2}"

	if [ "${key_name}" = "method" ]; then
		local unquoted
		if ! unquoted="$(mcp_json_minimal_unquote "${value}")"; then
			return 1
		fi
		if [ -z "${unquoted}" ]; then
			return 1
		fi
		MCP_JSON_CACHE_METHOD="${unquoted}"
		return 0
	fi

	if [ "${key_name}" = "id" ]; then
		if ! mcp_json_minimal_validate_id "${value}"; then
			return 1
		fi
		MCP_JSON_CACHE_ID="${value}"
		MCP_JSON_CACHE_HAS_ID="true"
		return 0
	fi

	if [ "${key_name}" = "params" ]; then
		MCP_JSON_CACHE_PARAMS="${value}"
		MCP_JSON_CACHE_HAS_PARAMS="true"
		return 0
	fi

	return 0
}

mcp_json_minimal_extract_param_string() {
	local param_key="$1"
	if [ "${MCP_JSON_CACHE_HAS_PARAMS}" != "true" ]; then
		return 1
	fi
	local payload="${MCP_JSON_CACHE_PARAMS}"
	local len=${#payload}
	if [ "${len}" -lt 2 ] || [ "${payload:0:1}" != "{" ] || [ "${payload:len-1:1}" != "}" ]; then
		return 1
	fi
	local inner="${payload:1:len-2}"
	local pairs
	if ! pairs="$(mcp_json_minimal_split_pairs "${inner}")"; then
		return 1
	fi
	local IFS=$'\n'
	local pair
	for pair in ${pairs}; do
		[ -z "${pair}" ] && continue
		local colon_index
		colon_index="$(mcp_json_minimal_find_colon "${pair}")" || {
			IFS=$' \t\n'
			return 1
		}
		[ "${colon_index}" -lt 0 ] && continue
		local key="${pair:0:colon_index}"
		local value="${pair:colon_index+1}"
		key="$(mcp_json_trim "${key}")"
		value="$(mcp_json_trim "${value}")"
		if [ "${key:0:1}" != '"' ] || [ "${key:${#key}-1:1}" != '"' ]; then
			continue
		fi
		local name="${key:1:${#key}-2}"
		if [ "${name}" = "${param_key}" ]; then
			local unquoted
			if ! unquoted="$(mcp_json_minimal_unquote "${value}")"; then
				IFS=$' \t\n'
				return 1
			fi
			IFS=$' \t\n'
			printf '%s' "${unquoted}"
			return 0
		fi
	done
	IFS=$' \t\n'
	return 1
}

mcp_json_minimal_find_colon() {
	local text="$1"
	local length=${#text}
	local i=0
	local char
	local depth=0
	local in_string=0
	local escape=0

	while [ "${i}" -lt "${length}" ]; do
		char="${text:i:1}"
		if [ "${escape}" = "1" ]; then
			escape=0
			i=$((i + 1))
			continue
		fi
		if [ "${char}" = "\\" ]; then
			escape=1
			i=$((i + 1))
			continue
		fi
		# shellcheck disable=SC1003 # manual escape handling keeps parser dependency-free
		case "${char}" in
		'"')
			if [ "${in_string}" = "1" ]; then
				in_string=0
			else
				in_string=1
			fi
			;;
		'{' | '[')
			if [ "${in_string}" = "0" ]; then
				depth=$((depth + 1))
			fi
			;;
		'}' | ']')
			if [ "${in_string}" = "0" ]; then
				depth=$((depth - 1))
				if [ "${depth}" -lt 0 ]; then
					return 1
				fi
			fi
			;;
		':')
			if [ "${in_string}" = "0" ] && [ "${depth}" -eq 0 ]; then
				printf '%s' "${i}"
				return 0
			fi
			;;
		*) ;;
		esac
		i=$((i + 1))
	done

	printf '%s' "-1"
	return 0
}

mcp_json_minimal_unquote() {
	local value="$1"
	local length=${#value}
	if [ "${length}" -lt 2 ]; then
		return 1
	fi
	if [ "${value:0:1}" != "\"" ] || [ "${value:length-1:1}" != "\"" ]; then
		return 1
	fi
	local body="${value:1:length-2}"
	local body_length=${#body}
	local i=0
	local char
	local escape
	local hex
	local result=""
	while [ "${i}" -lt "${body_length}" ]; do
		char="${body:i:1}"
		if [ "${char}" = '\\' ]; then
			i=$((i + 1))
			if [ "${i}" -ge "${body_length}" ]; then
				return 1
			fi
			escape="${body:i:1}"
			case "${escape}" in
			"\"" | "/" | \\)
				result+="${escape}"
				;;
			b)
				result+=$'\b'
				;;
			f)
				result+=$'\f'
				;;
			n)
				result+=$'\n'
				;;
			r)
				result+=$'\r'
				;;
			t)
				result+=$'\t'
				;;
			u)
				if [ $((i + 4)) -ge "${body_length}" ]; then
					return 1
				fi
				hex="${body:i+1:4}"
				case "${hex}" in
				[0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F]) ;;
				*)
					return 1
					;;
				esac
				result+="\\u${hex}"
				i=$((i + 4))
				;;
			*)
				return 1
				;;
			esac
		else
			result+="${char}"
		fi
		i=$((i + 1))
	done
	printf '%s' "${result}"
}

mcp_json_minimal_validate_id() {
	local value="$1"
	# shellcheck disable=SC1003 # minimal parser exploits literal patterns
	case "${value}" in
	\"*\"*)
		if ! mcp_json_minimal_unquote "${value}" >/dev/null; then
			return 1
		fi
		return 0
		;;
	null)
		return 0
		;;
	esac

	if mcp_json_minimal_is_number "${value}"; then
		return 0
	fi

	return 1
}

mcp_json_minimal_is_number() {
	local num="$1"
	if [ -z "${num}" ]; then
		return 1
	fi
	if [[ "${num}" =~ ^-?(0|[1-9][0-9]*)(\.[0-9]+)?([eE][+-]?[0-9]+)?$ ]]; then
		return 0
	fi
	return 1
}

mcp_json_extract_cancel_id() {
	local json="$1"

	if mcp_runtime_is_minimal_mode; then
		printf ''
		return 1
	fi

	case "${MCPBASH_JSON_TOOL}" in
	gojq | jq)
		if ! printf '%s' "${json}" | "${MCPBASH_JSON_TOOL_BIN}" -er '.params.requestId // .params.id' 2>/dev/null; then
			return 1
		fi
		;;
	*)
		return 1
		;;
	esac
}

mcp_json_extract_protocol_version() {
	local json="$1"

	if mcp_runtime_is_minimal_mode; then
		if ! mcp_json_minimal_parse "${json}"; then
			printf ''
			return 1
		fi
		if mcp_json_minimal_extract_param_string "protocolVersion"; then
			return 0
		fi
		printf ''
		return 0
	fi

	case "${MCPBASH_JSON_TOOL}" in
	gojq | jq)
		if ! printf '%s' "${json}" | "${MCPBASH_JSON_TOOL_BIN}" -er '.params.protocolVersion // empty' 2>/dev/null; then
			printf ''
		fi
		;;
	*)
		printf ''
		;;
	esac
}

mcp_json_extract_limit() {
	local json="$1"
	if mcp_runtime_is_minimal_mode; then
		printf ''
		return 0
	fi

	case "${MCPBASH_JSON_TOOL}" in
	gojq | jq)
		printf '%s' "${json}" | "${MCPBASH_JSON_TOOL_BIN}" -r '.params.limit? // ""' 2>/dev/null
		;;
	*)
		printf ''
		;;
	esac
}

mcp_json_extract_cursor() {
	local json="$1"
	if mcp_runtime_is_minimal_mode; then
		printf ''
		return 0
	fi

	case "${MCPBASH_JSON_TOOL}" in
	gojq | jq)
		printf '%s' "${json}" | "${MCPBASH_JSON_TOOL_BIN}" -r '.params.cursor? // .params.nextCursor? // ""' 2>/dev/null
		;;
	*)
		printf ''
		;;
	esac
}

mcp_json_extract_tool_name() {
	local json="$1"
	if mcp_runtime_is_minimal_mode; then
		printf ''
		return 0
	fi

	case "${MCPBASH_JSON_TOOL}" in
	gojq | jq)
		printf '%s' "${json}" | "${MCPBASH_JSON_TOOL_BIN}" -r '.params.name? // ""' 2>/dev/null
		;;
	*)
		printf ''
		;;
	esac
}

mcp_json_extract_arguments() {
	local json="$1"
	if mcp_runtime_is_minimal_mode; then
		printf '{}'
		return 0
	fi

	case "${MCPBASH_JSON_TOOL}" in
	gojq | jq)
		if ! printf '%s' "${json}" | "${MCPBASH_JSON_TOOL_BIN}" -ec '.params.arguments // {}' 2>/dev/null; then
			printf '{}'
		fi
		;;
	*)
		printf '{}'
		;;
	esac
}

mcp_json_extract_timeout_override() {
	local json="$1"
	if mcp_runtime_is_minimal_mode; then
		printf ''
		return 0
	fi

	case "${MCPBASH_JSON_TOOL}" in
	gojq | jq)
		printf '%s' "${json}" | "${MCPBASH_JSON_TOOL_BIN}" -r '.params.timeoutSecs? // ""' 2>/dev/null
		;;
	*)
		printf ''
		;;
	esac
}

mcp_json_extract_resource_name() {
	local json="$1"
	if mcp_runtime_is_minimal_mode; then
		printf ''
		return 0
	fi

	case "${MCPBASH_JSON_TOOL}" in
	gojq | jq)
		printf '%s' "${json}" | "${MCPBASH_JSON_TOOL_BIN}" -r '.params.name? // ""' 2>/dev/null
		;;
	*)
		printf ''
		;;
	esac
}

mcp_json_extract_resource_uri() {
	local json="$1"
	if mcp_runtime_is_minimal_mode; then
		printf ''
		return 0
	fi

	case "${MCPBASH_JSON_TOOL}" in
	gojq | jq)
		printf '%s' "${json}" | "${MCPBASH_JSON_TOOL_BIN}" -r '.params.uri? // ""' 2>/dev/null
		;;
	*)
		printf ''
		;;
	esac
}

mcp_json_extract_subscription_id() {
	local json="$1"
	if mcp_runtime_is_minimal_mode; then
		printf ''
		return 0
	fi

	case "${MCPBASH_JSON_TOOL}" in
	gojq | jq)
		printf '%s' "${json}" | "${MCPBASH_JSON_TOOL_BIN}" -r '.params.subscriptionId? // ""' 2>/dev/null
		;;
	*)
		printf ''
		;;
	esac
}

mcp_json_extract_progress_token() {
	local json="$1"
	if mcp_runtime_is_minimal_mode; then
		printf ''
		return 0
	fi

	case "${MCPBASH_JSON_TOOL}" in
	gojq | jq)
		printf '%s' "${json}" | "${MCPBASH_JSON_TOOL_BIN}" -r '.params._meta.progressToken? // ""' 2>/dev/null
		;;
	*)
		printf ''
		;;
	esac
}

mcp_json_extract_completion_name() {
	local json="$1"
	if mcp_runtime_is_minimal_mode; then
		printf ''
		return 0
	fi

	case "${MCPBASH_JSON_TOOL}" in
	gojq | jq)
		printf '%s' "${json}" | "${MCPBASH_JSON_TOOL_BIN}" -r '.params.name? // ""' 2>/dev/null
		;;
	*)
		printf ''
		;;
	esac
}

mcp_json_extract_log_level() {
	local json="$1"
	if mcp_runtime_is_minimal_mode; then
		if ! mcp_json_minimal_parse "${json}"; then
			printf ''
			return 1
		fi
		if mcp_json_minimal_extract_param_string "level"; then
			return 0
		fi
		printf ''
		return 0
	fi

	case "${MCPBASH_JSON_TOOL}" in
	gojq | jq)
		printf '%s' "${json}" | "${MCPBASH_JSON_TOOL_BIN}" -r '.params.level? // ""' 2>/dev/null
		;;
	*)
		printf ''
		;;
	esac
}

mcp_json_extract_completion_arguments() {
	local json="$1"
	if mcp_runtime_is_minimal_mode; then
		printf '{}'
		return 0
	fi

	case "${MCPBASH_JSON_TOOL}" in
	gojq | jq)
		if ! printf '%s' "${json}" | "${MCPBASH_JSON_TOOL_BIN}" -ec '.params.arguments // {}' 2>/dev/null; then
			printf '{}'
		fi
		;;
	*)
		printf '{}'
		;;
	esac
}

mcp_json_extract_completion_query() {
	local json="$1"
	if mcp_runtime_is_minimal_mode; then
		printf ''
		return 0
	fi

	case "${MCPBASH_JSON_TOOL}" in
	gojq | jq)
		printf '%s' "${json}" | "${MCPBASH_JSON_TOOL_BIN}" -r '.params.arguments.query? // .params.arguments.prefix? // ""' 2>/dev/null
		;;
	*)
		printf ''
		;;
	esac
}

mcp_json_extract_prompt_name() {
	local json="$1"
	if mcp_runtime_is_minimal_mode; then
		printf ''
		return 0
	fi

	case "${MCPBASH_JSON_TOOL}" in
	gojq | jq)
		printf '%s' "${json}" | "${MCPBASH_JSON_TOOL_BIN}" -r '.params.name? // ""' 2>/dev/null
		;;
	*)
		printf ''
		;;
	esac
}

mcp_json_extract_prompt_arguments() {
	local json="$1"
	if mcp_runtime_is_minimal_mode; then
		printf '{}'
		return 0
	fi

	case "${MCPBASH_JSON_TOOL}" in
	gojq | jq)
		if ! printf '%s' "${json}" | "${MCPBASH_JSON_TOOL_BIN}" -ec '.params.arguments // {}' 2>/dev/null; then
			printf '{}'
		fi
		;;
	*)
		printf '{}'
		;;
	esac
}
