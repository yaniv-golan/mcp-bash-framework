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

# Internal constants for safe error-path logging (not user-facing env vars).
_MCP_JSON_LOG_EXCERPT_LIMIT=1024

# Cache SHA-256 backend detection for error paths.
_MCP_JSON_SHA256_CHECKED=false
_MCP_JSON_SHA256_BACKEND=""

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

	# Fallback: use mcp_json_quote_text which properly escapes all control
	# characters (\b, \f, \n, \r, \t, and 0x00-0x1F as \u00XX).
	mcp_json_quote_text "${value}"
}

mcp_json_log_payload_bytes() {
	local payload="$1"
	LC_ALL=C printf '%s' "${payload}" | wc -c | tr -d ' \n'
}

mcp_json_log_payload_hash16() {
	local payload="$1"

	if [ "${_MCP_JSON_SHA256_CHECKED}" != "true" ]; then
		_MCP_JSON_SHA256_CHECKED="true"
		if command -v sha256sum >/dev/null 2>&1; then
			_MCP_JSON_SHA256_BACKEND="sha256sum"
		elif command -v shasum >/dev/null 2>&1; then
			_MCP_JSON_SHA256_BACKEND="shasum"
		elif command -v openssl >/dev/null 2>&1; then
			_MCP_JSON_SHA256_BACKEND="openssl"
		else
			_MCP_JSON_SHA256_BACKEND="none"
		fi
	fi

	local hash=""
	case "${_MCP_JSON_SHA256_BACKEND}" in
	sha256sum)
		hash="$(printf '%s' "${payload}" | sha256sum | awk '{print $1}' 2>/dev/null || true)"
		;;
	shasum)
		hash="$(printf '%s' "${payload}" | shasum -a 256 | awk '{print $1}' 2>/dev/null || true)"
		;;
	openssl)
		hash="$(printf '%s' "${payload}" | openssl dgst -sha256 2>/dev/null | awk '{print $NF}' 2>/dev/null || true)"
		;;
	*)
		hash=""
		;;
	esac

	if [ -z "${hash}" ]; then
		printf ''
		return 0
	fi
	if [ ${#hash} -le 16 ]; then
		printf '%s' "${hash}"
		return 0
	fi
	printf '%s' "${hash:0:16}"
}

mcp_json_log_payload_excerpt() {
	# SECURITY: This helper must never log raw payload bytes (single-line + sanitized).
	local payload="$1"

	local prefix=""
	if prefix="$(LC_ALL=C printf '%s' "${payload}" | head -c "${_MCP_JSON_LOG_EXCERPT_LIMIT}" 2>/dev/null)"; then
		:
	else
		prefix="$(LC_ALL=C printf '%s' "${payload}" | dd bs="${_MCP_JSON_LOG_EXCERPT_LIMIT}" count=1 2>/dev/null || true)"
	fi

	# Normalize newlines/tabs to visible escapes first.
	local s="${prefix//$'\r'/\\r}"
	s="${s//$'\n'/\\n}"
	s="${s//$'\t'/\\t}"

	# Replace any remaining non-ASCII/control bytes with '?' (keep ASCII printables only).
	if s="$(LC_ALL=C printf '%s' "${s}" | tr -c '\040-\176' '?' 2>/dev/null)"; then
		:
	fi

	# Escape for excerpt="...": backslashes first, then quotes.
	s="${s//\\/\\\\}"
	s="${s//\"/\\\"}"

	printf '%s' "${s}"
}

mcp_json_log_safe_error() {
	# SECURITY: Never log raw payloads on error paths.
	local prefix="$1"
	local payload="$2"
	local bin="$3"

	local bytes sha truncated excerpt
	bytes="$(mcp_json_log_payload_bytes "${payload}")"
	case "${bytes}" in
	'' | *[!0-9]*) bytes=0 ;;
	esac
	truncated="false"
	if [ "${bytes}" -gt "${_MCP_JSON_LOG_EXCERPT_LIMIT}" ]; then
		truncated="true"
	fi
	sha="$(mcp_json_log_payload_hash16 "${payload}")"
	if [ -z "${sha}" ]; then
		sha="none"
	fi
	excerpt="$(mcp_json_log_payload_excerpt "${payload}")"

	printf '%s (bin=%s) bytes=%s sha256=%s truncated=%s excerpt="%s"\n' "${prefix}" "${bin}" "${bytes}" "${sha}" "${truncated}" "${excerpt}" >&2
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
		# SECURITY: Never log raw payload bytes.
		mcp_json_log_safe_error "JSON normalization failed" "${line}" "${MCPBASH_JSON_TOOL_BIN}"
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
	# Trim leading whitespace
	value="${value#"${value%%[!$' \t\r\n']*}"}"
	# Trim trailing whitespace
	value="${value%"${value##*[!$' \t\r\n']}"}"
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

mcp_json_extract_file_required() {
	# Extract a value from a JSON file using the configured jq/gojq tool.
	# Fails closed with a clear stderr message on parse/tool errors.
	#
	# Args:
	# - $1: file path
	# - $2: jq output mode flag (e.g., -r or -c)
	# - $3: jq filter expression
	# - $4: context string (for error messages)
	local path="$1"
	local mode="$2"
	local filter="$3"
	local context="${4:-}"

	local json_bin="${MCPBASH_JSON_TOOL_BIN:-}"
	if [ -z "${json_bin}" ] || ! command -v "${json_bin}" >/dev/null 2>&1; then
		if [ -n "${context}" ]; then
			printf '%s\n' "${context}: JSON tooling unavailable" >&2
		fi
		return 1
	fi

	if [ -z "${mode}" ]; then
		mode="-r"
	fi

	local out=""
	if ! out="$("${json_bin}" "${mode}" "${filter}" "${path}" 2>/dev/null)"; then
		if [ -n "${context}" ]; then
			printf '%s\n' "${context}: JSON parse failed" >&2
		fi
		return 1
	fi
	printf '%s' "${out}"
	return 0
}

mcp_json_extract_optional() {
	# Best-effort JSON extraction for non-critical paths.
	# Returns $default on errors; optionally logs a warning when available.
	#
	# Args:
	# - $1: JSON string
	# - $2: jq output mode flag (e.g., -r or -c)
	# - $3: jq filter expression
	# - $4: default value
	# - $5: optional logger name for mcp_logging_warning
	# - $6: optional context string for warning message
	local json="$1"
	local mode="$2"
	local filter="$3"
	local default_value="$4"
	local logger="${5:-}"
	local context="${6:-}"

	local json_bin="${MCPBASH_JSON_TOOL_BIN:-}"
	if [ -z "${json_bin}" ] || ! command -v "${json_bin}" >/dev/null 2>&1; then
		printf '%s' "${default_value}"
		return 0
	fi
	if [ -z "${mode}" ]; then
		mode="-r"
	fi

	local out=""
	if ! out="$(printf '%s' "${json}" | "${json_bin}" "${mode}" "${filter}" 2>/dev/null)"; then
		if [ -n "${logger}" ] && command -v mcp_logging_warning >/dev/null 2>&1 && [ -n "${context}" ]; then
			mcp_logging_warning "${logger}" "${context}: JSON parse failed; using default"
		fi
		printf '%s' "${default_value}"
		return 0
	fi
	printf '%s' "${out}"
	return 0
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
			# SECURITY: Never log raw payload bytes.
			mcp_json_log_safe_error "Method extraction failed" "${json}" "${MCPBASH_JSON_TOOL_BIN}"
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
			# SECURITY: Never log raw payload bytes.
			mcp_json_log_safe_error "ID extraction failed" "${json}" "${MCPBASH_JSON_TOOL_BIN}"
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

mcp_json_extract_completion_ref_type() {
	local json="$1"
	if mcp_runtime_is_minimal_mode; then
		printf ''
		return 0
	fi

	case "${MCPBASH_JSON_TOOL}" in
	gojq | jq)
		printf '%s' "${json}" | "${MCPBASH_JSON_TOOL_BIN}" -r '.params.ref.type? // ""' 2>/dev/null
		;;
	*)
		printf ''
		;;
	esac
}

mcp_json_extract_completion_ref_name() {
	local json="$1"
	if mcp_runtime_is_minimal_mode; then
		printf ''
		return 0
	fi

	case "${MCPBASH_JSON_TOOL}" in
	gojq | jq)
		printf '%s' "${json}" | "${MCPBASH_JSON_TOOL_BIN}" -r '.params.ref.name? // ""' 2>/dev/null
		;;
	*)
		printf ''
		;;
	esac
}

