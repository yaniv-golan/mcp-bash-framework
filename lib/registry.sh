#!/usr/bin/env bash
# Registry refresh helpers (fast-path detection and locked writes).

set -euo pipefail

MCPBASH_REGISTRY_FASTPATH_FILE=""
MCPBASH_REGISTRY_MAX_LIMIT_DEFAULT=104857600
MCP_REGISTRY_DECLARATIVE_SIGNATURE=""
MCP_REGISTRY_DECLARATIVE_LAST_RUN=0
MCP_REGISTRY_DECLARATIVE_COMPLETE=false
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
	local count=0 hash mtime
	local tmp_manifest tmp_sorted
	tmp_manifest="$(mktemp "${MCPBASH_TMP_ROOT}/mcp-registry-fastpath.manifest.XXXXXX")"
	tmp_sorted="$(mktemp "${MCPBASH_TMP_ROOT}/mcp-registry-fastpath.sorted.XXXXXX")"
	if [ -z "${tmp_manifest}" ] || [ -z "${tmp_sorted}" ]; then
		printf '0|0|0'
		return 0
	fi

	while IFS= read -r -d '' path; do
		case "${path}" in
		*$'\n'* | *$'\r'*)
			# Filenames containing newlines/CR are unsupported; disable fastpath so
			# callers fall back to full scans rather than building a corrupt hash.
			rm -f "${tmp_manifest}" "${tmp_sorted}" 2>/dev/null || true
			printf '0|0|0'
			return 0
			;;
		esac
		[ -n "${path}" ] || continue
		count=$((count + 1))
		local file_mtime
		file_mtime="$(mcp_registry_stat_mtime "${path}")"
		# Use relative path to avoid absolute prefixes in hash
		local rel_path="${path#"${scan_root}/"}"
		printf '%s|%s\n' "${file_mtime}" "${rel_path}" >>"${tmp_manifest}"
	done < <(find "${scan_root}" -type f ! -name ".*" -print0 2>/dev/null)

	LC_ALL=C sort "${tmp_manifest}" >"${tmp_sorted}" 2>/dev/null || true
	local manifest=""
	manifest="$(cat "${tmp_sorted}" 2>/dev/null || true)"
	rm -f "${tmp_manifest}" "${tmp_sorted}" 2>/dev/null || true

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
	if command -v stat >/dev/null 2>&1; then
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
	if command -v stat >/dev/null 2>&1; then
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

mcp_registry_declarative_path() {
	printf '%s' "${MCPBASH_SERVER_DIR}/register.json"
}

mcp_registry_declarative_reset_state() {
	MCP_REGISTRY_DECLARATIVE_COMPLETE=false
}

mcp_registry_declarative_set_error_all() {
	local message="$1"
	mcp_registry_register_set_status "tools" "error" "${message}"
	mcp_registry_register_set_status "resources" "error" "${message}"
	mcp_registry_register_set_status "resourceTemplates" "error" "${message}"
	mcp_registry_register_set_status "prompts" "error" "${message}"
	mcp_registry_register_set_status "completions" "error" "${message}"
	MCP_REGISTRY_DECLARATIVE_COMPLETE=true
}

mcp_registry_declarative_check_bom() {
	local path="$1"
	# jq/gojq typically reject BOM-prefixed JSON; provide a clearer error.
	local prefix=""
	prefix="$(dd if="${path}" bs=3 count=1 2>/dev/null || printf '')"
	if [ "${prefix}" = $'\xEF\xBB\xBF' ]; then
		return 1
	fi
	return 0
}

