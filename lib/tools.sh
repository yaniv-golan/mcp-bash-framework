#!/usr/bin/env bash
# Tool discovery, registry generation, invocation helpers.

set -euo pipefail

if [[ -z "${BASH_VERSION:-}" ]]; then
	printf 'Bash is required for mcpbash; BASH_VERSION missing\n' >&2
	exit 1
fi
# shellcheck disable=SC2030,SC2031  # Subshell env mutations are intentionally isolated

MCP_TOOLS_REGISTRY_JSON=""
MCP_TOOLS_REGISTRY_HASH=""
MCP_TOOLS_REGISTRY_PATH=""
# shellcheck disable=SC2034
MCP_TOOLS_TOTAL=0
# Internal error handoff between library and handler (not user-configurable).
# shellcheck disable=SC2034
_MCP_TOOLS_ERROR_CODE=0
# shellcheck disable=SC2034
_MCP_TOOLS_ERROR_MESSAGE=""
# shellcheck disable=SC2034
_MCP_TOOLS_ERROR_DATA=""
# shellcheck disable=SC2034
_MCP_TOOLS_RESULT=""
MCP_TOOLS_TTL="${MCP_TOOLS_TTL:-5}"
MCP_TOOLS_LAST_SCAN="" # Empty means "use cache mtime if loading"; 0 means "force scan"
MCP_TOOLS_LAST_NOTIFIED_HASH=""
MCP_TOOLS_CHANGED=false
MCP_TOOLS_MANUAL_ACTIVE=false
MCP_TOOLS_MANUAL_BUFFER=""
MCP_TOOLS_MANUAL_DELIM=$'\036'
MCP_TOOLS_LOGGER="${MCP_TOOLS_LOGGER:-mcp.tools}"
: "${MCPBASH_TOOL_ENV_INHERIT_WARNED:=false}"

# Ensure require helper is available (for standalone sourcing).
if ! command -v mcp_require >/dev/null 2>&1; then
	# shellcheck disable=SC1090
	. "${MCPBASH_HOME:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}/lib/require.sh"
fi

mcp_require registry mcp_registry_resolve_scan_root
mcp_require json mcp_json_icons_to_data_uris
mcp_require uri mcp_uri_file_uri_from_path
mcp_require resource_content mcp_resource_content_object_from_file

# Provide defaults if policy helpers were not sourced (older bootstraps).
if ! declare -F mcp_tools_policy_check >/dev/null 2>&1; then
	mcp_tools_policy_check() { return 0; }
fi
if ! declare -F mcp_tools_policy_init >/dev/null 2>&1; then
	mcp_tools_policy_init() { return 0; }
fi

mcp_tools_scan_root() {
	mcp_registry_resolve_scan_root "${MCPBASH_TOOLS_DIR}"
}

mcp_tools_normalize_path() {
	local target="$1"
	if command -v mcp_path_normalize >/dev/null 2>&1; then
		mcp_path_normalize --physical "${target}"
		return
	fi
	if command -v realpath >/dev/null 2>&1; then
		realpath "${target}" 2>/dev/null
		return
	fi
	(
		cd "$(dirname "${target}")" 2>/dev/null || exit 1
		pwd -P 2>/dev/null | awk -v base="$(basename "${target}")" '{print $0"/"base}'
	)
}

mcp_tools_stat_perm_mask() {
	local path="$1"
	local perm_mask=""
	if command -v stat >/dev/null 2>&1; then
		perm_mask="$(stat -c '%a' "${path}" 2>/dev/null || true)"
		if [ -z "${perm_mask}" ]; then
			perm_mask="$(stat -f '%Lp' "${path}" 2>/dev/null || true)"
		fi
	fi
	[ -n "${perm_mask}" ] || return 1
	printf '%s' "${perm_mask}"
}

mcp_tools_stat_uid_gid() {
	local path="$1"
	local uid_gid=""
	if command -v stat >/dev/null 2>&1; then
		uid_gid="$(stat -c '%u:%g' "${path}" 2>/dev/null || true)"
		if [ -z "${uid_gid}" ]; then
			uid_gid="$(stat -f '%u:%g' "${path}" 2>/dev/null || true)"
		fi
	fi
	[ -n "${uid_gid}" ] || return 1
	printf '%s' "${uid_gid}"
}

