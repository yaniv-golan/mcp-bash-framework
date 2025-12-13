#!/usr/bin/env bash
# Registry refresh helpers (fast-path detection and locked writes).

set -euo pipefail

MCPBASH_REGISTRY_FASTPATH_FILE=""
MCPBASH_REGISTRY_MAX_LIMIT_DEFAULT=104857600
MCP_REGISTRY_REGISTER_SIGNATURE=""
MCP_REGISTRY_REGISTER_LAST_RUN=0
MCP_REGISTRY_REGISTER_COMPLETE=false
MCP_REGISTRY_REGISTER_STATUS_TOOLS=""
MCP_REGISTRY_REGISTER_STATUS_RESOURCES=""
MCP_REGISTRY_REGISTER_STATUS_RESOURCE_TEMPLATES=""
MCP_REGISTRY_REGISTER_STATUS_PROMPTS=""
MCP_REGISTRY_REGISTER_STATUS_COMPLETIONS=""
MCP_REGISTRY_REGISTER_ERROR_TOOLS=""
MCP_REGISTRY_REGISTER_ERROR_RESOURCES=""
MCP_REGISTRY_REGISTER_ERROR_RESOURCE_TEMPLATES=""
MCP_REGISTRY_REGISTER_ERROR_PROMPTS=""
MCP_REGISTRY_REGISTER_ERROR_COMPLETIONS=""