mcp_json_extract_completion_ref_uri() {
	local json="$1"
	if mcp_runtime_is_minimal_mode; then
		printf ''
		return 0
	fi

	case "${MCPBASH_JSON_TOOL}" in
	gojq | jq)
		printf '%s' "${json}" | "${MCPBASH_JSON_TOOL_BIN}" -r '.params.ref.uri? // ""' 2>/dev/null
		;;
	*)
		printf ''
		;;
	esac
}

mcp_json_extract_completion_argument_name() {
	local json="$1"
	if mcp_runtime_is_minimal_mode; then
		printf ''
		return 0
	fi

	case "${MCPBASH_JSON_TOOL}" in
	gojq | jq)
		printf '%s' "${json}" | "${MCPBASH_JSON_TOOL_BIN}" -r '.params.argument.name? // ""' 2>/dev/null
		;;
	*)
		printf ''
		;;
	esac
}

mcp_json_extract_completion_argument_value() {
	local json="$1"
	if mcp_runtime_is_minimal_mode; then
		printf ''
		return 0
	fi

	case "${MCPBASH_JSON_TOOL}" in
	gojq | jq)
		printf '%s' "${json}" | "${MCPBASH_JSON_TOOL_BIN}" -r '.params.argument.value? // ""' 2>/dev/null
		;;
	*)
		printf ''
		;;
	esac
}