mcp_tools_validate_path() {
	local candidate="$1"
	local canonical root
	canonical="$(mcp_tools_normalize_path "${candidate}" 2>/dev/null || true)"
	root="$(mcp_tools_normalize_path "${MCPBASH_TOOLS_DIR}" 2>/dev/null || true)"
	if [ -z "${canonical}" ] || [ -z "${root}" ]; then
		return 1
	fi
	# SECURITY: do NOT use case/glob matching for containment checks. Tool/root
	# paths may contain glob metacharacters like []?* which would turn the check
	# into a wildcard match and allow bypasses.
	if [ "${root}" != "/" ]; then
		root="${root%/}"
	fi
	if [ "${canonical}" != "${root}" ]; then
		if [ "${root}" = "/" ]; then
			:
		else
			local prefix="${root}/"
			if [ "${canonical:0:${#prefix}}" != "${prefix}" ]; then
				return 1
			fi
		fi
	fi
	local perm_mask
	if perm_mask="$(mcp_tools_stat_perm_mask "${canonical}" 2>/dev/null)"; then
		local perm_bits=$((8#${perm_mask}))
		if [ $((perm_bits & 0020)) -ne 0 ] || [ $((perm_bits & 0002)) -ne 0 ]; then
			return 1
		fi
	fi
	local uid_gid cur_uid cur_gid
	if uid_gid="$(mcp_tools_stat_uid_gid "${canonical}" 2>/dev/null)"; then
		cur_uid="$(id -u 2>/dev/null || printf '0')"
		cur_gid="$(id -g 2>/dev/null || printf '0')"
		case "${uid_gid}" in
		"${cur_uid}:${cur_gid}" | "${cur_uid}:"*) return 0 ;;
		esac
	fi
	return 1
}

mcp_tools_manual_begin() {
	MCP_TOOLS_MANUAL_ACTIVE=true
	MCP_TOOLS_MANUAL_BUFFER=""
}

mcp_tools_manual_abort() {
	MCP_TOOLS_MANUAL_ACTIVE=false
	MCP_TOOLS_MANUAL_BUFFER=""
}

mcp_tools_schema_normalizer() {
	cat <<'EOF'
def ensure_schema:
	if (type == "object") then
		(if ((.type // "") | length) > 0 then . else . + {type: "object"} end)
		| (if (.properties | type) == "object" then . else . + {properties: {}} end)
	else
		{type: "object", properties: {}}
	end;
EOF
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

	local registry_json
	if ! registry_json="$(printf '%s' "${MCP_TOOLS_MANUAL_BUFFER}" | awk -v RS='\036' '{if ($0 != "") print $0}' | "${MCPBASH_JSON_TOOL_BIN}" -s '
		map(select(.name and .path)) |
		unique_by(.name) |
		map({
			name: .name,
			description: (.description // ""),
			path: .path,
			inputSchema: (.inputSchema // .arguments // {type: "object", properties: {}}),
			timeoutSecs: (.timeoutSecs // null),
			outputSchema: (.outputSchema // null),
			icons: (.icons // null),
			annotations: (.annotations // null)
		}) |
		map(
			if .outputSchema == null then del(.outputSchema) else . end |
			if .icons == null then del(.icons) else . end |
			if .annotations == null then del(.annotations) else . end
		) |
		sort_by(.name) |
		{
			version: 1,
			generatedAt: (now | todate),
			items: .,
			total: length
		}
	')"; then
		mcp_tools_manual_abort
		mcp_tools_error -32603 "Manual registration parsing failed"
		return 1
	fi

	registry_json="$(printf '%s' "${registry_json}" | "${MCPBASH_JSON_TOOL_BIN}" -c '
		'"$(mcp_tools_schema_normalizer)"'
		.items |= map(.inputSchema = (.inputSchema | ensure_schema))
	')"

	local items_json
	items_json="$(printf '%s' "${registry_json}" | "${MCPBASH_JSON_TOOL_BIN}" -c '.items')"
	local hash
	hash="$(mcp_hash_string "${items_json}")"

	registry_json="$(printf '%s' "${registry_json}" | "${MCPBASH_JSON_TOOL_BIN}" --arg hash "${hash}" '.hash = $hash')"

	local previous_hash="${MCP_TOOLS_REGISTRY_HASH}"
	MCP_TOOLS_REGISTRY_JSON="${registry_json}"
	MCP_TOOLS_REGISTRY_HASH="${hash}"
	MCP_TOOLS_TOTAL="$(printf '%s' "${registry_json}" | "${MCPBASH_JSON_TOOL_BIN}" '.total')"

	if ! mcp_tools_enforce_registry_limits "${MCP_TOOLS_TOTAL}" "${registry_json}"; then
		mcp_tools_manual_abort
		return 1
	fi

	MCP_TOOLS_MANUAL_ACTIVE=false
	MCP_TOOLS_MANUAL_BUFFER=""

	MCP_TOOLS_LAST_SCAN="$(date +%s)"
	local write_rc=0
	mcp_registry_write_with_lock "${MCP_TOOLS_REGISTRY_PATH}" "${registry_json}" || write_rc=$?
	if [ "${write_rc}" -ne 0 ]; then
		mcp_tools_manual_abort
		return "${write_rc}"
	fi
	return 0
}

mcp_tools_normalize_schema() {
	local raw="$1"
	local normalized
	if ! normalized="$({ printf '%s' "${raw}"; } | "${MCPBASH_JSON_TOOL_BIN}" -c '
		'"$(mcp_tools_schema_normalizer)"'
		ensure_schema
	' 2>/dev/null)"; then
		normalized='{"type":"object","properties":{}}'
	fi
	printf '%s' "${normalized}"
}

mcp_tools_normalize_local_path() {
	local raw="$1"
	if [ -z "${raw}" ]; then
		return 1
	fi
	local abs="${raw}"
	if [[ "${abs}" != /* ]]; then
		if [ -n "${MCPBASH_PROJECT_ROOT:-}" ]; then
			abs="${MCPBASH_PROJECT_ROOT%/}/${abs}"
		else
			abs="$(pwd)/${abs}"
		fi
	fi
	if declare -F mcp_roots_normalize_path >/dev/null 2>&1; then
		if ! abs="$(mcp_roots_normalize_path "${abs}")"; then
			return 1
		fi
	else
		local dir base
		dir="$(cd "$(dirname "${abs}")" 2>/dev/null && pwd -P)" || return 1
		base="$(basename "${abs}")"
		abs="${dir}/${base}"
	fi
	printf '%s' "${abs}"
}

mcp_tools_embed_resource_from_path() {
	local path="$1"
	local mime_hint="${2:-}"
	local uri_hint="${3:-}"

	local abs
	if ! abs="$(mcp_tools_normalize_local_path "${path}")"; then
		return 1
	fi
	if declare -F mcp_roots_contains_path >/dev/null 2>&1; then
		# Debug: log containment check details
		if mcp_logging_is_enabled "debug"; then
			local roots_debug=""
			local r
			for r in "${MCPBASH_ROOTS_PATHS[@]:-}"; do
				roots_debug="${roots_debug}[${r}] "
			done
			mcp_logging_debug "${MCP_TOOLS_LOGGER}" "Containment check: path=${abs} roots=${roots_debug}"
		fi
		if ! mcp_roots_contains_path "${abs}"; then
			local roots_list=""
			local r
			for r in "${MCPBASH_ROOTS_PATHS[@]:-}"; do
				roots_list="${roots_list}[${r}] "
			done
			mcp_logging_warning "${MCP_TOOLS_LOGGER}" "Embedded resource skipped (outside allowed roots): path=${abs} roots=${roots_list}"
			return 1
		fi
	fi
	if [ ! -r "${abs}" ]; then
		mcp_logging_warning "${MCP_TOOLS_LOGGER}" "Embedded resource unreadable: ${abs}"
		return 1
	fi

	local uri="${uri_hint}"
	if [ -z "${uri}" ] && command -v mcp_uri_file_uri_from_path >/dev/null 2>&1; then
		uri="$(mcp_uri_file_uri_from_path "${abs}" 2>/dev/null || true)"
	elif [ -z "${uri}" ]; then
		uri="file://${abs}"
	fi

	local content_obj
	if ! content_obj="$(mcp_resource_content_object_from_file "${abs}" "${mime_hint}" "${uri}")"; then
		return 1
	fi
	printf '%s' "${content_obj}"
}

mcp_tools_collect_embedded_resources() {
	local spec_file="$1"

	if [[ "${MCPBASH_JSON_TOOL:-none}" = "none" ]]; then
		return 0
	fi

	local specs_json=""
	if [ -s "${spec_file}" ]; then
		specs_json="$("${MCPBASH_JSON_TOOL_BIN}" -c '
			def normalize:
				if type == "string" then {path: ., mimeType: null, uri: null}
				elif type == "object" then {path: (.path // ""), mimeType: (.mimeType // null), uri: (.uri // null)}
				else empty end;
			try (
				if type == "array" then . else [.] end
				| map(normalize | select(.path != ""))
			) catch []
		' "${spec_file}" 2>/dev/null || true)"
	fi

	if [ -z "${specs_json}" ]; then
		specs_json="$("${MCPBASH_JSON_TOOL_BIN}" -Rs '
			if length == 0 then [] else
				split("\n")
				| map(select(length > 0))
				| map(split("\t"))
				| map({path: (.[0] // ""), mimeType: (.[1]? // null), uri: (.[2]? // null)})
				| map(select(.path != ""))
			end
		' "${spec_file}" 2>/dev/null || true)"
	fi

	if [ -z "${specs_json}" ] || [ "${specs_json}" = "[]" ] || [ "${specs_json}" = "null" ]; then
		return 0
	fi

	local contents=()
	local embed_attempts=0
	local embed_added=0

	while IFS=$'\t' read -r path mime uri || [ -n "${path}" ]; do
		[ -n "${path}" ] || continue
		((embed_attempts++)) || true
		local content_obj
		# Temporarily removed 2>/dev/null for Windows path debugging
		content_obj="$(mcp_tools_embed_resource_from_path "${path}" "${mime}" "${uri}" || true)"
		if [ -n "${content_obj}" ]; then
			content_obj="$(
				printf '%s' "${content_obj}" | "${MCPBASH_JSON_TOOL_BIN}" -c '{type:"resource",resource:.}' 2>/dev/null || true
			)"
			if [ -n "${content_obj}" ]; then
				contents+=("${content_obj}")
				((embed_added++)) || true
			fi
		else
			if declare -F mcp_logging_debug >/dev/null 2>&1; then
				mcp_logging_debug "${MCP_TOOLS_LOGGER}" "Embedded resource skipped for path=${path}"
			fi
		fi
	done < <(printf '%s' "${specs_json}" | "${MCPBASH_JSON_TOOL_BIN}" -r '
		.[]
		| "\(.path // "")\t\(.mimeType // "")\t\(.uri // "")"
	')

	if [ "${#contents[@]}" -eq 0 ]; then
		if [ "${embed_attempts}" -gt 0 ] && declare -F mcp_logging_debug >/dev/null 2>&1; then
			mcp_logging_debug "${MCP_TOOLS_LOGGER}" "No embedded resources added from ${spec_file}; check roots, readability, or format"
		fi
		return 0
	fi

	printf '[%s]' "$(
		IFS=,
		printf '%s' "${contents[*]}"
	)"
}
mcp_tools_registry_max_bytes() {
	mcp_registry_global_max_bytes
}

mcp_tools_enforce_registry_limits() {
	local total="$1"
	local json_payload="$2"
	local limit_or_size

	if ! limit_or_size="$(mcp_registry_check_size "${json_payload}")"; then
		mcp_tools_error -32603 "Tool registry exceeds ${limit_or_size} byte cap"
		return 1
	fi
	if [ "${total}" -gt 500 ]; then
		mcp_logging_warning "${MCP_TOOLS_LOGGER}" "Tools registry contains ${total} entries; consider manual registration"
	fi
	return 0
}

mcp_tools_apply_manual_registration() {
	local manual_status=0
	mcp_registry_register_apply "tools"
	manual_status=$?
	if [ "${manual_status}" -ne 0 ]; then
		if [ "${manual_status}" -eq 2 ]; then
			local err
			err="$(mcp_registry_register_error_for_kind "tools")"
			if [ -z "${err}" ]; then
				err="Manual registration script returned empty output or non-zero"
			fi
			mcp_logging_warning "${MCP_TOOLS_LOGGER}" "${err}"
		fi
		return "${manual_status}"
	fi
	# mcp_registry_register_apply returns 0 for both ok and skipped.
	# Treat skipped as "not applied" so we fall back to cache/scan.
	if [ "${MCP_REGISTRY_REGISTER_LAST_APPLIED:-false}" = "true" ]; then
		return 0
	fi
	return 1
}

mcp_tools_load_cache_if_empty() {
	if [ -n "${MCP_TOOLS_REGISTRY_JSON}" ] || [ ! -f "${MCP_TOOLS_REGISTRY_PATH}" ]; then
		return 0
	fi

	local tmp_json=""
	if tmp_json="$(cat "${MCP_TOOLS_REGISTRY_PATH}")"; then
		if printf '%s' "${tmp_json}" | "${MCPBASH_JSON_TOOL_BIN}" . >/dev/null 2>&1; then
			MCP_TOOLS_REGISTRY_JSON="${tmp_json}"
			MCP_TOOLS_REGISTRY_HASH="$(printf '%s' "${MCP_TOOLS_REGISTRY_JSON}" | "${MCPBASH_JSON_TOOL_BIN}" -r '.hash // empty')"
			MCP_TOOLS_TOTAL="$(printf '%s' "${MCP_TOOLS_REGISTRY_JSON}" | "${MCPBASH_JSON_TOOL_BIN}" '.total // 0')"
			if ! mcp_tools_enforce_registry_limits "${MCP_TOOLS_TOTAL}" "${MCP_TOOLS_REGISTRY_JSON}"; then
				return 1
			fi
			# Trust pre-generated cache and start TTL window from now (not file mtime, which fails for extracted bundles)
			if [ -z "${MCP_TOOLS_LAST_SCAN}" ]; then
				MCP_TOOLS_LAST_SCAN="$(date +%s)"
			fi
		else
			MCP_TOOLS_REGISTRY_JSON=""
		fi
	else
		MCP_TOOLS_REGISTRY_JSON=""
	fi
	return 0
}

mcp_tools_cache_fresh() {
	local now="$1"
	local cache_age ttl="${MCP_TOOLS_TTL}"

	if [ -n "${MCP_TOOLS_REGISTRY_JSON}" ] && [ $((now - MCP_TOOLS_LAST_SCAN)) -lt "${ttl}" ]; then
		cache_age=$((now - MCP_TOOLS_LAST_SCAN))
		mcp_logging_debug "${MCP_TOOLS_LOGGER}" "Cache hit: tools.json (age=${cache_age}s, ttl=${ttl}s)"
		return 0
	fi
	if [ -n "${MCP_TOOLS_REGISTRY_JSON}" ]; then
		cache_age=$((now - MCP_TOOLS_LAST_SCAN))
		mcp_logging_debug "${MCP_TOOLS_LOGGER}" "Cache stale: tools.json (age=${cache_age}s, ttl=${ttl}s), will rescan"
	else
		mcp_logging_debug "${MCP_TOOLS_LOGGER}" "Cache miss: tools.json not loaded"
	fi
	return 1
}

mcp_tools_fastpath_hit() {
	local scan_root="$1"
	local now="$2"

	local fastpath_snapshot
	fastpath_snapshot="$(mcp_registry_fastpath_snapshot "${scan_root}")"
	if mcp_registry_fastpath_unchanged "tools" "${fastpath_snapshot}"; then
		MCP_TOOLS_LAST_SCAN="${now}"
		if [ -f "${MCP_TOOLS_REGISTRY_PATH}" ]; then
			local cached_hash
			cached_hash="$("${MCPBASH_JSON_TOOL_BIN}" -r '.hash // empty' "${MCP_TOOLS_REGISTRY_PATH}" 2>/dev/null || true)"
			if [ -n "${cached_hash}" ] && [ "${cached_hash}" != "${MCP_TOOLS_REGISTRY_HASH}" ]; then
				local cached_json cached_total
				cached_json="$(cat "${MCP_TOOLS_REGISTRY_PATH}" 2>/dev/null || true)"
				cached_total="$("${MCPBASH_JSON_TOOL_BIN}" '.total // 0' "${MCP_TOOLS_REGISTRY_PATH}" 2>/dev/null || printf '0')"
				MCP_TOOLS_REGISTRY_JSON="${cached_json}"
				MCP_TOOLS_REGISTRY_HASH="${cached_hash}"
				MCP_TOOLS_TOTAL="${cached_total}"
				MCP_TOOLS_CHANGED=true
			fi
		fi
		return 0
	fi
	return 1
}

mcp_tools_perform_full_scan() {
	local scan_root="$1"
	local now="$2"

	local previous_hash="${MCP_TOOLS_REGISTRY_HASH}"
	if [ -z "${previous_hash}" ] && [ -f "${MCP_TOOLS_REGISTRY_PATH}" ]; then
		previous_hash="$("${MCPBASH_JSON_TOOL_BIN}" -r '.hash // empty' "${MCP_TOOLS_REGISTRY_PATH}" 2>/dev/null || true)"
	fi

	mcp_tools_scan "${scan_root}" || return 1
	MCP_TOOLS_LAST_SCAN="${now}"

	local fastpath_snapshot
	fastpath_snapshot="$(mcp_registry_fastpath_snapshot "${scan_root}")"
	mcp_registry_fastpath_store "tools" "${fastpath_snapshot}" || true
	if [ -n "${MCP_TOOLS_REGISTRY_HASH}" ] && [ -n "${fastpath_snapshot}" ]; then
		local combined_hash
		combined_hash="$(mcp_hash_string "${MCP_TOOLS_REGISTRY_HASH}|${fastpath_snapshot}")"
		MCP_TOOLS_REGISTRY_HASH="${combined_hash}"
		MCP_TOOLS_REGISTRY_JSON="$(printf '%s' "${MCP_TOOLS_REGISTRY_JSON}" | "${MCPBASH_JSON_TOOL_BIN}" --arg hash "${combined_hash}" '.hash = $hash')"
		local write_rc=0
		mcp_registry_write_with_lock "${MCP_TOOLS_REGISTRY_PATH}" "${MCP_TOOLS_REGISTRY_JSON}" || write_rc=$?
		if [ "${write_rc}" -ne 0 ]; then
			return "${write_rc}"
		fi
	fi
	if [ "${previous_hash}" != "${MCP_TOOLS_REGISTRY_HASH}" ]; then
		MCP_TOOLS_CHANGED=true
	fi
	return 0
}

mcp_tools_error() {
	_MCP_TOOLS_ERROR_CODE="$1"
	_MCP_TOOLS_ERROR_MESSAGE="$2"
	_MCP_TOOLS_ERROR_DATA="${3:-}"
}

# Emit error JSON to stdout for propagation through command substitution.
# Usage: _mcp_tools_emit_error <code> <message> [data]
# The data argument should be valid JSON (object, string, null, etc.)
# Codes are JSON-RPC 2.0 values; we also emit the reserved server range for
# tool-specific states (-32001 cancelled, -32603 timed out).
_mcp_tools_emit_error() {
	local err_code="$1"
	local err_message="$2"
	local err_data="${3:-null}"
	# Also set the global variables for any code that reads them directly
	_MCP_TOOLS_ERROR_CODE="${err_code}"
	_MCP_TOOLS_ERROR_MESSAGE="${err_message}"
	_MCP_TOOLS_ERROR_DATA="${err_data}"
	# Output error JSON to variable - handler will parse this
	if [ "${MCPBASH_JSON_TOOL:-none}" != "none" ]; then
		local msg_escaped
		msg_escaped="$(printf '%s' "${err_message}" | "${MCPBASH_JSON_TOOL_BIN}" -Rs '.')"
		_MCP_TOOLS_RESULT="$(printf '{"_mcpToolError":true,"code":%s,"message":%s,"data":%s}' "${err_code}" "${msg_escaped}" "${err_data}")"
	else
		# Minimal mode: basic JSON escaping
		local msg_escaped="${err_message//\\/\\\\}"
		msg_escaped="${msg_escaped//\"/\\\"}"
		msg_escaped="${msg_escaped//$'\n'/\\n}"
		_MCP_TOOLS_RESULT="$(printf '{"_mcpToolError":true,"code":%s,"message":"%s","data":%s}' "${err_code}" "${msg_escaped}" "${err_data}")"
	fi
}

# Format timeout error message based on MCPBASH_TIMEOUT_REASON
# Returns message appropriate for the timeout type
mcp_tools_format_timeout_error() {
	local timeout="$1"
	local max_timeout="${MCPBASH_MAX_TIMEOUT_SECS:-600}"
	case "${MCPBASH_TIMEOUT_REASON:-}" in
	idle)
		printf 'Tool timed out after %ss (no progress reported)' "${timeout}"
		;;
	max_exceeded)
		printf 'Tool exceeded maximum runtime of %ss' "${max_timeout}"
		;;
	*)
		printf 'Tool timed out after %ss' "${timeout}"
		;;
	esac
}

mcp_tools_init() {
	if [ -z "${MCP_TOOLS_REGISTRY_PATH}" ]; then
		MCP_TOOLS_REGISTRY_PATH="${MCPBASH_REGISTRY_DIR}/tools.json"
	fi
	mkdir -p "${MCPBASH_REGISTRY_DIR}"
}

mcp_tools_output_schema_error_data() {
	local tool_name="$1"
	local exit_code="$2"
	local stderr_tail="$3"
	local trace_line="$4"
	local trace_available="$5"

	case "${exit_code}" in
	"" | *[!0-9-]*) exit_code=0 ;;
	esac
	case "${trace_available}" in
	"true" | "false") ;;
	*) trace_available="false" ;;
	esac

	if ! mcp_tools_debug_errors_enabled; then
		printf 'null'
		return 0
	fi
	if [ "${MCPBASH_JSON_TOOL:-none}" = "none" ]; then
		printf 'null'
		return 0
	fi

	"${MCPBASH_JSON_TOOL_BIN}" -n \
		--arg tool "${tool_name}" \
		--argjson exitCode "${exit_code}" \
		--argjson traceAvailable "${trace_available}" \
		--arg stderr "${stderr_tail}" \
		--arg traceLine "${trace_line}" \
		'
		{
			tool: $tool,
			exitCode: $exitCode,
			traceAvailable: $traceAvailable
		}
		| if ($stderr|length) > 0 then .stderrTail = $stderr else . end
		| if ($traceLine|length) > 0 then .traceLine = $traceLine else . end
		' 2>/dev/null || printf 'null'
}

mcp_tools_validate_output_schema() {
	local stdout_file="$1"
	local output_schema="$2"
	local has_json_tool="$3"
	local tool_name="${4:-}"
	local exit_code="${5:-0}"
	local stderr_tail="${6:-}"
	local trace_line="${7:-}"
	local trace_available="${8:-false}"

	# Skip validation if no schema or no JSON tool
	if [ "${output_schema}" = "null" ] || [ -z "${output_schema}" ] || [ "${has_json_tool}" != "true" ]; then
		return 0
	fi

	# Parse the tool output as JSON
	local structured_json=""
	if ! structured_json="$("${MCPBASH_JSON_TOOL_BIN}" -c '.' "${stdout_file}" 2>/dev/null)"; then
		local data_json
		data_json="$(mcp_tools_output_schema_error_data "${tool_name}" "${exit_code}" "${stderr_tail}" "${trace_line}" "${trace_available}")"
		_mcp_tools_emit_error -32603 "Tool output is not valid JSON for declared outputSchema" "${data_json}"
		return 1
	fi

	if [ -z "${structured_json}" ]; then
		local data_json
		data_json="$(mcp_tools_output_schema_error_data "${tool_name}" "${exit_code}" "${stderr_tail}" "${trace_line}" "${trace_available}")"
		_mcp_tools_emit_error -32603 "Tool output is empty for declared outputSchema" "${data_json}"
		return 1
	fi

	# Write schema to temp file to avoid shell quoting issues with --argjson
	# Run validation using jq -s pattern (avoid --slurpfile for Windows/gojq compatibility)
	# If tool output is already a CallToolResult (has content array), extract structuredContent for validation
	# errexit-safe: capture exit code without toggling shell state
	local validation_result=""
	local validation_status=0
	validation_result="$(printf '%s\n%s' "${output_schema}" "${structured_json}" | "${MCPBASH_JSON_TOOL_BIN}" -s '
		.[0] as $s |
		.[1] as $raw |
		# Detect if output is already a CallToolResult (has content array and isError field)
		(if ($raw | type) == "object" and ($raw.content | type) == "array" and ($raw | has("isError")) then
			# Extract structuredContent for validation
			$raw.structuredContent // {}
		else
			# Use raw output directly
			$raw
		end) as $data |
		(
			# Check required fields exist
			(($s.required // []) | all(. as $k | $data | has($k)))
		) as $required_ok |
		(
			# Check types match for present fields
			(($s.properties // {}) | keys) |
			all(. as $k |
				($data[$k] // null) as $v |
				(($s.properties // {})[$k].type // "") as $t |
				if ($v == null) or ($t == "") then true
				else
					(if $t=="string" then ($v|type)=="string"
					elif $t=="number" then ($v|type)=="number"
					elif $t=="integer" then ($v|type)=="number" and (($v|floor)==$v)
					elif $t=="boolean" then ($v|type)=="boolean"
					elif $t=="array" then ($v|type)=="array"
					elif $t=="object" then ($v|type)=="object"
					else true end)
				end)
		) as $types_ok |
		if ($s.type // "object") != "object" then true
		elif $required_ok and $types_ok then true
		else false
		end
	' 2>/dev/null)" && validation_status=0 || validation_status=$?

	if [ "${validation_status}" -ne 0 ]; then
		local data_json
		data_json="$(mcp_tools_output_schema_error_data "${tool_name}" "${exit_code}" "${stderr_tail}" "${trace_line}" "${trace_available}")"
		_mcp_tools_emit_error -32603 "Tool output does not satisfy outputSchema" "${data_json}"
		return 1
	fi

	# Check result - must be exactly true
	if [ "${validation_result}" = "true" ]; then
		return 0
	fi

	local data_json
	data_json="$(mcp_tools_output_schema_error_data "${tool_name}" "${exit_code}" "${stderr_tail}" "${trace_line}" "${trace_available}")"
	_mcp_tools_emit_error -32603 "Tool output does not satisfy outputSchema" "${data_json}"
	return 1
}

mcp_tools_apply_manual_json() {
	local manual_json="$1"
	local registry_json

	if ! printf '%s' "${manual_json}" | "${MCPBASH_JSON_TOOL_BIN}" -e '.tools | type == "array"' >/dev/null 2>&1; then
		manual_json='{"tools":[]}'
	fi

	local timestamp
	timestamp="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

	registry_json="$(printf '%s' "${manual_json}" | "${MCPBASH_JSON_TOOL_BIN}" --arg ts "${timestamp}" '{
		version: 1,
		generatedAt: $ts,
		items: .tools,
		total: (.tools | length)
	}')"

	local items_json
	items_json="$(printf '%s' "${registry_json}" | "${MCPBASH_JSON_TOOL_BIN}" -c '.items')"
	local hash
	hash="$(mcp_hash_string "${items_json}")"

	registry_json="$(printf '%s' "${registry_json}" | "${MCPBASH_JSON_TOOL_BIN}" --arg hash "${hash}" '.hash = $hash')"

	local new_hash="${hash}"
	MCP_TOOLS_REGISTRY_JSON="${registry_json}"
	MCP_TOOLS_REGISTRY_HASH="${new_hash}"
	MCP_TOOLS_TOTAL="$(printf '%s' "${registry_json}" | "${MCPBASH_JSON_TOOL_BIN}" '.total')"

	if ! mcp_tools_enforce_registry_limits "${MCP_TOOLS_TOTAL}" "${registry_json}"; then
		return 1
	fi
	MCP_TOOLS_LAST_SCAN="$(date +%s)"
	local write_rc=0
	mcp_registry_write_with_lock "${MCP_TOOLS_REGISTRY_PATH}" "${registry_json}" || write_rc=$?
	if [ "${write_rc}" -ne 0 ]; then
		return "${write_rc}"
	fi
}

mcp_tools_refresh_registry() {
	local scan_root
	scan_root="$(mcp_tools_scan_root)"
	mcp_tools_init

	# Static registry mode: check register.json (data-only), skip register.sh (shell code)
	if [ "${MCPBASH_STATIC_REGISTRY:-0}" = "1" ]; then
		local json_path
		json_path="$(mcp_registry_declarative_path)"

		# Still allow declarative overrides via register.json (but NOT register.sh)
		if [ -f "${json_path}" ]; then
			mcp_registry_register_apply "tools"
			if [ "${MCP_REGISTRY_REGISTER_LAST_APPLIED:-false}" = "true" ]; then
				return 0
			fi
		fi
		# Load pre-generated cache
		if ! mcp_tools_load_cache_if_empty; then
			return 1
		fi
		# Check format version for cache compatibility
		if [ -n "${MCP_TOOLS_REGISTRY_JSON}" ]; then
			local cache_version
			cache_version="$(printf '%s' "${MCP_TOOLS_REGISTRY_JSON}" | "${MCPBASH_JSON_TOOL_BIN}" -r '.format_version // 0')"
			if [ "${cache_version}" != "1" ]; then
				mcp_logging_debug "${MCP_TOOLS_LOGGER}" "Static registry mode: cache format version mismatch (expected 1, got ${cache_version}), falling back to discovery"
				MCP_TOOLS_REGISTRY_JSON=""
			fi
		fi
		# Return if cache valid AND not CLI forced refresh (LAST_SCAN=0)
		if [ -n "${MCP_TOOLS_REGISTRY_JSON}" ] && [ "${MCP_TOOLS_LAST_SCAN}" != "0" ]; then
			# One-time info log to help developers who forget to disable static mode
			if [ "${MCPBASH_STATIC_REGISTRY_LOGGED:-}" != "true" ]; then
				mcp_logging_info "${MCP_TOOLS_LOGGER}" "Static registry mode active - new tools/resources won't be discovered until restart or MCPBASH_STATIC_REGISTRY=0"
				export MCPBASH_STATIC_REGISTRY_LOGGED=true
			fi
			mcp_logging_debug "${MCP_TOOLS_LOGGER}" "Static registry mode: using pre-generated cache (${MCP_TOOLS_TOTAL} tools)"
			return 0
		fi
		# Fall through to normal discovery if cache missing or CLI forced
		if [ -z "${MCP_TOOLS_REGISTRY_JSON}" ]; then
			mcp_logging_debug "${MCP_TOOLS_LOGGER}" "Static registry mode: cache missing/invalid, falling back to discovery"
		fi
	fi

	# Registry refresh order: prefer user-provided server.d/register.sh output,
	# then reuse cached JSON if TTL has not expired, finally fall back to a full
	# filesystem scan (with fastpath snapshot to avoid rescanning unchanged trees).
	local manual_status
	manual_status=2
	mcp_tools_apply_manual_registration
	manual_status=$?
	if [ "${manual_status}" -eq 0 ]; then
		return 0
	fi
	if [ "${manual_status}" -eq 2 ]; then
		return 1
	fi

	local now
	now="$(date +%s)"

	if ! mcp_tools_load_cache_if_empty; then
		return 1
	fi

	if mcp_tools_cache_fresh "${now}"; then
		return 0
	fi

	if mcp_tools_fastpath_hit "${scan_root}" "${now}"; then
		return 0
	fi

	if ! mcp_tools_perform_full_scan "${scan_root}" "${now}"; then
		return 1
	fi
	return 0
}

mcp_tools_scan() {
	local scan_root="${1:-${MCPBASH_TOOLS_DIR}}"
	local items_file
	items_file="$(mktemp "${MCPBASH_TMP_ROOT}/mcp-tools-items.XXXXXX")"

	if [ -d "${scan_root}" ]; then
		while IFS= read -r -d '' path; do
			# Refuse filenames with newlines/CR to avoid corrupting registries/logs.
			case "${path}" in
			*$'\n'* | *$'\r'*)
				rm -f "${items_file}"
				mcp_tools_error -32603 "Tool scan encountered unsupported filename (newline/CR) under tools/"
				return 1
				;;
			esac
			# On Windows (Git Bash/MSYS), -x test is unreliable. Check for shebang or .sh extension as fallback.
			if [ ! -x "${path}" ]; then
				# Fallback: check if file has shebang or is .sh/.bash
				if [[ ! "${path}" =~ \.(sh|bash)$ ]] && ! head -n1 "${path}" 2>/dev/null | grep -q '^#!'; then
					continue
				fi
			fi
			local rel_path="${path#"${MCPBASH_TOOLS_DIR}"/}"
			# Enforce per-tool subdirectories under tools/ (ignore root-level scripts)
			case "${rel_path}" in
			*/*) ;;
			*) continue ;;
			esac
			local base_name
			base_name="$(basename "${path}")"
			# Skip scaffolded smoke test scripts (not tools)
			if [ "${base_name}" = "smoke.sh" ]; then
				continue
			fi
			local name="${base_name%.*}"
			local dir_name
			dir_name="$(dirname "${path}")"
			local meta_json="${dir_name}/${base_name}.meta.json"
			if [ ! -f "${meta_json}" ]; then
				local stem="${base_name%.*}"
				if [ -n "${stem}" ] && [ "${stem}" != "${base_name}" ]; then
					local alt_meta="${dir_name}/${stem}.meta.json"
					if [ -f "${alt_meta}" ]; then
						meta_json="${alt_meta}"
					fi
				fi
			fi
			local description=""
			local arguments="{}"
			local timeout=""
			local output_schema="null"
			local icons="null"
			local annotations="null"

			if [ -f "${meta_json}" ]; then
				# Read each field individually to handle multi-line descriptions correctly
				local meta_name meta_desc meta_args meta_timeout meta_outschema meta_icons meta_annot
				meta_name="$("${MCPBASH_JSON_TOOL_BIN}" -r '.name // ""' "${meta_json}" 2>/dev/null || true)"
				meta_desc="$("${MCPBASH_JSON_TOOL_BIN}" -r '.description // ""' "${meta_json}" 2>/dev/null || true)"
				meta_args="$("${MCPBASH_JSON_TOOL_BIN}" -c '.inputSchema // .arguments // {type:"object",properties:{}}' "${meta_json}" 2>/dev/null || echo '{}')"
				meta_timeout="$("${MCPBASH_JSON_TOOL_BIN}" -r '.timeoutSecs // ""' "${meta_json}" 2>/dev/null || true)"
				meta_outschema="$("${MCPBASH_JSON_TOOL_BIN}" -c '.outputSchema // null' "${meta_json}" 2>/dev/null || echo 'null')"
				meta_icons="$("${MCPBASH_JSON_TOOL_BIN}" -c '.icons // null' "${meta_json}" 2>/dev/null || echo 'null')"
				meta_annot="$("${MCPBASH_JSON_TOOL_BIN}" -c '.annotations // null' "${meta_json}" 2>/dev/null || echo 'null')"

				if [ -n "${meta_name}" ] || [ -n "${meta_desc}" ]; then
					[ -n "${meta_args}" ] || meta_args='{}'
					[ -n "${meta_outschema}" ] || meta_outschema='null'
					name="${meta_name:-${name}}"
					description="${meta_desc:-${description}}"
					arguments="${meta_args}"
					timeout="${meta_timeout}"
					output_schema="${meta_outschema}"
					icons="${meta_icons:-${icons}}"
					annotations="${meta_annot:-${annotations}}"
					# Convert local file paths to data URIs
					local meta_dir
					meta_dir="$(dirname "${meta_json}")"
					icons="$(mcp_json_icons_to_data_uris "${icons}" "${meta_dir}")"
				fi
			fi

			if [ "${arguments}" = "{}" ]; then
				local header
				header="$(head -n 10 "${path}")"
				local mcp_line
				mcp_line="$(printf '%s\n' "${header}" | grep "mcp:" | head -n 1)"
				if [ -n "${mcp_line}" ]; then
					local json_payload
					json_payload="${mcp_line#*mcp:}"
					local h_name
					h_name="$(printf '%s' "${json_payload}" | "${MCPBASH_JSON_TOOL_BIN}" -r '.name // empty' 2>/dev/null)"
					[ -n "${h_name}" ] && name="${h_name}"
					local h_desc
					h_desc="$(printf '%s' "${json_payload}" | "${MCPBASH_JSON_TOOL_BIN}" -r '.description // empty' 2>/dev/null)"
					[ -n "${h_desc}" ] && description="${h_desc}"
					arguments="$(printf '%s' "${json_payload}" | "${MCPBASH_JSON_TOOL_BIN}" -c '.arguments // {type: "object", properties: {}}' 2>/dev/null)"
					timeout="$(printf '%s' "${json_payload}" | "${MCPBASH_JSON_TOOL_BIN}" -r '.timeoutSecs // empty' 2>/dev/null)"
					output_schema="$(printf '%s' "${json_payload}" | "${MCPBASH_JSON_TOOL_BIN}" -c '.outputSchema // null' 2>/dev/null)"
					icons="$(printf '%s' "${json_payload}" | "${MCPBASH_JSON_TOOL_BIN}" -c '.icons // null' 2>/dev/null)"
					annotations="$(printf '%s' "${json_payload}" | "${MCPBASH_JSON_TOOL_BIN}" -c '.annotations // null' 2>/dev/null)"
					# Convert local file paths to data URIs (relative to tool script dir)
					local script_dir
					script_dir="$(dirname "${path}")"
					icons="$(mcp_json_icons_to_data_uris "${icons}" "${script_dir}")"
				fi
			fi

			arguments="$(mcp_tools_normalize_schema "${arguments}")"

			# Ensure all --argjson values are valid JSON (fallback to safe defaults)
			[ -z "${arguments}" ] && arguments='{"type":"object","properties":{}}'
			[ -z "${output_schema}" ] && output_schema='null'
			[ -z "${icons}" ] && icons='null'
			[ -z "${annotations}" ] && annotations='null'

			# Construct item object
			"${MCPBASH_JSON_TOOL_BIN}" -n \
				--arg name "$name" \
				--arg desc "$description" \
				--arg path "$rel_path" \
				--argjson args "$arguments" \
				--arg timeout "$timeout" \
				--argjson out "$output_schema" \
				--argjson icons "$icons" \
				--argjson annotations "$annotations" \
				'{
					name: $name,
					description: $desc,
					path: $path,
					inputSchema: $args,
					timeoutSecs: (if ($timeout|test("^[0-9]+$")) then ($timeout|tonumber) else null end)
				}
				+ (if $out != null then {outputSchema: $out} else {} end)
				+ (if $icons != null then {icons: $icons} else {} end)
				+ (if $annotations != null then {annotations: $annotations} else {} end)' >>"${items_file}"
		done < <(find "${scan_root}" -type f ! -name ".*" ! -name "*.meta.json" -print0 2>/dev/null)
	fi

	local timestamp
	timestamp="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
	local items_json="[]"
	if [ -s "${items_file}" ]; then
		local parsed
		if parsed="$("${MCPBASH_JSON_TOOL_BIN}" -s 'sort_by([.name, .path])' "${items_file}" 2>/dev/null)"; then
			items_json="${parsed}"
		fi
	fi
	rm -f "${items_file}"

	local hash
	hash="$(mcp_hash_string "${items_json}")"

	local total
	total="$(printf '%s' "${items_json}" | "${MCPBASH_JSON_TOOL_BIN}" 'length' 2>/dev/null)" || total=0
	# Ensure total is a valid number
	case "${total}" in
	'' | *[!0-9]*) total=0 ;;
	esac

	MCP_TOOLS_REGISTRY_JSON="$(printf '%s' "${items_json}" | "${MCPBASH_JSON_TOOL_BIN}" -s \
		--arg ver "1" \
		--arg ts "${timestamp}" \
		--arg hash "${hash}" \
		--argjson total "${total}" \
		'{format_version: 1, version: ($ver|tonumber), generatedAt: $ts, items: .[0], hash: $hash, total: $total}')"

	MCP_TOOLS_REGISTRY_HASH="${hash}"
	MCP_TOOLS_TOTAL="${total}"

	if mcp_logging_is_enabled "debug"; then
		mcp_logging_debug "${MCP_TOOLS_LOGGER}" "Refresh count=${MCP_TOOLS_TOTAL} hash=${MCP_TOOLS_REGISTRY_HASH}"
	fi

	if ! mcp_tools_enforce_registry_limits "${MCP_TOOLS_TOTAL}" "${MCP_TOOLS_REGISTRY_JSON}"; then
		return 1
	fi

	local write_rc=0
	mcp_registry_write_with_lock "${MCP_TOOLS_REGISTRY_PATH}" "${MCP_TOOLS_REGISTRY_JSON}" || write_rc=$?
	if [ "${write_rc}" -ne 0 ]; then
		return "${write_rc}"
	fi
}

mcp_tools_consume_notification() {
	local actually_emit="${1:-true}"
	local current_hash="${MCP_TOOLS_REGISTRY_HASH}"
	_MCP_NOTIFICATION_PAYLOAD=""

	if [ -z "${current_hash}" ]; then
		return 0
	fi

	if [ "${MCP_TOOLS_CHANGED}" != "true" ]; then
		return 0
	fi

	if [ "${actually_emit}" = "true" ]; then
		# shellcheck disable=SC2034  # stored for next consume call
		MCP_TOOLS_LAST_NOTIFIED_HASH="${current_hash}"
		MCP_TOOLS_CHANGED=false
		_MCP_NOTIFICATION_PAYLOAD='{"jsonrpc":"2.0","method":"notifications/tools/list_changed","params":{}}'
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
	# Empty = uninitialized, 0 = CLI forced scan, else check TTL
	if [ -z "${MCP_TOOLS_LAST_SCAN}" ] || [ "${MCP_TOOLS_LAST_SCAN}" -eq 0 ] || [ $((now - MCP_TOOLS_LAST_SCAN)) -ge "${ttl}" ]; then
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
	# Args:
	#   limit  - optional max items per page (stringified number).
	#   cursor - opaque pagination cursor from previous response.
	# Note: ListToolsResult is paginated; we expose total as an extension via
	# result._meta["mcpbash/total"] (instead of a top-level field) for strict-client
	# compatibility.
	# shellcheck disable=SC2034
	_MCP_TOOLS_ERROR_CODE=0
	# shellcheck disable=SC2034
	_MCP_TOOLS_ERROR_MESSAGE=""
	# shellcheck disable=SC2034
	_MCP_TOOLS_ERROR_DATA=""

	mcp_tools_refresh_registry || {
		mcp_tools_error -32603 "Unable to load tool registry"
		return 1
	}

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

	local total="${MCP_TOOLS_TOTAL}"
	local result_json
	result_json="$(printf '%s' "${MCP_TOOLS_REGISTRY_JSON}" | "${MCPBASH_JSON_TOOL_BIN}" -c --argjson offset "${offset}" --argjson limit "${numeric_limit}" --argjson total "${total}" '
		{
			tools: .items[$offset:$offset+$limit],
			_meta: {"mcpbash/total": $total}
		}
	')"

	if ! result_json="$(mcp_paginate_attach_next_cursor "${result_json}" "tools" "${offset}" "${numeric_limit}" "${total}" "${MCP_TOOLS_REGISTRY_HASH}")"; then
		mcp_tools_error -32603 "Unable to encode tools cursor"
		return 1
	fi

	printf '%s' "${result_json}"
}

mcp_tools_metadata_for_name() {
	local name="$1"
	mcp_tools_refresh_registry || return 1
	local metadata
	if ! metadata="$(printf '%s' "${MCP_TOOLS_REGISTRY_JSON}" | "${MCPBASH_JSON_TOOL_BIN}" -c --arg name "${name}" '.items[] | select(.name == $name)' | head -n 1)"; then
		return 1
	fi
	if [ -z "${metadata}" ]; then
		return 1
	fi
	printf '%s' "${metadata}"
}

mcp_tools_stderr_capture_enabled() {
	local flag="${MCPBASH_TOOL_STDERR_CAPTURE:-true}"
	case "${flag}" in
	"" | "1" | "true" | "TRUE" | "yes" | "on") return 0 ;;
	*) return 1 ;;
	esac
}

mcp_tools_timeout_capture_enabled() {
	local flag="${MCPBASH_TOOL_TIMEOUT_CAPTURE:-true}"
	case "${flag}" in
	"" | "1" | "true" | "TRUE" | "yes" | "on") return 0 ;;
	*) return 1 ;;
	esac
}

mcp_tools_debug_errors_enabled() {
	local flag="${MCPBASH_DEBUG_ERRORS:-false}"
	case "${flag}" in
	"" | "0" | "false" | "FALSE" | "no" | "off") return 1 ;;
	*) return 0 ;;
	esac
}

mcp_tools_stderr_tail() {
	local file="$1"
	local limit="${2:-4096}"
	[ -n "${file}" ] || return 0
	[ -f "${file}" ] || return 0
	tail -c "${limit}" "${file}" 2>/dev/null | tr -d '\0'
}

mcp_tools_trace_enabled() {
	local flag="${MCPBASH_TRACE_TOOLS:-false}"
	case "${flag}" in
	"1" | "true" | "TRUE" | "yes" | "on") return 0 ;;
	*) return 1 ;;
	esac
}