mcp_registry_declarative_validate_and_normalize() {
	local raw_json="$1"
	local bin="${MCPBASH_JSON_TOOL_BIN}"
	local normalized
	if ! normalized="$(printf '%s' "${raw_json}" | "${bin}" -c '
		def infer_provider:
			(.uri // "") as $u
			| if ($u|contains("://")) then ($u|split("://")[0]) else "" end
			| if . == "" then "file"
			  elif . == "git+https" then "git"
			  else . end;
		. as $root
		| if type != "object" then error("register.json must be a JSON object") else . end
		| if (.version | type) != "number" then error("register.json version must be a number") else . end
		| if (.version != 1) then error("register.json version must be 1") else . end
		| ((keys - ["version","tools","resources","resourceTemplates","prompts","completions","_meta"]) as $extra
			| if ($extra|length) > 0 then error("register.json unknown keys: " + ($extra|join(","))) else . end)
		| if (has("_meta") and (._meta != null) and ((._meta|type) != "object")) then error("register.json _meta must be an object") else . end
		| if (has("tools") and (.tools != null) and ((.tools|type) != "array")) then error("register.json tools must be an array or null") else . end
		| if (has("resources") and (.resources != null) and ((.resources|type) != "array")) then error("register.json resources must be an array or null") else . end
		| if (has("resourceTemplates") and (.resourceTemplates != null) and ((.resourceTemplates|type) != "array")) then error("register.json resourceTemplates must be an array or null") else . end
		| if (has("prompts") and (.prompts != null) and ((.prompts|type) != "array")) then error("register.json prompts must be an array or null") else . end
		| if (has("completions") and (.completions != null) and ((.completions|type) != "array")) then error("register.json completions must be an array or null") else . end
		| {version: 1}
		  + (if has("_meta") and ._meta != null then {_meta: ._meta} else {} end)
		  + (if has("tools") and .tools != null then {tools: .tools} else {} end)
		  + (if has("resources") and .resources != null then {resources: (.resources | map(if (.provider // "") == "" then . + {provider: infer_provider} else . end))} else {} end)
		  + (if has("resourceTemplates") and .resourceTemplates != null then {resourceTemplates: .resourceTemplates} else {} end)
		  + (if has("prompts") and .prompts != null then {prompts: .prompts} else {} end)
		  + (if has("completions") and .completions != null then {completions: .completions} else {} end)
	' 2>/dev/null)"; then
		return 1
	fi
	printf '%s' "${normalized}"
}

mcp_registry_declarative_execute() {
	local json_path="$1"
	local signature="$2"

	if [ "${MCPBASH_JSON_TOOL:-none}" = "none" ] || [ -z "${MCPBASH_JSON_TOOL_BIN:-}" ]; then
		mcp_registry_declarative_set_error_all "Declarative register.json requires jq/gojq (JSON tooling unavailable)"
		return 0
	fi

	if ! mcp_registry_register_check_permissions "${json_path}"; then
		mcp_registry_declarative_set_error_all "Declarative register.json permissions/ownership invalid"
		return 0
	fi

	local size
	size="$(mcp_registry_register_filesize "${json_path}")"
	local manual_limit="${MCPBASH_MAX_MANUAL_REGISTRY_BYTES:-1048576}"
	case "${manual_limit}" in
	'' | *[!0-9]*) manual_limit=1048576 ;;
	0) manual_limit=1048576 ;;
	esac
	if [ "${size:-0}" -gt "${manual_limit}" ]; then
		mcp_registry_declarative_set_error_all "Declarative register.json exceeded ${manual_limit} bytes"
		return 0
	fi

	if ! mcp_registry_declarative_check_bom "${json_path}"; then
		mcp_registry_declarative_set_error_all "Declarative register.json has a UTF-8 BOM; save as UTF-8 without BOM"
		return 0
	fi

	local raw_json=""
	if ! raw_json="$(cat "${json_path}" 2>/dev/null)"; then
		mcp_registry_declarative_set_error_all "Unable to read declarative register.json"
		return 0
	fi

	local normalized=""
	if ! normalized="$(mcp_registry_declarative_validate_and_normalize "${raw_json}")"; then
		# mcp_registry_declarative_validate_and_normalize is quiet; re-run to capture error details.
		local details=""
		details="$(printf '%s' "${raw_json}" | "${MCPBASH_JSON_TOOL_BIN}" -c '.' 2>&1 || true)"
		if mcp_logging_verbose_enabled; then
			mcp_registry_declarative_set_error_all "Declarative register.json parsing/validation failed: ${details}"
		else
			mcp_registry_declarative_set_error_all "Declarative register.json parsing/validation failed (enable MCPBASH_LOG_VERBOSE=true for details)"
		fi
		return 0
	fi

	mcp_registry_register_reset_state
	MCP_REGISTRY_DECLARATIVE_SIGNATURE="${signature}"
	MCP_REGISTRY_DECLARATIVE_LAST_RUN="$(date +%s)"

	# Extract present kinds as minimal objects. Missing/null keys are absent and should fall through to discovery.
	local tools_json resources_json templates_json prompts_json completions_json
	tools_json="$(printf '%s' "${normalized}" | "${MCPBASH_JSON_TOOL_BIN}" -c 'if has("tools") then {tools: .tools} else empty end' 2>/dev/null || printf '')"
	resources_json="$(printf '%s' "${normalized}" | "${MCPBASH_JSON_TOOL_BIN}" -c 'if has("resources") then {resources: .resources} else empty end' 2>/dev/null || printf '')"
	templates_json="$(printf '%s' "${normalized}" | "${MCPBASH_JSON_TOOL_BIN}" -c 'if has("resourceTemplates") then {resourceTemplates: .resourceTemplates} else empty end' 2>/dev/null || printf '')"
	prompts_json="$(printf '%s' "${normalized}" | "${MCPBASH_JSON_TOOL_BIN}" -c 'if has("prompts") then {prompts: .prompts} else empty end' 2>/dev/null || printf '')"
	completions_json="$(printf '%s' "${normalized}" | "${MCPBASH_JSON_TOOL_BIN}" -c 'if has("completions") then {completions: .completions} else empty end' 2>/dev/null || printf '')"

	# Validate all present kinds first (no writes). Do it in one subshell so
	# resourceTemplates can see resources when both are present.
	local failed_kind=""
	if ! failed_kind="$(
		(
			# Prevent writes during validation and avoid accidental recursive refresh.
			export MCPBASH_REGISTRY_REFRESH_NO_WRITE=true
			export MCP_REGISTRY_REGISTER_COMPLETE=false
			mcp_tools_init
			mcp_resources_init
			mcp_resources_templates_init
			mcp_prompts_init
			if [ -n "${tools_json}" ]; then
				mcp_tools_apply_manual_json "${tools_json}" || {
					printf '%s' 'tools'
					exit 1
				}
			fi
			if [ -n "${resources_json}" ]; then
				mcp_resources_apply_manual_json "${resources_json}" || {
					printf '%s' 'resources'
					exit 1
				}
			fi
			if [ -n "${templates_json}" ]; then
				mcp_resources_templates_apply_manual_json "${templates_json}" || {
					printf '%s' 'resourceTemplates'
					exit 1
				}
			fi
			if [ -n "${prompts_json}" ]; then
				mcp_prompts_apply_manual_json "${prompts_json}" || {
					printf '%s' 'prompts'
					exit 1
				}
			fi
			if [ -n "${completions_json}" ]; then
				mcp_completion_apply_manual_json "${completions_json}" || {
					printf '%s' 'completions'
					exit 1
				}
			fi
		)
	)"; then
		mcp_registry_declarative_set_error_all "Declarative register.json validation failed for ${failed_kind:-unknown}"
		return 0
	fi

	# Apply present kinds for real (writes enabled). Absent kinds remain skipped
	# so callers fall through to auto-discovery.
	mcp_tools_init
	mcp_resources_init
	mcp_resources_templates_init
	mcp_prompts_init

	mcp_registry_register_set_status "tools" "skipped" ""
	mcp_registry_register_set_status "resources" "skipped" ""
	mcp_registry_register_set_status "resourceTemplates" "skipped" ""
	mcp_registry_register_set_status "prompts" "skipped" ""
	mcp_registry_register_set_status "completions" "skipped" ""

	if [ -n "${tools_json}" ]; then
		if mcp_tools_apply_manual_json "${tools_json}"; then
			mcp_registry_register_set_status "tools" "ok" ""
		else
			mcp_registry_declarative_set_error_all "Declarative register.json apply failed for tools"
			return 0
		fi
	fi
	if [ -n "${resources_json}" ]; then
		if mcp_resources_apply_manual_json "${resources_json}"; then
			mcp_registry_register_set_status "resources" "ok" ""
		else
			mcp_registry_declarative_set_error_all "Declarative register.json apply failed for resources"
			return 0
		fi
	fi
	if [ -n "${templates_json}" ]; then
		if mcp_resources_templates_apply_manual_json "${templates_json}"; then
			mcp_registry_register_set_status "resourceTemplates" "ok" ""
		else
			mcp_registry_declarative_set_error_all "Declarative register.json apply failed for resourceTemplates"
			return 0
		fi
	fi
	if [ -n "${prompts_json}" ]; then
		if mcp_prompts_apply_manual_json "${prompts_json}"; then
			mcp_registry_register_set_status "prompts" "ok" ""
		else
			mcp_registry_declarative_set_error_all "Declarative register.json apply failed for prompts"
			return 0
		fi
	fi
	if [ -n "${completions_json}" ]; then
		if mcp_completion_apply_manual_json "${completions_json}"; then
			# shellcheck disable=SC2034  # consumed by completion refresh path in lib/completion.sh
			MCP_COMPLETION_MANUAL_LOADED=true
			mcp_registry_register_set_status "completions" "ok" ""
		else
			mcp_registry_declarative_set_error_all "Declarative register.json apply failed for completions"
			return 0
		fi
	fi

	MCP_REGISTRY_DECLARATIVE_COMPLETE=true
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
	# errexit-safe: capture exit code without toggling shell state
	# Note: use fd 8 to avoid conflicting with MCPBASH_DIRECT_FD (fd 3)
	# shellcheck disable=SC1090
	# shellcheck disable=SC1091
	if exec 8<"${script_path}"; then
		cat <&8 >"${tmp_script}" 2>/dev/null && script_status=0 || script_status=$?
		exec 8<&-
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
			. "${tmp_script}" >"${script_output_file}" 2>&1 && script_status=0 || script_status=$?
		fi
	fi
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
		mcp_registry_register_set_status "resourceTemplates" "error" "Manual registration output exceeded ${manual_limit} bytes"
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
		mcp_registry_register_set_status "resourceTemplates" "error" "${message}"
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
	local json_path
	json_path="$(mcp_registry_declarative_path)"
	local script_path="${MCPBASH_SERVER_DIR}/register.sh"
	# Expose last outcome for callers that need to distinguish "applied" vs
	# "skipped" while still treating skipped as a non-error state.
	# shellcheck disable=SC2034
	MCP_REGISTRY_REGISTER_LAST_KIND="${kind}"
	# shellcheck disable=SC2034
	MCP_REGISTRY_REGISTER_LAST_STATUS=""
	# shellcheck disable=SC2034
	MCP_REGISTRY_REGISTER_LAST_APPLIED=false

	# Declarative registration takes precedence over register.sh and is always
	# attempted if present. If it fails validation, we fail loudly and do not
	# fall back to executing register.sh.
	if [ -f "${json_path}" ]; then
		local signature
		signature="$(mcp_registry_register_signature "${json_path}")"
		local now ttl
		now="$(date +%s)"
		ttl="$(mcp_registry_register_ttl)"
		if [ "${MCP_REGISTRY_DECLARATIVE_COMPLETE}" = true ]; then
			if [ "${signature}" != "${MCP_REGISTRY_DECLARATIVE_SIGNATURE}" ] || [ $((now - MCP_REGISTRY_DECLARATIVE_LAST_RUN)) -ge "${ttl}" ]; then
				mcp_registry_declarative_reset_state
			fi
		fi
		if [ "${MCP_REGISTRY_DECLARATIVE_COMPLETE}" != true ]; then
			mcp_registry_declarative_execute "${json_path}" "${signature}"
		fi
		local status=""
		case "${kind}" in
		tools) status="${MCP_REGISTRY_REGISTER_STATUS_TOOLS}" ;;
		resources) status="${MCP_REGISTRY_REGISTER_STATUS_RESOURCES}" ;;
		resourceTemplates) status="${MCP_REGISTRY_REGISTER_STATUS_RESOURCE_TEMPLATES}" ;;
		prompts) status="${MCP_REGISTRY_REGISTER_STATUS_PROMPTS}" ;;
		completions) status="${MCP_REGISTRY_REGISTER_STATUS_COMPLETIONS}" ;;
		esac
		MCP_REGISTRY_REGISTER_LAST_STATUS="${status}"
		case "${status}" in
		ok)
			MCP_REGISTRY_REGISTER_LAST_APPLIED=true
			return 0
			;;
		skipped)
			return 0
			;;
		error)
			return 2
			;;
		esac
		return 1
	fi
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