mcp_json_extract_completion_context_arguments() {
	local json="$1"
	if mcp_runtime_is_minimal_mode; then
		printf '{}'
		return 0
	fi

	case "${MCPBASH_JSON_TOOL}" in
	gojq | jq)
		if ! printf '%s' "${json}" | "${MCPBASH_JSON_TOOL_BIN}" -ec '(.params.context.arguments? // {}) | if type == "object" then . else {} end' 2>/dev/null; then
			printf '{}'
		fi
		;;
	*)
		printf '{}'
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
		if ! printf '%s' "${json}" | "${MCPBASH_JSON_TOOL_BIN}" -c '
			def obj_or_empty($v):
				if ($v | type) == "object" then $v else {} end;
			def str_or_empty($v):
				if ($v | type) == "string" then $v else "" end;

			(.params.argument? // {}) as $arg
			| (str_or_empty($arg.value)) as $value
			| {
				query: $value,
				prefix: $value,
				argument: {
					name: (str_or_empty($arg.name)),
					value: $value
				},
				context: {
					arguments: obj_or_empty(.params.context.arguments? // {})
				},
				ref: (obj_or_empty(.params.ref? // {}))
			}
		' 2>/dev/null; then
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
		# MCP 2025-11-25: params.argument.value
		printf '%s' "${json}" | "${MCPBASH_JSON_TOOL_BIN}" -r '.params.argument.value? // ""' 2>/dev/null
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

# Convert local file paths in icons array to data URIs.
# Usage: mcp_json_icons_to_data_uris <icons_json> <base_dir>
# Input: [{"src": "./icon.svg"}, {"src": "https://..."}]
# Output: [{"src": "data:image/svg+xml;base64,..."}, {"src": "https://..."}]
mcp_json_icons_to_data_uris() {
	local icons_json="$1"
	local base_dir="$2"

	if [ "${icons_json}" = "null" ] || [ -z "${icons_json}" ]; then
		printf 'null'
		return 0
	fi

	if [ "${MCPBASH_JSON_TOOL:-none}" = "none" ]; then
		# No JSON tool - pass through unchanged
		printf '%s' "${icons_json}"
		return 0
	fi

	# Validate input is an array before iterating to avoid jq errors on null/objects
	local icons_type
	icons_type="$(printf '%s' "${icons_json}" | "${MCPBASH_JSON_TOOL_BIN}" -r 'type' 2>/dev/null || true)"
	if [ "${icons_type}" != "array" ]; then
		printf 'null'
		return 0
	fi

	# Process each icon in the array
	printf '%s' "${icons_json}" | "${MCPBASH_JSON_TOOL_BIN}" -c --arg base "${base_dir}" '
		[.[] | . as $icon |
			# Skip null elements or objects without src string
			if ($icon | type) != "object" or (($icon.src // null) | type) != "string" then
				empty
			elif ($icon.src | startswith("data:")) or ($icon.src | startswith("http://")) or ($icon.src | startswith("https://")) then
				$icon
			else
				# Local file path - mark for shell processing
				$icon + {"_local": true, "_base": $base}
			end
		]
	' 2>/dev/null | while IFS= read -r processed; do
		# Check if any icons need local file conversion
		if printf '%s' "${processed}" | "${MCPBASH_JSON_TOOL_BIN}" -e 'any(._local)' >/dev/null 2>&1; then
			# Has local files - process them
			mcp_json_icons_resolve_local_files "${processed}" "${base_dir}"
		else
			printf '%s' "${processed}"
		fi
	done
}

# Resolve local file icons to data URIs
mcp_json_icons_resolve_local_files() {
	local icons_json="$1"
	local base_dir="$2"
	local result="["
	local first=1
	local icon_count
	icon_count="$(printf '%s' "${icons_json}" | "${MCPBASH_JSON_TOOL_BIN}" 'length')"

	local i=0
	while [ "${i}" -lt "${icon_count}" ]; do
		local icon
		icon="$(printf '%s' "${icons_json}" | "${MCPBASH_JSON_TOOL_BIN}" -c ".[$i]")"
		local is_local
		is_local="$(printf '%s' "${icon}" | "${MCPBASH_JSON_TOOL_BIN}" -r '._local // false')"

		if [ "${is_local}" = "true" ]; then
			local src mime_type
			src="$(printf '%s' "${icon}" | "${MCPBASH_JSON_TOOL_BIN}" -r '.src')"
			mime_type="$(printf '%s' "${icon}" | "${MCPBASH_JSON_TOOL_BIN}" -r '.mimeType // empty')"

			# Resolve path relative to base_dir
			local file_path
			case "${src}" in
			/*) file_path="${src}" ;;
			*) file_path="${base_dir}/${src}" ;;
			esac

			if [ -f "${file_path}" ]; then
				# Auto-detect mime type from extension if not provided
				if [ -z "${mime_type}" ]; then
					case "${file_path}" in
					*.svg) mime_type="image/svg+xml" ;;
					*.png) mime_type="image/png" ;;
					*.jpg | *.jpeg) mime_type="image/jpeg" ;;
					*.gif) mime_type="image/gif" ;;
					*.webp) mime_type="image/webp" ;;
					*.ico) mime_type="image/x-icon" ;;
					*) mime_type="application/octet-stream" ;;
					esac
				fi

				# Read and base64 encode the file
				local data_uri
				if command -v base64 >/dev/null 2>&1; then
					data_uri="data:${mime_type};base64,$(base64 <"${file_path}" | tr -d '\n')"
				else
					# Fallback: keep original src if base64 not available
					data_uri="${src}"
				fi

				# Build icon object with data URI
				icon="$(printf '%s' "${icon}" | "${MCPBASH_JSON_TOOL_BIN}" -c --arg src "${data_uri}" --arg mime "${mime_type}" '
					del(._local, ._base) | .src = $src | if .mimeType then . else .mimeType = $mime end
				')"
			else
				# File not found - keep original src, remove markers
				icon="$(printf '%s' "${icon}" | "${MCPBASH_JSON_TOOL_BIN}" -c 'del(._local, ._base)')"
			fi
		fi

		if [ "${first}" -eq 1 ]; then
			result="${result}${icon}"
			first=0
		else
			result="${result},${icon}"
		fi
		i=$((i + 1))
	done

	result="${result}]"
	printf '%s' "${result}"
}