mcp_tools_trace_ps4() {
	if [ -n "${MCPBASH_TRACE_PS4:-}" ]; then
		printf '%s' "${MCPBASH_TRACE_PS4}"
		return 0
	fi
	printf '+ ${BASH_SOURCE[0]##*/}:${LINENO}: '
}

mcp_tools_trace_mode() {
	local mode="fd"
	if [[ "${BASH_VERSINFO[0]:-0}" -lt 4 ]]; then
		mode="stderr"
	fi
	printf '%s' "${mode}"
}

mcp_tools_trace_split_stderr() {
	local stderr_file="$1"
	local trace_file="$2"
	local tmp_root="$3"
	[[ -n "${stderr_file}" ]] || return 0
	[[ -f "${stderr_file}" ]] || return 0
	[[ -n "${trace_file}" ]] || return 0

	local tmp_file=""
	if [[ -n "${tmp_root}" ]]; then
		tmp_file="$(mktemp "${tmp_root}/mcp-tools-stderr.XXXXXX" 2>/dev/null || true)"
	fi
	if [[ -z "${tmp_file}" ]]; then
		local fallback_root="${TMPDIR:-/tmp}"
		tmp_file="$(mktemp "${fallback_root%/}/mcp-tools-stderr.XXXXXX" 2>/dev/null || true)"
	fi
	[[ -n "${tmp_file}" ]] || return 0

	: >"${trace_file}" 2>/dev/null || true
	awk -v trace_file="${trace_file}" '
		/^\+?[[:space:]]*[^:]+:[0-9]+:[[:space:]]*/ { print >> trace_file; next }
		{ print }
	' "${stderr_file}" >"${tmp_file}" 2>/dev/null || true

	mv "${tmp_file}" "${stderr_file}" 2>/dev/null || rm -f "${tmp_file}" 2>/dev/null || true
}