mcp_registry_resolve_scan_root() {
	local default_dir="$1"
	local scan_root="${default_dir}"
	local filter_path="${MCPBASH_REGISTRY_REFRESH_PATH:-}"

	if [ -n "${filter_path}" ]; then
		local candidate="${filter_path}"
		case "${candidate}" in
		/*) ;;
		*)
			candidate="${MCPBASH_PROJECT_ROOT%/}/${candidate}"
			;;
		esac
		if [ -d "${candidate}" ]; then
			# SECURITY: do not use glob/pattern matching for containment checks.
			# Paths may contain glob metacharacters like []?* which would turn a
			# prefix check into a wildcard match (e.g., default[1] matching default1).
			local base="${default_dir}"
			if [ "${base}" != "/" ]; then
				base="${base%/}"
			fi
			if [ "${candidate}" = "${base}" ]; then
				scan_root="${candidate}"
			elif [ "${base}" = "/" ]; then
				scan_root="${candidate}"
			else
				local prefix="${base}/"
				if [ "${candidate:0:${#prefix}}" = "${prefix}" ]; then
					scan_root="${candidate}"
				fi
			fi
		fi
	fi

	printf '%s' "${scan_root}"
}

mcp_registry_global_max_bytes() {
	local limit="${MCPBASH_REGISTRY_MAX_BYTES:-${MCPBASH_REGISTRY_MAX_LIMIT_DEFAULT}}"
	case "${limit}" in
	'' | *[!0-9]*) limit="${MCPBASH_REGISTRY_MAX_LIMIT_DEFAULT}" ;;
	esac
	printf '%s' "${limit}"
}

mcp_registry_check_size() {
	local json_payload="$1"
	local limit
	limit="$(mcp_registry_global_max_bytes)"
	local size
	size="$(LC_ALL=C printf '%s' "${json_payload}" | wc -c | tr -d ' ')"
	if [ "${size}" -gt "${limit}" ]; then
		printf '%s' "${limit}"
		return 1
	fi
	printf '%s' "${size}"
	return 0
}

mcp_registry_fastpath_file() {
	if [ -z "${MCPBASH_STATE_DIR:-}" ]; then
		return 1
	fi
	if [ -z "${MCPBASH_REGISTRY_FASTPATH_FILE}" ]; then
		MCPBASH_REGISTRY_FASTPATH_FILE="${MCPBASH_STATE_DIR}/registry.fastpath.json"
	fi
	printf '%s' "${MCPBASH_REGISTRY_FASTPATH_FILE}"
}

mcp_registry_stat_mtime() {
	local path="$1"
	if [ ! -e "${path}" ]; then
		printf '0'
		return 0
	fi
	if command -v stat >/dev/null 2>&1; then
		# Prefer GNU stat (-c) for portable numeric mtime; fall back to BSD (-f).
		if stat -c %Y "${path}" >/dev/null 2>&1; then
			stat -c %Y "${path}"
			return 0
		fi
		if stat -f %m "${path}" >/dev/null 2>&1; then
			stat -f %m "${path}"
			return 0
		fi
	fi
	printf '0'
}

mcp_registry_fastpath_snapshot() {
	local root="$1"
	local scan_root="${root}"
	if [ ! -d "${scan_root}" ]; then
		printf '0|0|0'
		return 0
	fi
	local count=0 hash mtime manifest=""
	while IFS= read -r path; do
		[ -z "${path}" ] && continue
		count=$((count + 1))
		local file_mtime
		file_mtime="$(mcp_registry_stat_mtime "${path}")"
		# Use relative path to avoid absolute prefixes in hash
		local rel_path="${path#"${scan_root}/"}"
		manifest="${manifest}${file_mtime}|${rel_path}\n"
	done < <(find "${scan_root}" -type f ! -name ".*" 2>/dev/null | LC_ALL=C sort)
	hash="$(mcp_hash_string "${manifest}")"
	mtime="$(mcp_registry_stat_mtime "${scan_root}")"
	printf '%s|%s|%s' "${count:-0}" "${hash:-0}" "${mtime:-0}"
}

mcp_registry_fastpath_unchanged() {
	local kind="$1"
	local snapshot="$2"
	if [ "${MCPBASH_JSON_TOOL:-}" = "none" ] || [ -z "${MCPBASH_JSON_TOOL_BIN:-}" ]; then
		return 1
	fi
	local file
	if ! file="$(mcp_registry_fastpath_file)"; then
		return 1
	fi
	if [ ! -f "${file}" ]; then
		return 1
	fi
	local count hash mtime
	IFS='|' read -r count hash mtime <<<"${snapshot}"
	if [ -z "${count}" ] || [ -z "${hash}" ] || [ -z "${mtime}" ]; then
		return 1
	fi
	local prev_count prev_hash prev_mtime
	prev_count="$("${MCPBASH_JSON_TOOL_BIN}" -r --arg kind "${kind}" '.[$kind].count // empty' "${file}" 2>/dev/null || true)"
	prev_hash="$("${MCPBASH_JSON_TOOL_BIN}" -r --arg kind "${kind}" '.[$kind].hash // empty' "${file}" 2>/dev/null || true)"
	prev_mtime="$("${MCPBASH_JSON_TOOL_BIN}" -r --arg kind "${kind}" '.[$kind].mtime // empty' "${file}" 2>/dev/null || true)"
	if [ -n "${prev_count}" ] && [ -n "${prev_hash}" ] && [ -n "${prev_mtime}" ] && [ "${prev_count}" = "${count}" ] && [ "${prev_hash}" = "${hash}" ] && [ "${prev_mtime}" = "${mtime}" ]; then
		return 0
	fi
	return 1
}

mcp_registry_fastpath_store() {
	local kind="$1"
	local snapshot="$2"
	if [ "${MCPBASH_JSON_TOOL:-}" = "none" ] || [ -z "${MCPBASH_JSON_TOOL_BIN:-}" ]; then
		return 0
	fi
	local file
	if ! file="$(mcp_registry_fastpath_file)"; then
		return 0
	fi
	local count hash mtime
	IFS='|' read -r count hash mtime <<<"${snapshot}"
	[ -n "${count}" ] || count="0"
	[ -n "${hash}" ] || hash="0"
	[ -n "${mtime}" ] || mtime="0"
	local existing="{}"
	if [ -f "${file}" ]; then
		existing="$(cat "${file}")"
	fi
	local tmp
	tmp="$(mktemp "${MCPBASH_TMP_ROOT}/mcp-registry-fastpath.XXXXXX")"
	printf '%s' "${existing}" | "${MCPBASH_JSON_TOOL_BIN}" -c --arg kind "${kind}" --argjson count "${count}" --arg hash "${hash}" --argjson mtime "${mtime}" '
		.[$kind] = {count: $count, hash: $hash, mtime: $mtime}
	' >"${tmp}"
	mv "${tmp}" "${file}"
}

mcp_registry_write_with_lock() {
	local path="$1"
	local json_payload="$2"
	local lock_name="${3:-registry.refresh}"
	local timeout="${4:-5}"

	if [ "${MCPBASH_REGISTRY_REFRESH_NO_WRITE:-false}" = "true" ]; then
		return 0
	fi

	if ! mcp_lock_acquire_timeout "${lock_name}" "${timeout}"; then
		printf '%s\n' "mcp-bash: registry lock '${lock_name}' unavailable after ${timeout}s" >&2
		return 2
	fi
	printf '%s' "${json_payload}" >"${path}"
	mcp_lock_release "${lock_name}"
	return 0
}

mcp_registry_register_filesize() {
	local path="$1"
	if [ ! -f "${path}" ]; then
		printf '0'
		return 0
	fi
	wc -c <"${path}" 2>/dev/null | tr -d ' '
}

mcp_registry_register_ttl() {
	local ttl="${MCPBASH_REGISTER_TTL:-5}"
	case "${ttl}" in
	'' | *[!0-9]*) ttl=5 ;;
	0) ttl=5 ;;
	esac
	printf '%s' "${ttl}"
}

mcp_registry_register_signature() {
	local path="$1"
	# Signature used to ensure the script we execute is exactly the one we checked.
	#
	# IMPORTANT: this must be stable across copies (we copy register.sh into a temp
	# file before sourcing it). Using path/mtime would spuriously fail even when
	# contents are identical, because the temp file has a different path and mtime.
	#
	# A content hash is simple, fast for small scripts, and portable (falls back to
	# cksum when sha256 tooling is unavailable).
	if command -v sha256sum >/dev/null 2>&1; then
		sha256sum "${path}" 2>/dev/null | awk '{print $1}'
		return 0
	fi
	if command -v shasum >/dev/null 2>&1; then
		shasum -a 256 "${path}" 2>/dev/null | awk '{print $1}'
		return 0
	fi
	cksum "${path}" 2>/dev/null | awk '{print $1}'
}

mcp_registry_register_reset_state() {
	MCP_REGISTRY_REGISTER_COMPLETE=false
	MCP_REGISTRY_REGISTER_STATUS_TOOLS=""
	MCP_REGISTRY_REGISTER_STATUS_RESOURCES=""
	MCP_REGISTRY_REGISTER_STATUS_RESOURCE_TEMPLATES=""
	MCP_REGISTRY_REGISTER_STATUS_PROMPTS=""
	MCP_REGISTRY_REGISTER_STATUS_COMPLETIONS=""
	MCP_REGISTRY_REGISTER_ERROR_TOOLS=""
	MCP_REGISTRY_REGISTER_ERROR_RESOURCES=""
	MCP_REGISTRY_REGISTER_ERROR_RESOURCE_TEMPLATES=""
	MCP_REGISTRY_REGISTER_ERROR_PROMPTS=""
	MCP_REGISTRY_REGISTER_ERROR_COMPLETIONS=""
}

mcp_registry_register_hooks_allowed() {
	case "${MCPBASH_ALLOW_PROJECT_HOOKS:-false}" in
	true | 1 | yes | on) return 0 ;;
	esac
	return 1
}

mcp_registry_register_warn_untrusted() {
	if [ "${MCPBASH_REGISTER_HOOK_WARNED:-false}" = "true" ]; then
		return 0
	fi
	MCPBASH_REGISTER_HOOK_WARNED="true"
	if mcp_logging_is_enabled "warning"; then
		mcp_logging_warning "mcp.registry" "Project hook execution enabled (MCPBASH_ALLOW_PROJECT_HOOKS=true); ensure server.d/register.sh is trusted."
	fi
	return 0
}

mcp_registry_register_stat_perm_mask() {
	local path="$1"
	local perm_mask=""
	if command -v perl >/dev/null 2>&1; then
		perm_mask="$(perl -e 'printf "%o\n", (stat($ARGV[0]))[2] & 0777' "${path}" 2>/dev/null || true)"
	fi
	if [ -z "${perm_mask}" ] && command -v stat >/dev/null 2>&1; then
		perm_mask="$(stat -c '%a' "${path}" 2>/dev/null || true)"
		if [ -z "${perm_mask}" ]; then
			perm_mask="$(stat -f '%Lp' "${path}" 2>/dev/null || true)"
		fi
	fi
	[ -n "${perm_mask}" ] || return 1
	printf '%s' "${perm_mask}"
}

mcp_registry_register_stat_uid_gid() {
	local path="$1"
	local uid_gid=""
	if command -v perl >/dev/null 2>&1; then
		uid_gid="$(perl -e 'printf "%d:%d\n", (stat($ARGV[0]))[4,5]' "${path}" 2>/dev/null || true)"
	fi
	if [ -z "${uid_gid}" ] && command -v stat >/dev/null 2>&1; then
		uid_gid="$(stat -c '%u:%g' "${path}" 2>/dev/null || true)"
		if [ -z "${uid_gid}" ]; then
			uid_gid="$(stat -f '%u:%g' "${path}" 2>/dev/null || true)"
		fi
	fi
	[ -n "${uid_gid}" ] || return 1
	printf '%s' "${uid_gid}"
}

mcp_registry_register_check_secure_path() {
	local target="$1"
	if [ -z "${target}" ]; then
		return 1
	fi
	if [ -L "${target}" ]; then
		return 1
	fi
	local perm_mask perm_bits
	if ! perm_mask="$(mcp_registry_register_stat_perm_mask "${target}")"; then
		return 1
	fi
	perm_bits=$((8#${perm_mask}))
	if [ $((perm_bits & 0020)) -ne 0 ] || [ $((perm_bits & 0002)) -ne 0 ]; then
		return 1
	fi
	local uid_gid cur_uid cur_gid
	if ! uid_gid="$(mcp_registry_register_stat_uid_gid "${target}")"; then
		return 1
	fi
	cur_uid="$(id -u 2>/dev/null || printf '0')"
	cur_gid="$(id -g 2>/dev/null || printf '0')"
	case "${uid_gid}" in
	"${cur_uid}:${cur_gid}" | "${cur_uid}:"*) return 0 ;;
	esac
	return 1
}

mcp_registry_register_check_permissions() {
	local script_path="$1"
	if [ ! -f "${script_path}" ]; then
		return 1
	fi
	# Defense-in-depth: never source symlink hooks, and require that the script
	# and its parent dirs are not group/world writable and are owned by the user.
	if [ -L "${script_path}" ]; then
		return 1
	fi
	if ! mcp_registry_register_check_secure_path "${script_path}"; then
		return 1
	fi
	local script_dir
	script_dir="$(dirname "${script_path}")"
	if [ -n "${script_dir}" ] && [ -d "${script_dir}" ]; then
		if ! mcp_registry_register_check_secure_path "${script_dir}"; then
			return 1
		fi
	fi
	if [ -n "${MCPBASH_PROJECT_ROOT:-}" ] && [ -d "${MCPBASH_PROJECT_ROOT}" ]; then
		if ! mcp_registry_register_check_secure_path "${MCPBASH_PROJECT_ROOT}"; then
			return 1
		fi
	fi
	return 0
}

mcp_registry_register_set_status() {
	local kind="$1"
	local status="$2"
	local message="$3"
	case "${kind}" in
	tools)
		MCP_REGISTRY_REGISTER_STATUS_TOOLS="${status}"
		MCP_REGISTRY_REGISTER_ERROR_TOOLS="${message}"
		;;
	resources)
		MCP_REGISTRY_REGISTER_STATUS_RESOURCES="${status}"
		MCP_REGISTRY_REGISTER_ERROR_RESOURCES="${message}"
		;;
	resourceTemplates)
		MCP_REGISTRY_REGISTER_STATUS_RESOURCE_TEMPLATES="${status}"
		MCP_REGISTRY_REGISTER_ERROR_RESOURCE_TEMPLATES="${message}"
		;;
	prompts)
		MCP_REGISTRY_REGISTER_STATUS_PROMPTS="${status}"
		MCP_REGISTRY_REGISTER_ERROR_PROMPTS="${message}"
		;;
	completions)
		MCP_REGISTRY_REGISTER_STATUS_COMPLETIONS="${status}"
		MCP_REGISTRY_REGISTER_ERROR_COMPLETIONS="${message}"
		;;
	esac
}

mcp_registry_register_error_for_kind() {
	local kind="$1"
	case "${kind}" in
	tools) printf '%s' "${MCP_REGISTRY_REGISTER_ERROR_TOOLS}" ;;
	resources) printf '%s' "${MCP_REGISTRY_REGISTER_ERROR_RESOURCES}" ;;
	resourceTemplates) printf '%s' "${MCP_REGISTRY_REGISTER_ERROR_RESOURCE_TEMPLATES}" ;;
	prompts) printf '%s' "${MCP_REGISTRY_REGISTER_ERROR_PROMPTS}" ;;
	completions) printf '%s' "${MCP_REGISTRY_REGISTER_ERROR_COMPLETIONS}" ;;
	*) printf '' ;;
	esac
}

mcp_registry_register_abort_all() {
	mcp_tools_manual_abort 2>/dev/null || true
	mcp_resources_manual_abort 2>/dev/null || true
	mcp_resources_templates_manual_abort 2>/dev/null || true
	mcp_prompts_manual_abort 2>/dev/null || true
	mcp_completion_manual_abort 2>/dev/null || true
}

mcp_registry_register_finalize_kind() {
	local kind="$1"
	local script_output="$2"
	case "${kind}" in
	tools)
		if [ "${MCP_TOOLS_MANUAL_ACTIVE}" = "true" ]; then
			if [ -z "${MCP_TOOLS_MANUAL_BUFFER}" ] && [ -n "${script_output}" ]; then
				mcp_tools_manual_abort
				if mcp_tools_apply_manual_json "${script_output}"; then
					mcp_registry_register_set_status "tools" "ok" ""
				else
					mcp_registry_register_set_status "tools" "error" "Manual tools registration parsing failed"
				fi
				return 0
			fi
			if [ -z "${MCP_TOOLS_MANUAL_BUFFER}" ] && [ -z "${script_output}" ]; then
				mcp_tools_manual_abort
				mcp_registry_register_set_status "tools" "skipped" ""
				return 0
			fi
			if [ -n "${script_output}" ]; then
				if mcp_logging_verbose_enabled; then
					mcp_logging_warning "${MCP_TOOLS_LOGGER}" "Manual registration script output: ${script_output}"
				else
					mcp_logging_warning "${MCP_TOOLS_LOGGER}" "Manual registration script produced output (enable MCPBASH_LOG_VERBOSE=true to view)"
				fi
			fi
			if mcp_tools_manual_finalize; then
				mcp_registry_register_set_status "tools" "ok" ""
			else
				mcp_registry_register_set_status "tools" "error" "Manual tools registration finalize failed"
			fi
		else
			mcp_registry_register_set_status "tools" "skipped" ""
		fi
		;;
	resources)
		if [ "${MCP_RESOURCES_MANUAL_ACTIVE}" = "true" ]; then
			if [ -z "${MCP_RESOURCES_MANUAL_BUFFER}" ] && [ -n "${script_output}" ]; then
				mcp_resources_manual_abort
				if mcp_resources_apply_manual_json "${script_output}"; then
					mcp_registry_register_set_status "resources" "ok" ""
				else
					mcp_registry_register_set_status "resources" "error" "Manual resources registration parsing failed"
				fi
				return 0
			fi
			if [ -z "${MCP_RESOURCES_MANUAL_BUFFER}" ] && [ -z "${script_output}" ]; then
				mcp_resources_manual_abort
				mcp_registry_register_set_status "resources" "skipped" ""
				return 0
			fi
			if [ -n "${script_output}" ]; then
				if mcp_logging_verbose_enabled; then
					mcp_logging_warning "${MCP_RESOURCES_LOGGER}" "Manual registration script output: ${script_output}"
				else
					mcp_logging_warning "${MCP_RESOURCES_LOGGER}" "Manual registration script produced output (enable MCPBASH_LOG_VERBOSE=true to view)"
				fi
			fi
			if mcp_resources_manual_finalize; then
				mcp_registry_register_set_status "resources" "ok" ""
			else
				mcp_registry_register_set_status "resources" "error" "Manual resources registration finalize failed"
			fi
		else
			mcp_registry_register_set_status "resources" "skipped" ""
		fi
		;;
	resourceTemplates)
		if [ "${MCP_RESOURCES_TEMPLATES_MANUAL_ACTIVE}" = "true" ]; then
			if [ -z "${MCP_RESOURCES_TEMPLATES_MANUAL_BUFFER}" ] && [ -n "${script_output}" ]; then
				mcp_resources_templates_manual_abort
				if mcp_resources_templates_apply_manual_json "${script_output}"; then
					mcp_registry_register_set_status "resourceTemplates" "ok" ""
				else
					mcp_registry_register_set_status "resourceTemplates" "error" "Manual resourceTemplates registration parsing failed"
				fi
				return 0
			fi
			if [ -z "${MCP_RESOURCES_TEMPLATES_MANUAL_BUFFER}" ] && [ -z "${script_output}" ]; then
				mcp_resources_templates_manual_abort
				mcp_registry_register_set_status "resourceTemplates" "skipped" ""
				return 0
			fi
			if [ -n "${script_output}" ]; then
				if mcp_logging_verbose_enabled; then
					mcp_logging_warning "${MCP_RESOURCES_TEMPLATES_LOGGER}" "Manual registration script output: ${script_output}"
				else
					mcp_logging_warning "${MCP_RESOURCES_TEMPLATES_LOGGER}" "Manual registration script produced output (enable MCPBASH_LOG_VERBOSE=true to view)"
				fi
			fi
			if mcp_resources_templates_manual_finalize; then
				mcp_registry_register_set_status "resourceTemplates" "ok" ""
			else
				mcp_registry_register_set_status "resourceTemplates" "error" "Manual resourceTemplates registration finalize failed"
			fi
		else
			mcp_registry_register_set_status "resourceTemplates" "skipped" ""
		fi
		;;
	prompts)
		if [ "${MCP_PROMPTS_MANUAL_ACTIVE}" = "true" ]; then
			if [ -z "${MCP_PROMPTS_MANUAL_BUFFER}" ] && [ -n "${script_output}" ]; then
				mcp_prompts_manual_abort
				if mcp_prompts_apply_manual_json "${script_output}"; then
					mcp_registry_register_set_status "prompts" "ok" ""
				else
					mcp_registry_register_set_status "prompts" "error" "Manual prompts registration parsing failed"
				fi
				return 0
			fi
			if [ -z "${MCP_PROMPTS_MANUAL_BUFFER}" ] && [ -z "${script_output}" ]; then
				mcp_prompts_manual_abort
				mcp_registry_register_set_status "prompts" "skipped" ""
				return 0
			fi
			if [ -n "${script_output}" ]; then
				if mcp_logging_verbose_enabled; then
					mcp_logging_warning "${MCP_PROMPTS_LOGGER}" "Manual registration script output: ${script_output}"
				else
					mcp_logging_warning "${MCP_PROMPTS_LOGGER}" "Manual registration script produced output (enable MCPBASH_LOG_VERBOSE=true to view)"
				fi
			fi
			if mcp_prompts_manual_finalize; then
				mcp_registry_register_set_status "prompts" "ok" ""
			else
				mcp_registry_register_set_status "prompts" "error" "Manual prompts registration finalize failed"
			fi
		else
			mcp_registry_register_set_status "prompts" "skipped" ""
		fi
		;;
	completions)
		if [ "${MCP_COMPLETION_MANUAL_ACTIVE}" = "true" ]; then
			if [ -z "${MCP_COMPLETION_MANUAL_BUFFER}" ] && [ -n "${script_output}" ]; then
				mcp_completion_manual_abort
				# shellcheck disable=SC2034  # consumed by completion refresh path in lib/completion.sh
				if mcp_completion_apply_manual_json "${script_output}"; then
					MCP_COMPLETION_MANUAL_LOADED=true
					mcp_registry_register_set_status "completions" "ok" ""
				else
					mcp_registry_register_set_status "completions" "error" "Manual completion registration parsing failed"
				fi
				return 0
			fi
			if [ -z "${MCP_COMPLETION_MANUAL_BUFFER}" ] && [ -z "${script_output}" ]; then
				mcp_completion_manual_abort
				mcp_registry_register_set_status "completions" "skipped" ""
				return 0
			fi
			if [ -n "${script_output}" ]; then
				if mcp_logging_verbose_enabled; then
					mcp_logging_warning "${MCP_COMPLETION_LOGGER}" "Manual completion script output: ${script_output}"
				else
					mcp_logging_warning "${MCP_COMPLETION_LOGGER}" "Manual completion script produced output (enable MCPBASH_LOG_VERBOSE=true to view)"
				fi
			fi
			# shellcheck disable=SC2034  # consumed by completion refresh path in lib/completion.sh
			if mcp_completion_manual_finalize; then
				MCP_COMPLETION_MANUAL_LOADED=true
				mcp_registry_register_set_status "completions" "ok" ""
			else
				mcp_registry_register_set_status "completions" "error" "Manual completion registration finalize failed"
			fi
		else
			mcp_registry_register_set_status "completions" "skipped" ""
		fi
		;;
	esac
}

mcp_registry_register_execute() {
	local script_path="$1"
	local signature="$2"

	if ! mcp_registry_register_hooks_allowed; then
		mcp_registry_register_set_status "tools" "skipped" ""
		mcp_registry_register_set_status "resources" "skipped" ""
		mcp_registry_register_set_status "resourceTemplates" "skipped" ""
		mcp_registry_register_set_status "prompts" "skipped" ""
		mcp_registry_register_set_status "completions" "skipped" ""
		MCP_REGISTRY_REGISTER_COMPLETE=true
		return 0
	fi

	if ! mcp_registry_register_check_permissions "${script_path}"; then
		mcp_registry_register_set_status "tools" "error" "Manual registration script permissions/ownership invalid"
		mcp_registry_register_set_status "resources" "error" "Manual registration script permissions/ownership invalid"
		mcp_registry_register_set_status "resourceTemplates" "error" "Manual registration script permissions/ownership invalid"
		mcp_registry_register_set_status "prompts" "error" "Manual registration script permissions/ownership invalid"
		mcp_registry_register_set_status "completions" "error" "Manual registration script permissions/ownership invalid"
		MCP_REGISTRY_REGISTER_COMPLETE=true
		return 0
	fi

	mcp_registry_register_warn_untrusted

	mcp_registry_register_reset_state
	MCP_REGISTRY_REGISTER_SIGNATURE="${signature}"
	MCP_REGISTRY_REGISTER_LAST_RUN="$(date +%s)"

	# Ensure registry paths/dirs are initialized before manual registration writes.
	mcp_tools_init
	mcp_resources_init
	mcp_resources_templates_init
	mcp_prompts_init

	mcp_tools_manual_begin
	mcp_resources_manual_begin
	mcp_resources_templates_manual_begin
	mcp_prompts_manual_begin
	mcp_completion_manual_begin

	local script_output_file
	script_output_file="$(mktemp "${MCPBASH_TMP_ROOT}/mcp-register-output.XXXXXX")"
	local tmp_script
	tmp_script="$(mktemp "${MCPBASH_TMP_ROOT}/mcp-register-script.XXXXXX")"
	local script_status=0

	# Execute in the current shell so manual registration buffers are retained.
	set +e
	# shellcheck disable=SC1090
	# shellcheck disable=SC1091
	if exec 3<"${script_path}"; then
		cat <&3 >"${tmp_script}" 2>/dev/null
		script_status=$?
		exec 3<&-
	else
		script_status=1
	fi
	if [ "${script_status}" -ne 0 ]; then
		printf '%s\n' "Failed to open/copy manual registration script; refusing to run." >"${script_output_file}"
	fi
	if [ "${script_status}" -eq 0 ]; then
		chmod 600 "${tmp_script}" 2>/dev/null || true
		local tmp_sig=""
		tmp_sig="$(mcp_registry_register_signature "${tmp_script}" 2>/dev/null || true)"
		if [ -z "${tmp_sig}" ] || [ "${tmp_sig}" != "${signature}" ]; then
			script_status=1
			printf '%s\n' "Manual registration script changed during execution; refusing to run." >"${script_output_file}"
		else
			# shellcheck disable=SC1090
			. "${tmp_script}" >"${script_output_file}" 2>&1
			script_status=$?
		fi
	fi
	set -e
	rm -f "${tmp_script}" 2>/dev/null || true

	local script_output
	script_output="$(cat "${script_output_file}" 2>/dev/null || true)"
	local script_size
	script_size="$(wc -c <"${script_output_file}" | tr -d ' ')"
	rm -f "${script_output_file}"

	local manual_limit="${MCPBASH_MAX_MANUAL_REGISTRY_BYTES:-1048576}"
	case "${manual_limit}" in
	'' | *[!0-9]*) manual_limit=1048576 ;;
	0) manual_limit=1048576 ;;
	esac

	if [ "${script_size:-0}" -gt "${manual_limit}" ]; then
		mcp_registry_register_set_status "tools" "error" "Manual registration output exceeded ${manual_limit} bytes"
		mcp_registry_register_set_status "resources" "error" "Manual registration output exceeded ${manual_limit} bytes"
		mcp_registry_register_set_status "prompts" "error" "Manual registration output exceeded ${manual_limit} bytes"
		mcp_registry_register_set_status "completions" "error" "Manual registration output exceeded ${manual_limit} bytes"
		mcp_registry_register_abort_all
		MCP_REGISTRY_REGISTER_COMPLETE=true
		return 0
	fi

	if [ "${script_status}" -ne 0 ]; then
		local message="Manual registration script failed"
		if [ "${script_status}" -eq 124 ]; then
			message="Manual registration script timed out"
		fi
		mcp_registry_register_set_status "tools" "error" "${message}"
		mcp_registry_register_set_status "resources" "error" "${message}"
		mcp_registry_register_set_status "prompts" "error" "${message}"
		mcp_registry_register_set_status "completions" "error" "${message}"
		if [ -n "${script_output}" ]; then
			if mcp_logging_verbose_enabled; then
				mcp_logging_error "mcp.registry" "Manual registration script output: ${script_output}"
			else
				mcp_logging_error "mcp.registry" "Manual registration script failed (enable MCPBASH_LOG_VERBOSE=true for details)"
			fi
		fi
		mcp_registry_register_abort_all
		MCP_REGISTRY_REGISTER_COMPLETE=true
		return 0
	fi

	mcp_registry_register_finalize_kind "tools" "${script_output}"
	mcp_registry_register_finalize_kind "resources" "${script_output}"
	mcp_registry_register_finalize_kind "resourceTemplates" "${script_output}"
	mcp_registry_register_finalize_kind "prompts" "${script_output}"
	mcp_registry_register_finalize_kind "completions" "${script_output}"
	MCP_REGISTRY_REGISTER_COMPLETE=true
}

mcp_registry_register_apply() {
	local kind="$1"
	local script_path="${MCPBASH_SERVER_DIR}/register.sh"
	# Expose last outcome for callers that need to distinguish "applied" vs
	# "skipped" while still treating skipped as a non-error state.
	# shellcheck disable=SC2034
	MCP_REGISTRY_REGISTER_LAST_KIND="${kind}"
	# shellcheck disable=SC2034
	MCP_REGISTRY_REGISTER_LAST_STATUS=""
	# shellcheck disable=SC2034
	MCP_REGISTRY_REGISTER_LAST_APPLIED=false
	# On Windows (Git Bash/MSYS), -x test is unreliable. Check for shebang as fallback.
	if [ ! -x "${script_path}" ]; then
		if ! head -n1 "${script_path}" 2>/dev/null | grep -q '^#!'; then
			return 1
		fi
	fi

	local signature
	signature="$(mcp_registry_register_signature "${script_path}")"

	local now ttl
	now="$(date +%s)"
	ttl="$(mcp_registry_register_ttl)"

	if [ "${MCP_REGISTRY_REGISTER_COMPLETE}" = true ]; then
		if [ "${signature}" != "${MCP_REGISTRY_REGISTER_SIGNATURE}" ] || [ $((now - MCP_REGISTRY_REGISTER_LAST_RUN)) -ge "${ttl}" ]; then
			mcp_registry_register_reset_state
		fi
	fi

	if [ "${MCP_REGISTRY_REGISTER_COMPLETE}" != true ]; then
		mcp_registry_register_execute "${script_path}" "${signature}"
	fi

	local status=""
	case "${kind}" in
	tools) status="${MCP_REGISTRY_REGISTER_STATUS_TOOLS}" ;;
	resources) status="${MCP_REGISTRY_REGISTER_STATUS_RESOURCES}" ;;
	resourceTemplates) status="${MCP_REGISTRY_REGISTER_STATUS_RESOURCE_TEMPLATES}" ;;
	prompts) status="${MCP_REGISTRY_REGISTER_STATUS_PROMPTS}" ;;
	completions) status="${MCP_REGISTRY_REGISTER_STATUS_COMPLETIONS}" ;;
	esac
	# shellcheck disable=SC2034  # used across modules by callers of mcp_registry_register_apply
	MCP_REGISTRY_REGISTER_LAST_STATUS="${status}"

	case "${status}" in
	ok)
		# shellcheck disable=SC2034  # used across modules by callers of mcp_registry_register_apply
		MCP_REGISTRY_REGISTER_LAST_APPLIED=true
		return 0
		;;
	skipped)
		# "skipped" is a normal state (e.g., hooks disabled or no registrations for
		# this kind). Callers can check MCP_REGISTRY_REGISTER_LAST_APPLIED.
		return 0
		;;
	error)
		return 2
		;;
	esac

	return 1
}