mcp_tools_json_escape() {
	local value="${1:-}"
	value="${value//\\/\\\\}"
	value="${value//\"/\\\"}"
	value="${value//$'\n'/\\n}"
	value="${value//$'\r'/\\r}"
	printf '%s' "${value}"
}

mcp_tools_gh_escape() {
	local value="${1:-}"
	value="${value//%/%25}"
	value="${value//$'\r'/%0D}"
	value="${value//$'\n'/%0A}"
	printf '%s' "${value}"
}

mcp_tools_emit_github_annotation() {
	local tool="$1"
	local message="$2"
	local trace_line="$3"
	[ "${GITHUB_ACTIONS:-false}" = "true" ] || return 0
	[ -n "${trace_line}" ] || return 0
	# Expect trace format "+ file:line: rest"
	local file=""
	local line=""
	if [[ "${trace_line}" =~ ^\+?[[:space:]]*([^:]+):([0-9]+):[[:space:]]* ]]; then
		file="${BASH_REMATCH[1]}"
		line="${BASH_REMATCH[2]}"
	fi
	[ -n "${file}" ] && [ -n "${line}" ] || return 0
	local msg="Tool ${tool} failed: ${message}"
	printf '::error file=%s,line=%s::%s\n' "$(mcp_tools_gh_escape "${file}")" "$(mcp_tools_gh_escape "${line}")" "$(mcp_tools_gh_escape "${msg}")" >&2
}

mcp_tools_append_failure_summary() {
	local name="$1"
	local exit_code="$2"
	local message="$3"
	local stderr_tail="$4"
	local trace_line="$5"
	local arg_count="$6"
	local arg_bytes="$7"
	local meta_keys="$8"
	local roots_count="$9"
	local timed_out="${10:-false}"
	if [ "${MCPBASH_CI_MODE:-false}" != "true" ]; then
		return 0
	fi
	if [ -z "${MCPBASH_LOG_DIR:-}" ]; then
		return 0
	fi
	local summary_file="${MCPBASH_LOG_DIR}/failure-summary.jsonl"
	local ts
	ts="$(date -u +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || printf '')"
	local args_hash="n/a"
	if command -v sha256sum >/dev/null 2>&1; then
		args_hash="$(printf '%s' "${MCP_TOOL_ARGS_JSON:-}" | sha256sum | cut -d' ' -f1)"
	elif command -v shasum >/dev/null 2>&1; then
		args_hash="$(printf '%s' "${MCP_TOOL_ARGS_JSON:-}" | shasum -a 256 | cut -d' ' -f1)"
	fi
	{
		printf '{'
		printf '"ts":"%s",' "${ts}"
		printf '"tool":"%s",' "$(mcp_tools_json_escape "${name}")"
		printf '"exitCode":%s,' "${exit_code:-0}"
		printf '"timedOut":%s,' "${timed_out}"
		printf '"argCount":%s,' "${arg_count:-0}"
		printf '"argBytes":%s,' "${arg_bytes:-0}"
		printf '"argHash":"%s",' "${args_hash}"
		printf '"metaKeys":%s,' "${meta_keys:-0}"
		printf '"roots":%s,' "${roots_count:-0}"
		printf '"message":"%s",' "$(mcp_tools_json_escape "${message}")"
		printf '"stderrTail":"%s",' "$(mcp_tools_json_escape "${stderr_tail}")"
		printf '"traceLine":"%s"' "$(mcp_tools_json_escape "${trace_line}")"
		printf '}\n'
	} >>"${summary_file}" 2>/dev/null || true
}

# shellcheck disable=SC2031  # Subshell env exports are deliberate; parent values remain unchanged.
mcp_tools_call() {
	local name="$1"
	local args_json="$2"
	local timeout_override="$3"
	local request_meta="${4:-"{}"}"
	# Args:
	#   name             - tool name as registered.
	#   args_json        - JSON string of parameters (object shape, possibly "{}").
	#   timeout_override - optional numeric seconds to override metadata timeout.
	#   request_meta     - optional JSON string of _meta from the tools/call request.
	# shellcheck disable=SC2034
	_MCP_TOOLS_ERROR_CODE=0
	# shellcheck disable=SC2034
	_MCP_TOOLS_ERROR_MESSAGE=""
	# shellcheck disable=SC2034
	_MCP_TOOLS_ERROR_DATA=""
	# shellcheck disable=SC2034
	_MCP_TOOLS_RESULT=""

	local metadata
	if ! metadata="$(mcp_tools_metadata_for_name "${name}")"; then
		_mcp_tools_emit_error -32602 "Tool '${name}' not found" "null"
		return 1
	fi

	# Extract metadata fields in single jq pass (per json-handling rules)
	local tool_path metadata_timeout output_schema progress_extends max_timeout_secs
	read -r tool_path metadata_timeout progress_extends max_timeout_secs < <(printf '%s' "${metadata}" \
		| "${MCPBASH_JSON_TOOL_BIN}" -r '[.path // "", .timeoutSecs // "", .progressExtendsTimeout // "", .maxTimeoutSecs // ""] | @tsv' 2>/dev/null || printf '%s\t%s\t%s\t%s\n' "" "" "" "")
	output_schema="$(printf '%s' "${metadata}" | "${MCPBASH_JSON_TOOL_BIN}" -c '.outputSchema // null')"
	case "${metadata_timeout}" in
	"" | "null") metadata_timeout="" ;;
	esac
	case "${output_schema}" in
	"" | "null") output_schema="null" ;;
	esac
	# Set progress-aware timeout environment for worker subshell
	if [ "${progress_extends}" = "true" ]; then
		export MCPBASH_PROGRESS_EXTENDS_TIMEOUT=true
	fi
	if [ -n "${max_timeout_secs}" ] && [ "${max_timeout_secs}" != "null" ]; then
		export MCPBASH_MAX_TIMEOUT_SECS="${max_timeout_secs}"
	fi
	if [ -z "${tool_path}" ]; then
		_mcp_tools_emit_error -32602 "Tool '${name}' path unavailable" "null"
		return 1
	fi

	# Warn once per process when running in inherit mode, since tools then
	# receive the full host environment including any secrets present.
	local env_mode_raw="${MCPBASH_TOOL_ENV_MODE:-minimal}"
	local env_mode_lc
	env_mode_lc="$(printf '%s' "${env_mode_raw}" | tr '[:upper:]' '[:lower:]')"
	if [ "${env_mode_lc}" = "inherit" ] && [ "${MCPBASH_TOOL_ENV_INHERIT_WARNED}" != "true" ]; then
		MCPBASH_TOOL_ENV_INHERIT_WARNED="true"
		mcp_logging_warning "${MCP_TOOLS_LOGGER}" "MCPBASH_TOOL_ENV_MODE=inherit; tools receive the full host environment"
	fi
	if [ "${env_mode_lc}" = "inherit" ] && [ "${MCPBASH_TOOL_ENV_INHERIT_ALLOW:-false}" != "true" ]; then
		mcp_tools_error -32602 "MCPBASH_TOOL_ENV_MODE=inherit requires MCPBASH_TOOL_ENV_INHERIT_ALLOW=true"
		return 1
	fi

	# Initialize and enforce project policy (server.d/policy.sh can override).
	mcp_tools_policy_init
	if ! mcp_tools_policy_check "${name}" "${metadata}"; then
		if [ "${_MCP_TOOLS_ERROR_CODE:-0}" -eq 0 ]; then
			mcp_tools_error -32602 "Tool '${name}' blocked by policy"
		fi
		local policy_data="${_MCP_TOOLS_ERROR_DATA:-null}"
		[ -z "${policy_data}" ] && policy_data="null"
		_mcp_tools_emit_error "${_MCP_TOOLS_ERROR_CODE}" "${_MCP_TOOLS_ERROR_MESSAGE}" "${policy_data}"
		return 1
	fi

	local absolute_path="${MCPBASH_TOOLS_DIR}/${tool_path}"
	local tool_runner=("${absolute_path}")
	if ! mcp_tools_validate_path "${absolute_path}"; then
		mcp_tools_error -32602 "Tool path rejected by policy"
		return 1
	fi
	# On Windows (Git Bash/MSYS), -x test is unreliable. Check for shebang or .sh extension as fallback.
	if [ ! -x "${absolute_path}" ]; then
		if [[ ! "${absolute_path}" =~ \.(sh|bash)$ ]] && ! head -n1 "${absolute_path}" 2>/dev/null | grep -q '^#!'; then
			mcp_tools_error -32602 "Tool executable missing"
			return 1
		fi
		# Fallback: invoke via shell if not marked executable but looks runnable
		tool_runner=(bash "${absolute_path}")
	fi
	local safe_name
	safe_name="$(printf '%s' "${name}" | tr -c 'A-Za-z0-9._-' '_')"
	local trace_enabled="false"
	local trace_file=""
	local trace_ps4=""
	local trace_mode=""
	local trace_max_bytes="${MCPBASH_TRACE_MAX_BYTES:-1048576}"
	case "${trace_max_bytes}" in
	'' | *[!0-9]*) trace_max_bytes=1048576 ;;
	esac
	if mcp_tools_trace_enabled && [ -n "${MCPBASH_STATE_DIR:-}" ]; then
		trace_enabled="true"
		trace_ps4="$(mcp_tools_trace_ps4)"
		trace_mode="$(mcp_tools_trace_mode)"
		local trace_base="${MCPBASH_LOG_DIR:-${MCPBASH_STATE_DIR}}"
		mkdir -p "${trace_base}" 2>/dev/null || true
		trace_file="${trace_base}/trace.${safe_name}.${BASHPID:-$$}.${RANDOM}.log"
		# Prefer bash -x when we can detect shell scripts.
		if [ "${tool_runner[0]}" = "bash" ]; then
			tool_runner=(bash -x "${tool_runner[@]:1}")
		else
			if [[ "${absolute_path}" =~ \.(sh|bash)$ ]] || head -n1 "${absolute_path}" 2>/dev/null | grep -qi 'bash\|sh'; then
				tool_runner=(bash -x "${absolute_path}")
			fi
		fi
	fi

	local debug_log_file=""
	if [[ -z "${MCPBASH_DEBUG_LOG:-}" ]]; then
		local debug_base="${MCPBASH_LOG_DIR:-${MCPBASH_STATE_DIR:-}}"
		if [[ -n "${debug_base}" ]]; then
			mkdir -p "${debug_base}" 2>/dev/null || true
			local debug_id="${MCPBASH_WORKER_KEY:-${BASHPID:-$$}}"
			debug_id="$(printf '%s' "${debug_id}" | tr -c 'A-Za-z0-9._-' '_')"
			debug_log_file="${debug_base}/tool-debug.${safe_name}.${debug_id}.${RANDOM}.log"
		fi
	fi

	local env_limit="${MCPBASH_ENV_PAYLOAD_THRESHOLD:-65536}"
	case "${env_limit}" in
	'' | *[!0-9]*) env_limit=65536 ;;
	0) env_limit=65536 ;;
	esac

	# Roots environment (server + CLI both source roots.sh; guard keeps minimal stubs happy)
	local MCP_ROOTS_JSON="[]" MCP_ROOTS_PATHS="" MCP_ROOTS_COUNT=0
	if declare -F mcp_roots_wait_ready >/dev/null 2>&1; then
		mcp_roots_wait_ready
		MCP_ROOTS_JSON="$(mcp_roots_get_json)"
		MCP_ROOTS_PATHS="$(mcp_roots_get_paths)"
		MCP_ROOTS_COUNT="${#MCPBASH_ROOTS_PATHS[@]}"
	fi

	local args_env_value="${args_json}"
	local args_file=""
	if [ "${#args_json}" -gt "${env_limit}" ]; then
		args_file="$(mktemp "${MCPBASH_TMP_ROOT}/mcp-tool-args.XXXXXX")"
		printf '%s' "${args_json}" >"${args_file}"
		args_env_value=""
	fi

	local metadata_env_value="${metadata}"
	local metadata_file=""
	if [ "${#metadata}" -gt "${env_limit}" ]; then
		metadata_file="$(mktemp "${MCPBASH_TMP_ROOT}/mcp-tool-metadata.XXXXXX")"
		printf '%s' "${metadata}" >"${metadata_file}"
		metadata_env_value=""
	fi

	# Request _meta (client-provided metadata from tools/call request)
	local request_meta_env_value="${request_meta}"
	local request_meta_file=""
	if [ "${#request_meta}" -gt "${env_limit}" ]; then
		request_meta_file="$(mktemp "${MCPBASH_TMP_ROOT}/mcp-tool-request-meta.XXXXXX")"
		printf '%s' "${request_meta}" >"${request_meta_file}"
		request_meta_env_value=""
	fi

	local tool_resources_file
	tool_resources_file="$(mktemp "${MCPBASH_TMP_ROOT}/mcp-tool-resources.XXXXXX")"

	local tool_error_file
	tool_error_file="$(mktemp "${MCPBASH_TMP_ROOT}/mcp-tool-error.XXXXXX")"

	local effective_timeout="${timeout_override}"
	if [ -z "${effective_timeout}" ] && [ -n "${metadata_timeout}" ]; then
		effective_timeout="${metadata_timeout}"
	fi
	case "${effective_timeout}" in
	'' | *[!0-9]*) effective_timeout="" ;;
	esac

	local arg_count=0
	local arg_bytes=0
	local meta_count=0
	if [ -n "${args_json}" ] && [ "${args_json}" != "{}" ]; then
		arg_count="$(printf '%s' "${args_json}" | "${MCPBASH_JSON_TOOL_BIN}" -r 'keys | length' 2>/dev/null || echo 0)"
		arg_bytes="$(printf '%s' "${args_json}" | wc -c | tr -d ' ')"
	fi
	if [ -n "${metadata}" ] && [ "${metadata}" != "{}" ]; then
		meta_count="$(printf '%s' "${metadata}" | "${MCPBASH_JSON_TOOL_BIN}" -r 'keys | length' 2>/dev/null || echo 0)"
	fi
	if mcp_logging_is_enabled "debug"; then
		mcp_logging_debug "${MCP_TOOLS_LOGGER}" "Invoke tool=${name} arg_count=${arg_count} arg_bytes=${arg_bytes} meta_keys=${meta_count} roots=${MCP_ROOTS_COUNT:-0} timeout=${effective_timeout:-none} trace=${trace_enabled}"
		if mcp_logging_verbose_enabled; then
			mcp_logging_debug "${MCP_TOOLS_LOGGER}" "Tool path=${absolute_path}"
		fi
	fi

	local stdout_file stderr_file
	stdout_file="$(mktemp "${MCPBASH_TMP_ROOT}/mcp-tools-stdout.XXXXXX")"
	stderr_file="$(mktemp "${MCPBASH_TMP_ROOT}/mcp-tools-stderr.XXXXXX")"

	local has_json_tool="false"
	if [ "${MCPBASH_MODE}" != "minimal" ] && [ "${MCPBASH_JSON_TOOL:-none}" != "none" ]; then
		has_json_tool="true"
	fi
	local stream_stderr="${MCPBASH_TOOL_STREAM_STDERR:-false}"

	# Tool invocation lifecycle:
	# 1) Build an isolated env (respecting allowlist/minimal/inherit) and ship
	#    args/metadata via env or temp files to avoid huge env blobs.
	# 2) Run the tool with optional timeout and collect stdout/stderr into temp
	#    files so we can post-process them safely.
	# 3) Prefer structured errors emitted by the tool, enforce size limits, then
	#    validate outputSchema and produce the structured MCP response object.
	# Elicitation environment
	local elicit_supported="0"
	local elicit_request_file=""
	local elicit_response_file=""
	local elicit_key="${MCPBASH_WORKER_KEY:-${key:-}}"
	if declare -F mcp_elicitation_is_supported >/dev/null 2>&1 && [ -n "${elicit_key}" ]; then
		if mcp_elicitation_is_supported; then
			elicit_supported="1"
			elicit_request_file="$(mcp_elicitation_request_path_for_worker "${elicit_key}")"
			elicit_response_file="$(mcp_elicitation_response_path_for_worker "${elicit_key}")"
			rm -f "${elicit_request_file}" "${elicit_response_file}"
		fi
	fi
	if mcp_logging_is_enabled "debug"; then
		mcp_logging_debug "${MCP_TOOLS_LOGGER}" "Elicitation env supported=${elicit_supported} request=${elicit_request_file:-none} response=${elicit_response_file:-none}"
	fi

	cleanup_tool_temp_files() {
		# Preserve temp files when debugging so we can inspect tool I/O.
		if [ "${MCPBASH_PRESERVE_STATE:-}" = "true" ]; then
			return 0
		fi
		rm -f "${stdout_file}" "${stderr_file}"
		[ -n "${tool_resources_file:-}" ] && rm -f "${tool_resources_file}"
		[ -n "${tool_error_file}" ] && rm -f "${tool_error_file}"
		[ -n "${args_file}" ] && rm -f "${args_file}"
		[ -n "${metadata_file}" ] && rm -f "${metadata_file}"
		[ -n "${request_meta_file}" ] && rm -f "${request_meta_file}"
	}

	local exit_code
	# shellcheck disable=SC2030,SC2031,SC2094
	(
		# Environment mutations here are intentionally scoped to this subshell.
		# Ignore SIGTERM in this subshell - only the tool process should be killed
		# The tool runs in its own process via with_timeout, which handles the signal
		trap '' TERM
		set -o pipefail
		cd "${MCPBASH_PROJECT_ROOT}" || exit 1
		MCP_SDK="${MCPBASH_HOME}/sdk"
		MCP_TOOL_NAME="${name}"
		MCP_TOOL_PATH="${absolute_path}"
		# NOTE: Assign secret-bearing MCP_TOOL_*_JSON values before enabling xtrace.
		MCP_TOOL_ARGS_JSON="${args_env_value}"
		MCP_TOOL_METADATA_JSON="${metadata_env_value}"
		MCP_TOOL_META_JSON="${request_meta_env_value}"
		MCP_TOOL_ERROR_FILE="${tool_error_file}"
		if [ -n "${args_file}" ]; then
			MCP_TOOL_ARGS_FILE="${args_file}"
		else
			unset MCP_TOOL_ARGS_FILE 2>/dev/null || true
		fi
		if [ -n "${metadata_file}" ]; then
			MCP_TOOL_METADATA_FILE="${metadata_file}"
		else
			unset MCP_TOOL_METADATA_FILE 2>/dev/null || true
		fi
		if [ -n "${request_meta_file}" ]; then
			MCP_TOOL_META_FILE="${request_meta_file}"
		else
			unset MCP_TOOL_META_FILE 2>/dev/null || true
		fi

		local tool_env_mode
		tool_env_mode="$(printf '%s' "${MCPBASH_TOOL_ENV_MODE:-minimal}" | tr '[:upper:]' '[:lower:]')"
		case " ${tool_env_mode} " in
		" inherit " | " minimal " | " allowlist ") ;;
		*) tool_env_mode="minimal" ;;
		esac

		local trace_active="${trace_enabled}"
		mcp_tools_apply_common_tool_env() {
			# CRLF can leak into env vars on Windows/Git Bash/MSYS; strip it defensively.
			local saw_crlf="false" saw_progress_stream_cr="false" saw_progress_token_cr="false"
			case "${MCP_PROGRESS_STREAM:-}" in
			*$'\r')
				saw_crlf="true"
				saw_progress_stream_cr="true"
				MCP_PROGRESS_STREAM="${MCP_PROGRESS_STREAM%$'\r'}"
				;;
			esac
			case "${MCP_PROGRESS_TOKEN:-}" in
			*$'\r')
				saw_crlf="true"
				saw_progress_token_cr="true"
				MCP_PROGRESS_TOKEN="${MCP_PROGRESS_TOKEN%$'\r'}"
				;;
			esac
			if mcp_logging_is_enabled "debug"; then
				local stream_present="false"
				local token_present="false"
				[ -n "${MCP_PROGRESS_STREAM:-}" ] && stream_present="true"
				[ -n "${MCP_PROGRESS_TOKEN:-}" ] && token_present="true"
				mcp_logging_debug "${MCP_TOOLS_LOGGER}" "Progress wiring: stream_present=${stream_present} token_present=${token_present} env_crlf_stripped=${saw_crlf} stream_had_cr=${saw_progress_stream_cr} token_had_cr=${saw_progress_token_cr}"
				if mcp_logging_verbose_enabled; then
					# Show escaped values so hidden CR/LF or whitespace is visible.
					local stream_q token_q
					printf -v stream_q '%q' "${MCP_PROGRESS_STREAM:-}"
					printf -v token_q '%q' "${MCP_PROGRESS_TOKEN:-}"
					mcp_logging_debug "${MCP_TOOLS_LOGGER}" "Progress wiring: stream=${stream_q} token=${token_q}"
				fi
			fi

			export MCP_SDK MCP_TOOL_NAME MCP_TOOL_PATH MCP_TOOL_ARGS_JSON MCP_TOOL_METADATA_JSON MCP_TOOL_META_JSON
			[ -n "${MCP_TOOL_ARGS_FILE:-}" ] && export MCP_TOOL_ARGS_FILE
			[ -n "${MCP_TOOL_METADATA_FILE:-}" ] && export MCP_TOOL_METADATA_FILE
			[ -n "${MCP_TOOL_META_FILE:-}" ] && export MCP_TOOL_META_FILE
			export MCP_TOOL_ERROR_FILE
			export MCP_TOOL_RESOURCES_FILE="${tool_resources_file}"
			export MCP_ELICIT_SUPPORTED="${elicit_supported}"
			export MCPBASH_JSON_TOOL="${MCPBASH_JSON_TOOL:-}"
			export MCPBASH_JSON_TOOL_BIN="${MCPBASH_JSON_TOOL_BIN:-}"
			export MCPBASH_MODE="${MCPBASH_MODE:-full}"
			if [[ -n "${MCPBASH_DEBUG_LOG:-}" ]]; then
				export MCPBASH_DEBUG_LOG
			elif [[ -n "${debug_log_file}" ]]; then
				export MCPBASH_DEBUG_LOG="${debug_log_file}"
			fi
			if [ "${elicit_supported}" = "1" ]; then
				export MCP_ELICIT_REQUEST_FILE="${elicit_request_file}"
				export MCP_ELICIT_RESPONSE_FILE="${elicit_response_file}"
			fi
			if [ "${trace_enabled}" = "true" ]; then
				# Best-effort: ensure the trace file is not world-readable before xtrace
				# starts writing. On Windows/Git Bash, chmod is best-effort; treat trace
				# files as sensitive regardless.
				: >"${trace_file}" 2>/dev/null || true
				chmod 600 "${trace_file}" 2>/dev/null || true
				export PS4="${trace_ps4}"
				export MCPBASH_TRACE_FILE="${trace_file}"
				if [[ "${trace_mode}" = "fd" ]]; then
					if exec 9>"${trace_file}"; then
						export BASH_XTRACEFD=9
					else
						trace_active="false"
					fi
				fi
			fi
			if declare -F mcp_roots_wait_ready >/dev/null 2>&1; then
				export MCP_ROOTS_JSON="${MCP_ROOTS_JSON:-[]}"
				export MCP_ROOTS_PATHS="${MCP_ROOTS_PATHS:-}"
				export MCP_ROOTS_COUNT="${MCP_ROOTS_COUNT:-0}"
			fi
		}
		if [ "${tool_env_mode}" != "inherit" ]; then
			# Build the isolated tool environment without spawning external `env`.
			# On Windows/Git Bash/MSYS, launching subprocesses with a large host env
			# can hit E2BIG before the tool starts. Prefer bash built-ins.
			local allowlist_raw allowlist_names
			allowlist_raw="${MCPBASH_TOOL_ENV_ALLOWLIST:-}"
			allowlist_raw="${allowlist_raw//,/ }"
			allowlist_names=" ${allowlist_raw} "

			local env_key
			for env_key in $(compgen -e); do
				case "${env_key}" in
				PATH | HOME | TMPDIR | LANG) ;;
				MCP_* | MCPBASH_*) ;;
				*)
					if [ "${tool_env_mode}" = "allowlist" ]; then
						case "${allowlist_names}" in
						*" ${env_key} "*) ;;
						*) unset "${env_key}" 2>/dev/null || true ;;
						esac
					else
						unset "${env_key}" 2>/dev/null || true
					fi
					;;
				esac
			done

			# Ensure baseline vars are exported even if we had to default them.
			export PATH="${PATH:-/usr/bin:/bin}"
			export HOME="${HOME:-${MCPBASH_PROJECT_ROOT:-${PWD}}}"
			export TMPDIR="${TMPDIR:-/tmp}"
			export LANG="${LANG:-C}"

			# Allowlist mode: in addition to keeping already-exported allowlisted vars,
			# also export allowlisted vars when they are set and non-empty (even if they
			# were previously shell-only). This makes allowlist behavior predictable for
			# operators who set variables without `export`.
			if [ "${tool_env_mode}" = "allowlist" ]; then
				local allowlist_var allowlist_value
				for allowlist_var in ${allowlist_raw}; do
					[ -n "${allowlist_var}" ] || continue
					case "${allowlist_var}" in
					[A-Za-z_][A-Za-z0-9_]*) ;;
					*) continue ;;
					esac
					allowlist_value="${!allowlist_var:-}"
					[ -n "${allowlist_value}" ] || continue
					# shellcheck disable=SC2163  # Intentional: export var by name stored in allowlist_var
					export "${allowlist_var}"
				done
			fi

			mcp_tools_apply_common_tool_env
		else
			mcp_tools_apply_common_tool_env
		fi

		if [ "${trace_active}" = "true" ]; then
			set -x
		fi

		mcp_tools_can_stream_stderr() {
			if ! command -v tee >/dev/null 2>&1; then
				return 1
			fi
			if ! { : 2> >(cat >/dev/null); } 2>/dev/null; then
				return 1
			fi
			return 0
		}

		local stderr_streaming_enabled="${stream_stderr}"
		if [ "${stream_stderr}" = "true" ]; then
			if mcp_tools_can_stream_stderr; then
				stderr_streaming_enabled="true"
			else
				stderr_streaming_enabled="false"
				printf 'stream-stderr unavailable; stderr will be buffered\n' >>"${stderr_file}"
			fi
		fi

		if [ -n "${effective_timeout}" ]; then
			if [ "${stderr_streaming_enabled}" = "true" ]; then
				with_timeout "${effective_timeout}" -- "${tool_runner[@]}" 2> >(tee "${stderr_file}" >&2)
			else
				with_timeout "${effective_timeout}" -- "${tool_runner[@]}" 2>>"${stderr_file}"
			fi
		else
			if [ "${stderr_streaming_enabled}" = "true" ]; then
				"${tool_runner[@]}" 2> >(tee "${stderr_file}" >&2)
			else
				"${tool_runner[@]}" 2>>"${stderr_file}"
			fi
		fi
		# Outer stderr append captures shell-level errors; tool stderr is redirected above.
	) >"${stdout_file}" 2>>"${stderr_file}" || exit_code=$?
	exit_code=${exit_code:-0}

	if mcp_logging_is_enabled "debug"; then
		local stdout_size=0
		[ -f "${stdout_file}" ] && stdout_size="$(wc -c <"${stdout_file}" | tr -d ' ')"
		mcp_logging_debug "${MCP_TOOLS_LOGGER}" "Complete tool=${name} exit=${exit_code} stdout_bytes=${stdout_size}"
	fi

	# Prefer explicit tool-authored errors as early as possible.
	if [ -n "${tool_error_file}" ] && [ -s "${tool_error_file}" ]; then
		local tool_error_raw parsed_tool_error
		tool_error_raw="$(cat "${tool_error_file}" 2>/dev/null || true)"
		if [ "${MCPBASH_JSON_TOOL:-none}" != "none" ]; then
			parsed_tool_error="$(
				printf '%s' "${tool_error_raw}" | "${MCPBASH_JSON_TOOL_BIN}" -c '
					select(
						(.code | type) == "number"
						and (.code | floor) == (.code | tonumber)
						and (.message | type) == "string"
					)
					| {code: (.code | tonumber), message: .message, data: (.data // null)}
				' 2>/dev/null || true
			)"
		fi
		if [ -n "${parsed_tool_error}" ]; then
			local te_code te_message te_data
			te_code="$(printf '%s' "${parsed_tool_error}" | "${MCPBASH_JSON_TOOL_BIN}" -r '.code')"
			te_message="$(printf '%s' "${parsed_tool_error}" | "${MCPBASH_JSON_TOOL_BIN}" -r '.message')"
			te_data="$(printf '%s' "${parsed_tool_error}" | "${MCPBASH_JSON_TOOL_BIN}" -c '.data')"
			_mcp_tools_emit_error "${te_code}" "${te_message}" "${te_data}"
		else
			_mcp_tools_emit_error -32603 "Tool failed" "$(printf '%s' "${tool_error_raw}" | "${MCPBASH_JSON_TOOL_BIN}" -Rs '.' 2>/dev/null || printf '"%s"' "${tool_error_raw//\"/\\\"}")"
		fi
		cleanup_tool_temp_files
		return 1
	fi

	# NOTE: errexit toggling removed - code below uses explicit error checks and || true patterns
	local limit="${MCPBASH_MAX_TOOL_OUTPUT_SIZE:-10485760}"
	case "${limit}" in
	'' | *[!0-9]*) limit=10485760 ;;
	esac
	local stdout_size
	stdout_size="$(wc -c <"${stdout_file}" | tr -d ' ')"
	if [ "${stdout_size}" -gt "${limit}" ]; then
		mcp_logging_error "${MCP_TOOLS_LOGGER}" "Tool ${name} output ${stdout_size} bytes exceeds limit ${limit}" || true
		_mcp_tools_emit_error -32603 "Tool output exceeded ${limit} bytes" "null"
		cleanup_tool_temp_files
		return 1
	fi

	local stdout_content
	local stderr_content
	local stderr_limit="${MCPBASH_MAX_TOOL_STDERR_SIZE:-${limit}}"
	case "${stderr_limit}" in
	'' | *[!0-9]*) stderr_limit="${limit}" ;;
	0) stderr_limit="${limit}" ;;
	esac
	if [[ "${trace_enabled}" = "true" && "${trace_mode}" = "stderr" && -n "${trace_file}" ]]; then
		mcp_tools_trace_split_stderr "${stderr_file}" "${trace_file}" "${MCPBASH_TMP_ROOT:-}"
	fi
	local stderr_size
	stderr_size="$(wc -c <"${stderr_file}" | tr -d ' ')"
	if [ "${stderr_size}" -gt "${stderr_limit}" ]; then
		mcp_logging_error "${MCP_TOOLS_LOGGER}" "Tool ${name} stderr ${stderr_size} bytes exceeds limit ${stderr_limit}" || true
		_mcp_tools_emit_error -32603 "Tool stderr exceeded ${stderr_limit} bytes" "null"
		cleanup_tool_temp_files
		return 1
	fi
	stderr_content="${stderr_file}"
	stdout_content="${stdout_file}"

	local stderr_tail_limit="${MCPBASH_TOOL_STDERR_TAIL_LIMIT:-4096}"
	case "${stderr_tail_limit}" in
	'' | *[!0-9]*) stderr_tail_limit=4096 ;;
	esac
	local stderr_tail=""
	if mcp_tools_stderr_capture_enabled && [ -s "${stderr_content}" ]; then
		stderr_tail="$(mcp_tools_stderr_tail "${stderr_content}" "${stderr_tail_limit}")"
	fi

	local cancelled_flag="false"
	if [ -n "${MCP_CANCEL_FILE:-}" ] && [ -f "${MCP_CANCEL_FILE}" ]; then
		cancelled_flag="true"
	fi

	local timed_out="false"
	if [ -n "${effective_timeout}" ]; then
		case "${exit_code}" in
		124 | 137)
			timed_out="true"
			;;
		143)
			if [ "${cancelled_flag}" != "true" ]; then
				timed_out="true"
			fi
			;;
		esac
	fi

	local trace_size=0
	if [ "${trace_enabled}" = "true" ] && [ -n "${trace_file}" ] && [ -f "${trace_file}" ]; then
		trace_size="$(wc -c <"${trace_file}" | tr -d ' ')" || trace_size=0
		if [ "${trace_size}" -gt "${trace_max_bytes}" ]; then
			local trace_tmp="${trace_file}.tmp"
			tail -c "${trace_max_bytes}" "${trace_file}" >"${trace_tmp}" 2>/dev/null || true
			mv "${trace_tmp}" "${trace_file}" 2>/dev/null || true
		fi
	fi
	local trace_line=""
	if [ "${trace_enabled}" = "true" ] && [ -n "${trace_file}" ] && [ -f "${trace_file}" ]; then
		trace_line="$(tail -n 1 "${trace_file}" 2>/dev/null | head -c 512 | tr -d '\0')"
	fi
	local trace_available="false"
	if [[ "${trace_enabled}" = "true" && "${trace_size}" -gt 0 ]]; then
		trace_available="true"
	fi

	if [ "${cancelled_flag}" = "true" ]; then
		_mcp_tools_emit_error -32001 "Tool cancelled" "null"
		cleanup_tool_temp_files
		return 1
	fi

	if [ "${timed_out}" = "true" ]; then
		local timeout_data="null"
		if mcp_tools_timeout_capture_enabled && [ "${MCPBASH_JSON_TOOL:-none}" != "none" ]; then
			timeout_data="$(
				"${MCPBASH_JSON_TOOL_BIN}" -n \
					--argjson code "${exit_code}" \
					--arg stderr "${stderr_tail}" \
					--arg traceLine "${trace_line}" \
					'
					{
						exitCode: $code,
						_meta: ({exitCode: $code} + (if ($stderr|length) > 0 then {stderr: $stderr} else {} end))
					}
					| if ($stderr|length) > 0 then .stderrTail = $stderr else . end
					| if ($traceLine|length) > 0 then .traceLine = $traceLine else . end
					'
			)"
		fi
		local timeout_msg
		timeout_msg="$(mcp_tools_format_timeout_error "${effective_timeout}")"
		mcp_tools_emit_github_annotation "${name}" "${timeout_msg}" "${trace_line}"
		mcp_tools_append_failure_summary "${name}" "${exit_code}" "${timeout_msg}" "${stderr_tail}" "${trace_line}" "${arg_count}" "${arg_bytes}" "${meta_count}" "${MCP_ROOTS_COUNT:-0}" "true"
		_mcp_tools_emit_error -32603 "${timeout_msg}" "${timeout_data}"
		# Suggest enabling progress-aware timeout if tool emitted progress but feature was disabled
		if [ "${MCPBASH_PROGRESS_EXTENDS_TIMEOUT:-false}" != "true" ] && [ -n "${MCP_PROGRESS_STREAM:-}" ] && [ -s "${MCP_PROGRESS_STREAM}" ]; then
			mcp_logging_warning "${MCP_TOOLS_LOGGER}" \
				"Tool '${name}' emitted progress but timed out. Consider enabling MCPBASH_PROGRESS_EXTENDS_TIMEOUT=true or adding progressExtendsTimeout:true to tool.meta.json"
		fi
		cleanup_tool_temp_files
		return 1
	fi

	local tool_error_raw=""
	if [ -n "${tool_error_file}" ] && [ -e "${tool_error_file}" ]; then
		tool_error_raw="$(cat "${tool_error_file}" 2>/dev/null || true)"
	fi

	if [ -n "${tool_error_raw}" ]; then
		mcp_logging_debug "${MCP_TOOLS_LOGGER}" "Tool ${name} emitted structured error ${tool_error_raw}" || true
		if [ "${MCPBASH_JSON_TOOL:-none}" != "none" ]; then
			local parsed
			parsed="$(
				printf '%s' "${tool_error_raw}" | "${MCPBASH_JSON_TOOL_BIN}" -c '
					select(
						(.code | type) == "number"
						and (.code | floor) == (.code | tonumber)
						and (.message | type) == "string"
					)
					| {code: (.code | tonumber), message: .message, data: (.data // null)}
				' 2>/dev/null || true
			)"
			if [ -n "${parsed}" ]; then
				local tool_err_code tool_err_message tool_err_data
				tool_err_code="$(printf '%s' "${parsed}" | "${MCPBASH_JSON_TOOL_BIN}" -r '.code')"
				tool_err_message="$(printf '%s' "${parsed}" | "${MCPBASH_JSON_TOOL_BIN}" -r '.message')"
				tool_err_data="$(printf '%s' "${parsed}" | "${MCPBASH_JSON_TOOL_BIN}" -c '.data')"
				_mcp_tools_emit_error "${tool_err_code}" "${tool_err_message}" "${tool_err_data}"
				cleanup_tool_temp_files
				return 1
			fi
		fi
		_mcp_tools_emit_error -32603 "Tool failed" "$(printf '%s' "${tool_error_raw}" | "${MCPBASH_JSON_TOOL_BIN}" -Rs '.' 2>/dev/null || printf '"%s"' "${tool_error_raw//\"/\\\"}")"
		cleanup_tool_temp_files
		return 1
	fi

	if [ "${exit_code}" -ne 0 ]; then
		local message_from_stderr data_json="" stdout_error_json="" stdout_raw=""
		if [ -s "${stdout_content}" ]; then
			stdout_raw="$(cat "${stdout_content}")"
			if [ "${MCPBASH_JSON_TOOL:-none}" != "none" ]; then
				stdout_error_json="$(
					printf '%s' "${stdout_raw}" | "${MCPBASH_JSON_TOOL_BIN}" -c '
						select(
							(.code | type) == "number"
							and (.code | floor) == (.code | tonumber)
							and (.message | type) == "string"
						)
						| {code: (.code | tonumber), message: .message, data: (.data // null)}
					' 2>/dev/null || true
				)"
			fi
			if [ -n "${stdout_error_json}" ]; then
				local err_code err_message err_data
				err_code="$(printf '%s' "${stdout_error_json}" | "${MCPBASH_JSON_TOOL_BIN}" -r '.code')"
				err_message="$(printf '%s' "${stdout_error_json}" | "${MCPBASH_JSON_TOOL_BIN}" -r '.message')"
				err_data="$(printf '%s' "${stdout_error_json}" | "${MCPBASH_JSON_TOOL_BIN}" -c '.data')"
				_mcp_tools_emit_error "${err_code}" "${err_message}" "${err_data}"
				cleanup_tool_temp_files
				return 1
			fi
			if [ "${MCPBASH_JSON_TOOL:-none}" != "none" ]; then
				local err_code_simple err_message_simple err_data_simple
				err_code_simple="$(printf '%s' "${stdout_raw}" | "${MCPBASH_JSON_TOOL_BIN}" -r '(.code // "")' 2>/dev/null || true)"
				err_message_simple="$(printf '%s' "${stdout_raw}" | "${MCPBASH_JSON_TOOL_BIN}" -r '(.message // "")' 2>/dev/null || true)"
				err_data_simple="$(printf '%s' "${stdout_raw}" | "${MCPBASH_JSON_TOOL_BIN}" -c '(.data // null)' 2>/dev/null || true)"
				if [ -n "${err_code_simple}" ] && [ -n "${err_message_simple}" ]; then
					_mcp_tools_emit_error "${err_code_simple}" "${err_message_simple}" "${err_data_simple:-null}"
					cleanup_tool_temp_files
					return 1
				fi
			fi
			local err_code_guess err_message_guess
			err_code_guess="$(printf '%s' "${stdout_raw}" | sed -n 's/.*\"code\"[[:space:]]*:[[:space:]]*\\([-0-9]*\\).*/\\1/p' | head -n 1)"
			err_message_guess="$(printf '%s' "${stdout_raw}" | sed -n 's/.*\"message\"[[:space:]]*:[[:space:]]*\"\\([^\"]*\\)\".*/\\1/p' | head -n 1)"
			if [ -n "${err_code_guess}" ] && [ -n "${err_message_guess}" ]; then
				local data_escaped
				data_escaped="$(printf '%s' "${stdout_raw}" | "${MCPBASH_JSON_TOOL_BIN}" -Rs '.' 2>/dev/null || printf '"%s"' "${stdout_raw//\"/\\\"}")"
				_mcp_tools_emit_error "${err_code_guess}" "${err_message_guess}" "${data_escaped}"
				cleanup_tool_temp_files
				return 1
			fi
			if [ -n "${stdout_raw}" ]; then
				local data_escaped
				data_escaped="$(printf '%s' "${stdout_raw}" | "${MCPBASH_JSON_TOOL_BIN}" -Rs '.' 2>/dev/null || printf '"%s"' "${stdout_raw//\"/\\\"}")"
				_mcp_tools_emit_error -32603 "Tool failed" "${data_escaped}"
				cleanup_tool_temp_files
				return 1
			fi
		fi

		message_from_stderr="$(printf '%s' "${stderr_tail}" | head -n 1 | tr -d '\r')"
		if [ -z "${message_from_stderr}" ]; then
			message_from_stderr="Tool failed"
		fi
		data_json="null"
		if [ "${MCPBASH_JSON_TOOL:-none}" != "none" ]; then
			data_json="$(
				"${MCPBASH_JSON_TOOL_BIN}" -n \
					--argjson code "${exit_code}" \
					--arg stderr "${stderr_tail}" \
					--arg traceLine "${trace_line}" \
					'
					{
						exitCode: $code,
						_meta: ({exitCode: $code} + (if ($stderr|length) > 0 then {stderr: $stderr} else {} end))
					}
					| if ($stderr|length) > 0 then .stderrTail = $stderr else . end
					| if ($traceLine|length) > 0 then .traceLine = $traceLine else . end
					'
			)"
		fi
		mcp_tools_emit_github_annotation "${name}" "${message_from_stderr}" "${trace_line}"
		mcp_tools_append_failure_summary "${name}" "${exit_code}" "${message_from_stderr}" "${stderr_tail}" "${trace_line}" "${arg_count}" "${arg_bytes}" "${meta_count}" "${MCP_ROOTS_COUNT:-0}" "false"
		_mcp_tools_emit_error -32603 "${message_from_stderr}" "${data_json}"
		cleanup_tool_temp_files
		return 1
	fi

	if ! mcp_tools_validate_output_schema "${stdout_content}" "${output_schema}" "${has_json_tool}" "${name}" "${exit_code}" "${stderr_tail}" "${trace_line}" "${trace_available}"; then
		cleanup_tool_temp_files
		return 1
	fi

	local result_json
	result_json="$(
		"${MCPBASH_JSON_TOOL_BIN}" -n -c \
			--arg name "${name}" \
			--rawfile stdout "${stdout_content}" \
			--arg stderr "${stderr_tail}" \
			--argjson exit_code "${exit_code}" \
			--arg has_json "${has_json_tool}" \
			'
		{
			name: $name,
			content: [],
			isError: false,
			_meta: {
				exitCode: $exit_code
			}
		} as $base |

		# Try to parse stdout as JSON if enabled
		if $has_json == "true" and ($stdout | length > 0) then
			try (
				($stdout | fromjson) as $json |
				# Detect if output is already a CallToolResult (has content array and isError field)
				if ($json | type) == "object" and ($json.content | type) == "array" and ($json | has("isError")) then
					# Tool already emitted CallToolResult - use it directly with metadata
					$json
					| .name = $name
					| ._meta = ({exitCode: $exit_code} + (if ($stderr | length > 0) then {stderr: $stderr} else {} end))
					| if $exit_code != 0 then .isError = true else . end
				else
					# Normal JSON output - wrap in CallToolResult
					$base
					| .content += [{type: "text", text: $stdout}]
					| .structuredContent = $json
				end
			) catch (
				$base | .content += [{type: "text", text: $stdout}]
			)
		else
			$base | .content += [{type: "text", text: $stdout}]
		end |

		# Add stderr if present (for non-CallToolResult outputs)
		if (._meta.stderr | length) == 0 and ($stderr | length > 0) then
			._meta.stderr = $stderr
		else . end |

		# Set isError if exit code non-zero (for non-CallToolResult outputs)
		if $exit_code != 0 then
			.isError = true
		else . end
		'
	)"

	local embedded_resources=""
	# Debug: write to persistent file (worker stderr is deleted on cleanup)
	local debug_file="${MCPBASH_STATE_DIR:-/tmp}/embed-debug.log"
	{
		printf '[DEBUG] tool_resources_file=%s\n' "${tool_resources_file}"
		printf '[DEBUG] file exists=%s size=%s\n' "$([ -f "${tool_resources_file}" ] && echo yes || echo no)" "$(wc -c <"${tool_resources_file}" 2>/dev/null || echo 0)"
	} >>"${debug_file}" 2>&1
	if [ -s "${tool_resources_file}" ]; then
		printf '[DEBUG] resources file content: %s\n' "$(cat "${tool_resources_file}" 2>/dev/null || echo "(read error)")" >>"${debug_file}" 2>&1
		# Temporarily removed 2>/dev/null for Windows path debugging
		embedded_resources="$(mcp_tools_collect_embedded_resources "${tool_resources_file}" || true)"
		printf '[DEBUG] embedded_resources result: %s\n' "${embedded_resources:-empty}" >>"${debug_file}" 2>&1
	else
		printf '[DEBUG] resources file empty or missing\n' >>"${debug_file}" 2>&1
	fi
	if [ -n "${embedded_resources}" ]; then
		result_json="$(
			printf '%s' "${result_json}" | "${MCPBASH_JSON_TOOL_BIN}" -c --argjson embeds "${embedded_resources}" '
				.content += ($embeds // [])
			'
		)" || result_json=""
	fi

	cleanup_tool_temp_files

	_MCP_TOOLS_RESULT="${result_json}"
}
