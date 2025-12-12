#!/usr/bin/env bash
# Resource discovery and providers.

set -euo pipefail

MCP_RESOURCES_REGISTRY_JSON=""
MCP_RESOURCES_REGISTRY_HASH=""
MCP_RESOURCES_REGISTRY_PATH=""
# shellcheck disable=SC2034
MCP_RESOURCES_TOTAL=0
# Internal error handoff between library and handler (not user-configurable).
# shellcheck disable=SC2034
_MCP_RESOURCES_ERR_CODE=0
# shellcheck disable=SC2034
_MCP_RESOURCES_ERR_MESSAGE=""
# shellcheck disable=SC2034
_MCP_RESOURCES_RESULT=""
MCP_RESOURCES_TTL="${MCP_RESOURCES_TTL:-5}"
MCP_RESOURCES_LAST_SCAN=0
MCP_RESOURCES_LAST_NOTIFIED_HASH=""
MCP_RESOURCES_CHANGED=false
MCP_RESOURCES_MANUAL_ACTIVE=false
MCP_RESOURCES_MANUAL_BUFFER=""
MCP_RESOURCES_MANUAL_DELIM=$'\036'
MCP_RESOURCES_LOGGER="${MCP_RESOURCES_LOGGER:-mcp.resources}"
MCP_RESOURCES_TEMPLATES_REGISTRY_JSON=""
MCP_RESOURCES_TEMPLATES_REGISTRY_HASH=""
MCP_RESOURCES_TEMPLATES_REGISTRY_PATH=""
MCP_RESOURCES_TEMPLATES_TOTAL=0
MCP_RESOURCES_TEMPLATES_LAST_SCAN=0
MCP_RESOURCES_TEMPLATES_TTL="${MCP_RESOURCES_TEMPLATES_TTL:-5}"
MCP_RESOURCES_TEMPLATES_MANUAL_ACTIVE=false
MCP_RESOURCES_TEMPLATES_MANUAL_BUFFER=""
MCP_RESOURCES_TEMPLATES_MANUAL_DELIM=$'\036'
MCP_RESOURCES_TEMPLATES_MANUAL_JSON="[]"
MCP_RESOURCES_TEMPLATES_MANUAL_UPDATED=false
MCP_RESOURCES_TEMPLATES_LOGGER="${MCP_RESOURCES_TEMPLATES_LOGGER:-mcp.resources.templates}"

if ! command -v mcp_uri_file_uri_from_path >/dev/null 2>&1; then
	# shellcheck disable=SC1090
	. "${MCPBASH_HOME:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}/lib/uri.sh"
fi

if ! command -v mcp_registry_resolve_scan_root >/dev/null 2>&1; then
	# shellcheck disable=SC1090
	. "${MCPBASH_HOME:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}/lib/registry.sh"
fi

if ! command -v mcp_paginate_decode >/dev/null 2>&1; then
	# shellcheck disable=SC1090
	. "${MCPBASH_HOME:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}/lib/paginate.sh"
fi

if ! command -v mcp_resource_content_object_from_file >/dev/null 2>&1; then
	# shellcheck disable=SC1090
	. "${MCPBASH_HOME:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}/lib/resource_content.sh"
fi

mcp_resources_file_uri_from_path() {
	mcp_uri_file_uri_from_path "$1"
}

mcp_resources_scan_root() {
	mcp_registry_resolve_scan_root "${MCPBASH_RESOURCES_DIR}"
}

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

	local registry_json
	if ! registry_json="$(printf '%s' "${MCP_RESOURCES_MANUAL_BUFFER}" | awk -v RS='\036' '{if ($0 != "") print $0}' | "${MCPBASH_JSON_TOOL_BIN}" -s '
		map(select(.name and .uri)) |
		unique_by(.name) |
		map({
			name: .name,
			description: (.description // ""),
			arguments: (.arguments // {type: "object", properties: {}}),
			uri: .uri,
			provider: (.provider // (
				if .uri | startswith("git://") then "git"
				elif .uri | startswith("https://") then "https"
				else "file" end
			)),
			mimeType: (.mimeType // "text/plain"),
			path: (.path // ""),
			icons: (.icons // null)
		}) |
		map(if .icons == null then del(.icons) else . end) |
		sort_by(.name) |
		{
			version: 1,
			generatedAt: (now | todate),
			items: .,
			total: length
		}
	')"; then
		mcp_resources_manual_abort
		mcp_resources_error -32603 "Manual registration parsing failed"
		return 1
	fi

	local items_json
	items_json="$(echo "${registry_json}" | "${MCPBASH_JSON_TOOL_BIN}" -c '.items')"
	local hash
	hash="$(mcp_resources_hash_payload "${items_json}")"
	local total
	total="$(echo "${registry_json}" | "${MCPBASH_JSON_TOOL_BIN}" '.total')"

	# Update hash
	registry_json="$(echo "${registry_json}" | "${MCPBASH_JSON_TOOL_BIN}" --arg hash "${hash}" '.hash = $hash')"

	local previous_hash="${MCP_RESOURCES_REGISTRY_HASH}"
	MCP_RESOURCES_REGISTRY_JSON="${registry_json}"
	MCP_RESOURCES_REGISTRY_HASH="${hash}"
	MCP_RESOURCES_TOTAL="${total}"

	if ! mcp_resources_enforce_registry_limits "${MCP_RESOURCES_TOTAL}" "${registry_json}"; then
		mcp_resources_manual_abort
		return 1
	fi

	MCP_RESOURCES_LAST_SCAN="$(date +%s)"
	local write_rc=0
	mcp_registry_write_with_lock "${MCP_RESOURCES_REGISTRY_PATH}" "${registry_json}" || write_rc=$?
	if [ "${write_rc}" -ne 0 ]; then
		return "${write_rc}"
	fi
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
	mcp_hash_string "${payload}"
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
	mcp_logging_debug "${MCP_RESOURCES_LOGGER}" "Emit update subscription=${subscription_id}"
	# Extract uri from payload contents for the notification
	local uri
	uri="$(echo "${payload}" | "${MCPBASH_JSON_TOOL_BIN}" -r '.contents[0].uri // ""')"
	# MCP 2025-11-25: notifications/resources/updated params are {uri}.
	rpc_send_line_direct "$("${MCPBASH_JSON_TOOL_BIN}" -n -c --arg uri "${uri}" '{"jsonrpc":"2.0","method":"notifications/resources/updated","params":{"uri":$uri}}')"
}

mcp_resources_emit_error() {
	local subscription_id="$1"
	local code="$2"
	local message="$3"
	local uri="${4:-}"
	if [ -z "${uri}" ]; then
		uri=""
	fi
	# MCP 2025-11-25: keep notifications/resources/updated spec-shaped; clients can
	# call resources/read and observe the error there.
	rpc_send_line_direct "$("${MCPBASH_JSON_TOOL_BIN}" -n -c --arg uri "${uri}" '{"jsonrpc":"2.0","method":"notifications/resources/updated","params":{"uri":$uri}}')"
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
		if mcp_resources_read "${name}" "${uri}"; then
			result="${_MCP_RESOURCES_RESULT}"
			local new_fingerprint
			new_fingerprint="$(mcp_resources_hash_payload "${result}")"
			if [ "${new_fingerprint}" != "${fingerprint}" ]; then
				mcp_resources_subscription_store "${subscription_id}" "${name}" "${uri}" "${new_fingerprint}"
				mcp_resources_emit_update "${subscription_id}" "${result}"
			fi
		else
			local code message error_fingerprint
			code="${_MCP_RESOURCES_ERR_CODE:--32603}"
			message="${_MCP_RESOURCES_ERR_MESSAGE:-Unable to read resource}"
			error_fingerprint="ERROR:${code}:$(mcp_resources_hash_payload "${message}")"
			if [ "${error_fingerprint}" != "${fingerprint}" ]; then
				mcp_resources_subscription_store "${subscription_id}" "${name}" "${uri}" "${error_fingerprint}"
				mcp_resources_emit_error "${subscription_id}" "${code}" "${message}" "${uri}"
			fi
		fi
	done
}
mcp_resources_registry_max_bytes() {
	mcp_registry_global_max_bytes
}

mcp_resources_enforce_registry_limits() {
	local total="$1"
	local json_payload="$2"
	local limit_or_size

	if ! limit_or_size="$(mcp_registry_check_size "${json_payload}")"; then
		mcp_resources_error -32603 "Resources registry exceeds ${limit_or_size} byte cap"
		return 1
	fi
	if [ "${total}" -gt 500 ]; then
		mcp_logging_warning "${MCP_RESOURCES_LOGGER}" "Resources registry contains ${total} entries; consider manual registration"
	fi
	return 0
}

mcp_resources_error() {
	_MCP_RESOURCES_ERR_CODE="$1"
	_MCP_RESOURCES_ERR_MESSAGE="$2"
}

mcp_resources_init() {
	if [ -z "${MCP_RESOURCES_REGISTRY_PATH}" ]; then
		MCP_RESOURCES_REGISTRY_PATH="${MCPBASH_REGISTRY_DIR}/resources.json"
	fi
	mkdir -p "${MCPBASH_REGISTRY_DIR}"
	mkdir -p "${MCPBASH_RESOURCES_DIR}" >/dev/null 2>&1 || true
}

mcp_resources_apply_manual_json() {
	local manual_json="$1"
	local registry_json

	# Basic validation of input structure
	if ! echo "${manual_json}" | "${MCPBASH_JSON_TOOL_BIN}" -e '.resources | type == "array"' >/dev/null 2>&1; then
		# If not present or not array, treat as empty
		manual_json='{"resources":[]}'
	fi

	local timestamp
	timestamp="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

	# Construct registry structure
	registry_json="$(echo "${manual_json}" | "${MCPBASH_JSON_TOOL_BIN}" --arg ts "${timestamp}" '{
		version: 1,
		generatedAt: $ts,
		items: .resources,
		total: (.resources | length)
	}')"

	# Calculate hash of items
	local items_json
	items_json="$(echo "${registry_json}" | "${MCPBASH_JSON_TOOL_BIN}" -c '.items')"
	local hash
	hash="$(mcp_resources_hash_payload "${items_json}")"

	# Add hash to registry
	registry_json="$(echo "${registry_json}" | "${MCPBASH_JSON_TOOL_BIN}" --arg hash "${hash}" '.hash = $hash')"

	local new_hash="${hash}"
	MCP_RESOURCES_REGISTRY_JSON="${registry_json}"
	MCP_RESOURCES_REGISTRY_HASH="${new_hash}"
	MCP_RESOURCES_TOTAL="$(echo "${registry_json}" | "${MCPBASH_JSON_TOOL_BIN}" '.total')"

	if ! mcp_resources_enforce_registry_limits "${MCP_RESOURCES_TOTAL}" "${registry_json}"; then
		return 1
	fi
	MCP_RESOURCES_LAST_SCAN="$(date +%s)"
	local write_rc=0
	mcp_registry_write_with_lock "${MCP_RESOURCES_REGISTRY_PATH}" "${registry_json}" || write_rc=$?
	if [ "${write_rc}" -ne 0 ]; then
		return "${write_rc}"
	fi
}

mcp_resources_refresh_registry() {
	local scan_root
	scan_root="$(mcp_resources_scan_root)"
	mcp_resources_init
	if mcp_logging_is_enabled "debug"; then
		local register_exists
		register_exists="$([[ -x "${MCPBASH_SERVER_DIR}/register.sh" ]] && echo yes || echo no)"
		if mcp_logging_verbose_enabled; then
			mcp_logging_debug "${MCP_RESOURCES_LOGGER}" "Refresh start register=${MCPBASH_SERVER_DIR}/register.sh exists=${register_exists} ttl=${MCP_RESOURCES_TTL:-5}"
		else
			mcp_logging_debug "${MCP_RESOURCES_LOGGER}" "Refresh start exists=${register_exists} ttl=${MCP_RESOURCES_TTL:-5}"
		fi
	fi
	local manual_status=0
	mcp_registry_register_apply "resources"
	manual_status=$?
	if [ "${manual_status}" -eq 2 ]; then
		local err
		err="$(mcp_registry_register_error_for_kind "resources")"
		if [ -z "${err}" ]; then
			err="Manual registration script returned empty output or non-zero"
		fi
		mcp_logging_error "${MCP_RESOURCES_LOGGER}" "${err}"
		return 1
	fi
	if [ "${manual_status}" -eq 0 ] && [ "${MCP_REGISTRY_REGISTER_LAST_APPLIED:-false}" = "true" ]; then
		mcp_logging_debug "${MCP_RESOURCES_LOGGER}" "Refresh satisfied by manual script"
		return 0
	fi
	local now
	now="$(date +%s)"

	if [ -z "${MCP_RESOURCES_REGISTRY_JSON}" ] && [ -f "${MCP_RESOURCES_REGISTRY_PATH}" ]; then
		local tmp_json=""
		if tmp_json="$(cat "${MCP_RESOURCES_REGISTRY_PATH}")"; then
			if echo "${tmp_json}" | "${MCPBASH_JSON_TOOL_BIN}" . >/dev/null 2>&1; then
				MCP_RESOURCES_REGISTRY_JSON="${tmp_json}"
				MCP_RESOURCES_REGISTRY_HASH="$(echo "${MCP_RESOURCES_REGISTRY_JSON}" | "${MCPBASH_JSON_TOOL_BIN}" -r '.hash // empty')"
				MCP_RESOURCES_TOTAL="$(echo "${MCP_RESOURCES_REGISTRY_JSON}" | "${MCPBASH_JSON_TOOL_BIN}" '.total // 0')"
				if ! mcp_resources_enforce_registry_limits "${MCP_RESOURCES_TOTAL}" "${MCP_RESOURCES_REGISTRY_JSON}"; then
					return 1
				fi
			else
				mcp_logging_warning "${MCP_RESOURCES_LOGGER}" "Discarding invalid resource registry cache"
				MCP_RESOURCES_REGISTRY_JSON=""
			fi
		else
			if mcp_logging_verbose_enabled; then
				mcp_logging_warning "${MCP_RESOURCES_LOGGER}" "Failed to read resource registry cache ${MCP_RESOURCES_REGISTRY_PATH}"
			else
				mcp_logging_warning "${MCP_RESOURCES_LOGGER}" "Failed to read resource registry cache"
			fi
			MCP_RESOURCES_REGISTRY_JSON=""
		fi
	fi
	if [ -n "${MCP_RESOURCES_REGISTRY_JSON}" ] && [ $((now - MCP_RESOURCES_LAST_SCAN)) -lt "${MCP_RESOURCES_TTL}" ]; then
		mcp_logging_debug "${MCP_RESOURCES_LOGGER}" "Refresh skipped due to ttl (last=${MCP_RESOURCES_LAST_SCAN})"
		return 0
	fi

	local fastpath_snapshot
	fastpath_snapshot="$(mcp_registry_fastpath_snapshot "${scan_root}")"
	if mcp_registry_fastpath_unchanged "resources" "${fastpath_snapshot}"; then
		MCP_RESOURCES_LAST_SCAN="${now}"
		# Sync in-memory state from cache if another process refreshed the registry
		if [ -f "${MCP_RESOURCES_REGISTRY_PATH}" ]; then
			local cached_hash
			cached_hash="$("${MCPBASH_JSON_TOOL_BIN}" -r '.hash // empty' "${MCP_RESOURCES_REGISTRY_PATH}" 2>/dev/null || true)"
			if [ -n "${cached_hash}" ] && [ "${cached_hash}" != "${MCP_RESOURCES_REGISTRY_HASH}" ]; then
				local cached_json cached_total
				cached_json="$(cat "${MCP_RESOURCES_REGISTRY_PATH}" 2>/dev/null || true)"
				cached_total="$("${MCPBASH_JSON_TOOL_BIN}" '.total // 0' "${MCP_RESOURCES_REGISTRY_PATH}" 2>/dev/null || printf '0')"
				MCP_RESOURCES_REGISTRY_JSON="${cached_json}"
				MCP_RESOURCES_REGISTRY_HASH="${cached_hash}"
				MCP_RESOURCES_TOTAL="${cached_total}"
				MCP_RESOURCES_CHANGED=true
			fi
		fi
		return 0
	fi

	# Capture previous hash from cache file if in-memory state is empty (parent may not have run scan yet)
	local previous_hash="${MCP_RESOURCES_REGISTRY_HASH}"
	if [ -z "${previous_hash}" ] && [ -f "${MCP_RESOURCES_REGISTRY_PATH}" ]; then
		previous_hash="$("${MCPBASH_JSON_TOOL_BIN}" -r '.hash // empty' "${MCP_RESOURCES_REGISTRY_PATH}" 2>/dev/null || true)"
	fi
	mcp_resources_scan "${scan_root}" || return 1
	MCP_RESOURCES_LAST_SCAN="${now}"
	# Recompute fastpath snapshot post-scan to capture content-only changes
	fastpath_snapshot="$(mcp_registry_fastpath_snapshot "${scan_root}")"
	mcp_registry_fastpath_store "resources" "${fastpath_snapshot}" || true
	# Incorporate fastpath snapshot into registry hash so content changes trigger notifications
	if [ -n "${MCP_RESOURCES_REGISTRY_HASH}" ] && [ -n "${fastpath_snapshot}" ]; then
		local combined_hash
		combined_hash="$(mcp_hash_string "${MCP_RESOURCES_REGISTRY_HASH}|${fastpath_snapshot}")"
		MCP_RESOURCES_REGISTRY_HASH="${combined_hash}"
		MCP_RESOURCES_REGISTRY_JSON="$(printf '%s' "${MCP_RESOURCES_REGISTRY_JSON}" | "${MCPBASH_JSON_TOOL_BIN}" --arg hash "${combined_hash}" '.hash = $hash')"
		local write_rc=0
		mcp_registry_write_with_lock "${MCP_RESOURCES_REGISTRY_PATH}" "${MCP_RESOURCES_REGISTRY_JSON}" || write_rc=$?
		if [ "${write_rc}" -ne 0 ]; then
			return "${write_rc}"
		fi
	fi
	mcp_logging_debug "${MCP_RESOURCES_LOGGER}" "Refresh completed scan hash=${MCP_RESOURCES_REGISTRY_HASH}"
	if [ "${previous_hash}" != "${MCP_RESOURCES_REGISTRY_HASH}" ]; then
		MCP_RESOURCES_CHANGED=true
	fi
}

mcp_resources_scan() {
	local resources_dir="${1:-${MCPBASH_RESOURCES_DIR}}"
	local items_file
	items_file="$(mktemp "${MCPBASH_TMP_ROOT}/mcp-resources-items.XXXXXX")"
	local names_seen_file
	names_seen_file="$(mktemp "${MCPBASH_TMP_ROOT}/mcp-resources-names.XXXXXX")"
	local duplicate_name=""

	if [ -d "${resources_dir}" ]; then
		while IFS= read -r path; do
			local rel_path="${path#"${MCPBASH_RESOURCES_DIR}"/}"
			local base_name
			base_name="$(basename "${path}")"
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
			local uri=""
			local mime="text/plain"
			local provider=""
			local icons="null"

			if [ -f "${meta_json}" ]; then
				local meta
				# Strip \r to handle CRLF line endings from Windows checkouts
				meta="$(tr -d '\r' <"${meta_json}")"
				local j_name
				j_name="$(printf '%s' "${meta}" | "${MCPBASH_JSON_TOOL_BIN}" -r '.name // empty' 2>/dev/null)"
				[ -n "${j_name}" ] && name="${j_name}"
				description="$(printf '%s' "${meta}" | "${MCPBASH_JSON_TOOL_BIN}" -r '.description // empty' 2>/dev/null)"
				uri="$(printf '%s' "${meta}" | "${MCPBASH_JSON_TOOL_BIN}" -r '.uri // empty' 2>/dev/null)"
				mime="$(printf '%s' "${meta}" | "${MCPBASH_JSON_TOOL_BIN}" -r '.mimeType // "text/plain"' 2>/dev/null)"
				provider="$(printf '%s' "${meta}" | "${MCPBASH_JSON_TOOL_BIN}" -r '.provider // empty' 2>/dev/null)"
				icons="$(printf '%s' "${meta}" | "${MCPBASH_JSON_TOOL_BIN}" -c '.icons // null' 2>/dev/null || printf 'null')"
				# Convert local file paths to data URIs
				local meta_dir
				meta_dir="$(dirname "${meta_json}")"
				icons="$(mcp_json_icons_to_data_uris "${icons}" "${meta_dir}")"
			fi

			if [ -z "${uri}" ]; then
				local header
				header="$(head -n 10 "${path}")"
				local mcp_line
				mcp_line="$(echo "${header}" | grep "mcp:" | head -n 1)"
				if [ -n "${mcp_line}" ]; then
					local json_payload
					json_payload="${mcp_line#*mcp:}"
					local h_name
					h_name="$(echo "${json_payload}" | "${MCPBASH_JSON_TOOL_BIN}" -r '.name // empty' 2>/dev/null)"
					[ -n "${h_name}" ] && name="${h_name}"
					local h_uri
					h_uri="$(echo "${json_payload}" | "${MCPBASH_JSON_TOOL_BIN}" -r '.uri // empty' 2>/dev/null)"
					[ -n "${h_uri}" ] && uri="${h_uri}"
					local h_desc
					h_desc="$(echo "${json_payload}" | "${MCPBASH_JSON_TOOL_BIN}" -r '.description // empty' 2>/dev/null)"
					[ -n "${h_desc}" ] && description="${h_desc}"
					local h_icons
					h_icons="$(echo "${json_payload}" | "${MCPBASH_JSON_TOOL_BIN}" -c '.icons // null' 2>/dev/null)"
					if [ -n "${h_icons}" ] && [ "${h_icons}" != "null" ]; then
						# Convert local file paths to data URIs
						local script_dir
						script_dir="$(dirname "${path}")"
						icons="$(mcp_json_icons_to_data_uris "${h_icons}" "${script_dir}")"
					fi
				fi
			fi

			if [ -z "${uri}" ]; then
				local computed_uri=""
				if computed_uri="$(mcp_resources_file_uri_from_path "${path}" 2>/dev/null)"; then
					uri="${computed_uri}"
				fi
			fi

			if [ -z "${uri}" ]; then
				continue
			fi

			if [ -z "${provider}" ]; then
				provider="file"
				case "${uri}" in
				https://*) provider="https" ;;
				git://*) provider="git" ;;
				esac
			fi

			if grep -Fxq "${name}" "${names_seen_file}"; then
				duplicate_name="${name}"
				break
			fi
			echo "${name}" >>"${names_seen_file}"

			# Ensure icons is valid JSON (fallback to null if empty)
			[ -z "${icons}" ] && icons='null'

			"${MCPBASH_JSON_TOOL_BIN}" -n \
				--arg name "$name" \
				--arg desc "$description" \
				--arg path "$rel_path" \
				--arg uri "$uri" \
				--arg mime "$mime" \
				--arg provider "$provider" \
				--argjson icons "$icons" \
				'{name: $name, description: $desc, path: $path, uri: $uri, mimeType: $mime, provider: $provider}
				+ (if $icons != null then {icons: $icons} else {} end)' >>"${items_file}"
		done < <(find "${resources_dir}" -type f ! -name ".*" ! -name "*.meta.json" 2>/dev/null | LC_ALL=C sort)
	fi

	if [ -n "${duplicate_name}" ]; then
		rm -f "${items_file}" "${names_seen_file}"
		mcp_logging_error "${MCP_RESOURCES_LOGGER}" "Duplicate resource name detected: ${duplicate_name}"
		mcp_resources_error -32603 "Duplicate resource name: ${duplicate_name}"
		return 1
	fi

	local timestamp
	timestamp="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
	local items_json="[]"
	if [ -s "${items_file}" ]; then
		local parsed
		if parsed="$("${MCPBASH_JSON_TOOL_BIN}" -s '.' "${items_file}" 2>/dev/null)"; then
			items_json="${parsed}"
		fi
	fi
	rm -f "${items_file}" "${names_seen_file}"

	local hash
	hash="$(mcp_resources_hash_payload "${items_json}")"
	local total
	total="$(printf '%s' "${items_json}" | "${MCPBASH_JSON_TOOL_BIN}" 'length' 2>/dev/null)" || total=0
	# Ensure total is a valid number
	case "${total}" in
	'' | *[!0-9]*) total=0 ;;
	esac

	MCP_RESOURCES_REGISTRY_JSON="$("${MCPBASH_JSON_TOOL_BIN}" -n \
		--arg ver "1" \
		--arg ts "${timestamp}" \
		--arg hash "${hash}" \
		--argjson items "${items_json}" \
		--argjson total "${total}" \
		'{version: $ver|tonumber, generatedAt: $ts, items: $items, hash: $hash, total: $total}')"

	MCP_RESOURCES_REGISTRY_HASH="${hash}"
	MCP_RESOURCES_TOTAL="${total}"

	if ! mcp_resources_enforce_registry_limits "${MCP_RESOURCES_TOTAL}" "${MCP_RESOURCES_REGISTRY_JSON}"; then
		return 1
	fi

	if ! mcp_registry_write_with_lock "${MCP_RESOURCES_REGISTRY_PATH}" "${MCP_RESOURCES_REGISTRY_JSON}"; then
		return 1
	fi
}

mcp_resources_decode_cursor() {
	local cursor="$1"
	local hash="$2"
	local offset
	local decode_status=0
	offset="$(mcp_paginate_decode "${cursor}" "resources" "${hash}")" || decode_status=$?
	if [ "${decode_status}" -ne 0 ]; then
		return 1
	fi
	printf '%s' "${offset}"
}

mcp_resources_list() {
	local limit="$1"
	local cursor="$2"
	# shellcheck disable=SC2034
	_MCP_RESOURCES_ERR_CODE=0
	# shellcheck disable=SC2034
	_MCP_RESOURCES_ERR_MESSAGE=""

	mcp_resources_refresh_registry || {
		mcp_resources_error -32603 "Unable to load resources registry"
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
		if ! offset="$(mcp_resources_decode_cursor "${cursor}" "${MCP_RESOURCES_REGISTRY_HASH}")"; then
			mcp_resources_error -32602 "Invalid cursor"
			return 1
		fi
	fi

	local total="${MCP_RESOURCES_TOTAL}"
	local result_json
	# Like tools/list, expose total via result._meta.total for strict-client
	# compatibility (instead of a top-level field).
	result_json="$(echo "${MCP_RESOURCES_REGISTRY_JSON}" | "${MCPBASH_JSON_TOOL_BIN}" -c --argjson offset "$offset" --argjson limit "$numeric_limit" --argjson total "${total}" '
		{
			resources: .items[$offset:$offset+$limit],
			_meta: {total: $total}
		}
	')"

	if ! result_json="$(mcp_paginate_attach_next_cursor "${result_json}" "resources" "${offset}" "${numeric_limit}" "${total}" "${MCP_RESOURCES_REGISTRY_HASH}")"; then
		mcp_resources_error -32603 "Unable to encode resources cursor"
		return 1
	fi

	printf '%s' "${result_json}"
}

mcp_resources_consume_notification() {
	local actually_emit="${1:-true}"
	local current_hash="${MCP_RESOURCES_REGISTRY_HASH}"
	_MCP_NOTIFICATION_PAYLOAD=""

	if [ -z "${current_hash}" ]; then
		return 0
	fi

	if [ "${MCP_RESOURCES_CHANGED}" != "true" ]; then
		return 0
	fi

	if [ "${actually_emit}" = "true" ]; then
		# shellcheck disable=SC2034  # stored for next consume call
		MCP_RESOURCES_LAST_NOTIFIED_HASH="${current_hash}"
		MCP_RESOURCES_CHANGED=false
		_MCP_NOTIFICATION_PAYLOAD='{"jsonrpc":"2.0","method":"notifications/resources/list_changed","params":{}}'
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
	mcp_resources_templates_refresh_registry || true
	return 0
}

mcp_resources_metadata_for_name() {
	local name="$1"
	mcp_resources_refresh_registry || return 1
	local metadata
	if ! metadata="$(echo "${MCP_RESOURCES_REGISTRY_JSON}" | "${MCPBASH_JSON_TOOL_BIN}" -c --arg name "${name}" '.items[] | select(.name == $name)' | head -n 1)"; then
		return 1
	fi
	if [ -z "${metadata}" ]; then
		return 1
	fi
	printf '%s' "${metadata}"
}

mcp_resources_templates_has_variable() {
	local template="$1"
	printf '%s' "${template}" | grep -q '{[^}]*[^[:space:]][^}]*}'
}

mcp_resources_templates_collect_resource_names() {
	local resources_dir="$1"
	local output_file="$2"

	if [ -z "${resources_dir}" ] || [ ! -d "${resources_dir}" ]; then
		return 0
	fi

	while IFS= read -r meta_path; do
		local meta has_uri has_template name
		if ! meta="$(cat "${meta_path}")"; then
			continue
		fi
		has_uri="$(printf '%s' "${meta}" | "${MCPBASH_JSON_TOOL_BIN}" -r 'if (.uri | type == "string") then "yes" else "no" end' 2>/dev/null)"
		has_template="$(printf '%s' "${meta}" | "${MCPBASH_JSON_TOOL_BIN}" -r 'if (.uriTemplate | type == "string") then "yes" else "no" end' 2>/dev/null)"
		if [ "${has_uri}" != "yes" ]; then
			continue
		fi
		if [ "${has_template}" = "yes" ]; then
			continue
		fi
		name="$(printf '%s' "${meta}" | "${MCPBASH_JSON_TOOL_BIN}" -r 'if (.name | type == "string") then .name else empty end' 2>/dev/null)"
		[ -z "${name}" ] && continue
		printf '%s\n' "${name}" >>"${output_file}"
	done < <(find "${resources_dir}" -type f -name "*.meta.json" ! -name ".*" 2>/dev/null | LC_ALL=C sort)

	if [ -s "${output_file}" ]; then
		local tmp
		tmp="$(mktemp "${MCPBASH_TMP_ROOT}/mcp-resource-template-names-sort.XXXXXX")"
		LC_ALL=C sort -u "${output_file}" >"${tmp}"
		mv "${tmp}" "${output_file}"
	fi
}

mcp_resources_templates_enforce_registry_limits() {
	local total="$1"
	local json_payload="$2"
	local limit_or_size

	if ! limit_or_size="$(mcp_registry_check_size "${json_payload}")"; then
		mcp_resources_error -32603 "Resource templates registry exceeds ${limit_or_size} byte cap"
		return 1
	fi
	if [ "${total}" -gt 500 ]; then
		mcp_logging_warning "${MCP_RESOURCES_TEMPLATES_LOGGER}" "Resource templates registry contains ${total} entries; consider manual registration"
	fi
	return 0
}

mcp_resources_templates_init() {
	if [ -z "${MCP_RESOURCES_TEMPLATES_REGISTRY_PATH}" ]; then
		MCP_RESOURCES_TEMPLATES_REGISTRY_PATH="${MCPBASH_REGISTRY_DIR}/resource-templates.json"
	fi
	mkdir -p "${MCPBASH_REGISTRY_DIR}"
	mkdir -p "${MCPBASH_RESOURCES_DIR}" >/dev/null 2>&1 || true
}

mcp_resources_templates_manual_begin() {
	MCP_RESOURCES_TEMPLATES_MANUAL_ACTIVE=true
	MCP_RESOURCES_TEMPLATES_MANUAL_BUFFER=""
	MCP_RESOURCES_TEMPLATES_MANUAL_JSON="[]"
	MCP_RESOURCES_TEMPLATES_MANUAL_UPDATED=true
}

mcp_resources_templates_manual_abort() {
	MCP_RESOURCES_TEMPLATES_MANUAL_ACTIVE=false
	MCP_RESOURCES_TEMPLATES_MANUAL_BUFFER=""
	MCP_RESOURCES_TEMPLATES_MANUAL_JSON="[]"
	MCP_RESOURCES_TEMPLATES_MANUAL_UPDATED=true
}

mcp_resources_templates_register_manual() {
	local payload="$1"
	if [ "${MCP_RESOURCES_TEMPLATES_MANUAL_ACTIVE}" != "true" ]; then
		return 0
	fi
	if [ -z "${payload}" ]; then
		return 0
	fi

	local json_type
	if ! json_type="$(printf '%s' "${payload}" | "${MCPBASH_JSON_TOOL_BIN}" -r 'type' 2>/dev/null)"; then
		mcp_logging_warning "${MCP_RESOURCES_TEMPLATES_LOGGER}" "Invalid JSON in manual template registration"
		return 1
	fi
	if [ "${json_type}" != "object" ]; then
		mcp_logging_warning "${MCP_RESOURCES_TEMPLATES_LOGGER}" "Manual template registration must be an object, got: ${json_type}"
		return 1
	fi

	local name uri_template uri_present
	name="$(printf '%s' "${payload}" | "${MCPBASH_JSON_TOOL_BIN}" -r 'if (.name | type == "string") then .name else empty end' 2>/dev/null)"
	uri_template="$(printf '%s' "${payload}" | "${MCPBASH_JSON_TOOL_BIN}" -r 'if (.uriTemplate | type == "string") then .uriTemplate else empty end' 2>/dev/null)"
	uri_present="$(printf '%s' "${payload}" | "${MCPBASH_JSON_TOOL_BIN}" -r 'if (.uri | type == "string") then "yes" else "no" end' 2>/dev/null)"

	if [ -z "${name}" ]; then
		mcp_logging_warning "${MCP_RESOURCES_TEMPLATES_LOGGER}" "Manual template missing required 'name' field"
		return 1
	fi
	if [ "${uri_present}" = "yes" ] && [ -n "${uri_template}" ]; then
		mcp_logging_warning "${MCP_RESOURCES_TEMPLATES_LOGGER}" "Manual template '${name}' has both uri and uriTemplate (mutually exclusive)"
		return 1
	fi
	if [ -z "${uri_template}" ]; then
		mcp_logging_warning "${MCP_RESOURCES_TEMPLATES_LOGGER}" "Manual template missing required 'uriTemplate' field"
		return 1
	fi
	if ! mcp_resources_templates_has_variable "${uri_template}"; then
		mcp_logging_warning "${MCP_RESOURCES_TEMPLATES_LOGGER}" "Template '${name}' uriTemplate must contain at least one {variable}"
		return 1
	fi

	local compact_payload
	if ! compact_payload="$(printf '%s' "${payload}" | "${MCPBASH_JSON_TOOL_BIN}" -c '.' 2>/dev/null)"; then
		mcp_logging_warning "${MCP_RESOURCES_TEMPLATES_LOGGER}" "Manual template registration: invalid JSON payload for '${name}'"
		return 1
	fi

	if [ -n "${MCP_RESOURCES_TEMPLATES_MANUAL_BUFFER}" ]; then
		MCP_RESOURCES_TEMPLATES_MANUAL_BUFFER="${MCP_RESOURCES_TEMPLATES_MANUAL_BUFFER}${MCP_RESOURCES_TEMPLATES_MANUAL_DELIM}${compact_payload}"
	else
		MCP_RESOURCES_TEMPLATES_MANUAL_BUFFER="${compact_payload}"
	fi
	return 0
}

mcp_resources_templates_normalize() {
	local payload="$1"
	local context="$2"
	local resource_names_file="${3:-}"

	if ! printf '%s' "${payload}" | "${MCPBASH_JSON_TOOL_BIN}" -e 'type == "object"' >/dev/null 2>&1; then
		mcp_logging_warning "${MCP_RESOURCES_TEMPLATES_LOGGER}" "${context}: skipping non-object template entry"
		return 1
	fi

	local name uri_template uri_value title description mime annotations meta
	name="$(printf '%s' "${payload}" | "${MCPBASH_JSON_TOOL_BIN}" -r 'if (.name | type == "string") then .name else empty end' 2>/dev/null)"
	uri_template="$(printf '%s' "${payload}" | "${MCPBASH_JSON_TOOL_BIN}" -r 'if (.uriTemplate | type == "string") then .uriTemplate else empty end' 2>/dev/null)"
	uri_value="$(printf '%s' "${payload}" | "${MCPBASH_JSON_TOOL_BIN}" -r 'if (.uri | type == "string") then .uri else empty end' 2>/dev/null)"

	if [ -z "${uri_template}" ] && [ -n "${uri_value}" ]; then
		return 1
	fi
	if [ -z "${uri_template}" ]; then
		mcp_logging_warning "${MCP_RESOURCES_TEMPLATES_LOGGER}" "${context}: skipping entry without uriTemplate"
		return 1
	fi
	if [ -n "${uri_value}" ]; then
		mcp_logging_warning "${MCP_RESOURCES_TEMPLATES_LOGGER}" "${context}: '${name:-<unnamed>}' has both uri and uriTemplate (mutually exclusive), skipping"
		return 1
	fi
	if [ -z "${name}" ]; then
		mcp_logging_warning "${MCP_RESOURCES_TEMPLATES_LOGGER}" "${context}: skipping template without name"
		return 1
	fi

	uri_template="${uri_template//$'\n'/}"
	uri_template="${uri_template//$'\r'/}"
	if ! mcp_resources_templates_has_variable "${uri_template}"; then
		mcp_logging_warning "${MCP_RESOURCES_TEMPLATES_LOGGER}" "${context}: '${name}' uriTemplate has no {variable}, skipping"
		return 1
	fi

	if [ -n "${resource_names_file}" ] && [ -f "${resource_names_file}" ]; then
		if grep -Fxq "${name}" "${resource_names_file}"; then
			mcp_logging_warning "${MCP_RESOURCES_TEMPLATES_LOGGER}" "${context}: template name conflicts with existing resource '${name}', skipping"
			return 1
		fi
	fi

	title="$(printf '%s' "${payload}" | "${MCPBASH_JSON_TOOL_BIN}" -r 'if (.title | type == "string") then .title else empty end' 2>/dev/null)"
	description="$(printf '%s' "${payload}" | "${MCPBASH_JSON_TOOL_BIN}" -r 'if (.description | type == "string") then .description else empty end' 2>/dev/null)"
	mime="$(printf '%s' "${payload}" | "${MCPBASH_JSON_TOOL_BIN}" -r 'if (.mimeType | type == "string") then .mimeType else empty end' 2>/dev/null)"
	annotations="$(printf '%s' "${payload}" | "${MCPBASH_JSON_TOOL_BIN}" -c 'try .annotations catch "null"' 2>/dev/null || printf 'null')"
	meta="$(printf '%s' "${payload}" | "${MCPBASH_JSON_TOOL_BIN}" -c 'try ._meta catch "null"' 2>/dev/null || printf 'null')"
	[ -z "${annotations}" ] && annotations="null"
	[ -z "${meta}" ] && meta="null"

	"${MCPBASH_JSON_TOOL_BIN}" -n \
		--arg name "${name}" \
		--arg uriTemplate "${uri_template}" \
		--arg title "${title}" \
		--arg description "${description}" \
		--arg mime "${mime}" \
		--argjson annotations "${annotations}" \
		--argjson meta "${meta}" '
			{
				name: $name,
				uriTemplate: $uriTemplate
			}
			| (if $title != "" then . + {title: $title} else . end)
			| (if $description != "" then . + {description: $description} else . end)
			| (if $mime != "" then . + {mimeType: $mime} else . end)
			| (if $annotations != null then . + {annotations: $annotations} else . end)
			| (if $meta != null then . + {_meta: $meta} else . end)
		' 2>/dev/null
}

mcp_resources_templates_apply_manual_json() {
	local manual_json="$1"
	local templates_json

	if ! templates_json="$(printf '%s' "${manual_json}" | "${MCPBASH_JSON_TOOL_BIN}" -c '.resourceTemplates // []' 2>/dev/null)"; then
		return 1
	fi

	MCP_RESOURCES_TEMPLATES_MANUAL_BUFFER=""
	MCP_RESOURCES_TEMPLATES_MANUAL_ACTIVE=true
	MCP_RESOURCES_TEMPLATES_MANUAL_JSON="[]"
	MCP_RESOURCES_TEMPLATES_MANUAL_UPDATED=true
	if [ -n "${templates_json}" ] && [ "${templates_json}" != "[]" ]; then
		while IFS= read -r entry; do
			[ -z "${entry}" ] && continue
			mcp_resources_templates_register_manual "${entry}" || true
		done < <(printf '%s' "${templates_json}" | "${MCPBASH_JSON_TOOL_BIN}" -c '.[] // empty' 2>/dev/null)
	fi
	if mcp_resources_templates_manual_finalize; then
		return 0
	fi
	return 1
}

mcp_resources_templates_manual_finalize() {
	if [ "${MCP_RESOURCES_TEMPLATES_MANUAL_ACTIVE}" != "true" ]; then
		return 0
	fi

	local resources_available=true
	if [ -z "${MCP_RESOURCES_REGISTRY_JSON}" ]; then
		if [ "${MCP_REGISTRY_REGISTER_COMPLETE:-false}" != "true" ]; then
			resources_available=false
		else
			if ! mcp_resources_refresh_registry 2>/dev/null; then
				resources_available=false
			fi
			if [ -z "${MCP_RESOURCES_REGISTRY_JSON}" ]; then
				resources_available=false
			fi
		fi
	fi
	if [ "${resources_available}" = false ]; then
		mcp_logging_warning "${MCP_RESOURCES_TEMPLATES_LOGGER}" "Cannot check for name collisions: resource registry unavailable"
	fi

	local resource_names_file=""
	if [ "${resources_available}" = true ]; then
		resource_names_file="$(mktemp "${MCPBASH_TMP_ROOT}/mcp-resource-template-names.XXXXXX")"
		printf '%s' "${MCP_RESOURCES_REGISTRY_JSON}" | "${MCPBASH_JSON_TOOL_BIN}" -r '.items[].name // empty' >"${resource_names_file}"
	fi

	local items_file names_seen_file
	items_file="$(mktemp "${MCPBASH_TMP_ROOT}/mcp-resource-templates-manual.XXXXXX")"
	names_seen_file="$(mktemp "${MCPBASH_TMP_ROOT}/mcp-resource-templates-manual-names.XXXXXX")"

	while IFS= read -r item; do
		[ -z "${item}" ] && continue
		local normalized name
		if ! normalized="$(mcp_resources_templates_normalize "${item}" "Manual registration" "${resource_names_file}")"; then
			continue
		fi
		name="$(printf '%s' "${normalized}" | "${MCPBASH_JSON_TOOL_BIN}" -r '.name')"
		if grep -Fxq "${name}" "${names_seen_file}"; then
			mcp_logging_warning "${MCP_RESOURCES_TEMPLATES_LOGGER}" "Duplicate template name in manual registration: ${name} (keeping first)"
			continue
		fi
		printf '%s\n' "${name}" >>"${names_seen_file}"
		printf '%s\n' "${normalized}" >>"${items_file}"
	done < <(printf '%s' "${MCP_RESOURCES_TEMPLATES_MANUAL_BUFFER}" | awk -v RS='\036' '{if ($0 != "") print $0}')

	local validated="[]"
	if [ -s "${items_file}" ]; then
		if ! validated="$("${MCPBASH_JSON_TOOL_BIN}" -s 'sort_by(.name)' "${items_file}" 2>/dev/null)"; then
			validated="[]"
		fi
	fi

	rm -f "${items_file}" "${names_seen_file}"
	if [ -n "${resource_names_file}" ]; then
		rm -f "${resource_names_file}"
	fi

	MCP_RESOURCES_TEMPLATES_MANUAL_JSON="${validated}"
	MCP_RESOURCES_TEMPLATES_MANUAL_UPDATED=true
	MCP_RESOURCES_TEMPLATES_MANUAL_ACTIVE=false
	MCP_RESOURCES_TEMPLATES_MANUAL_BUFFER=""
	return 0
}

mcp_resources_templates_scan() {
	local resources_dir="${1:-${MCPBASH_RESOURCES_DIR}}"
	local resource_names_file="${2:-}"
	local items_file names_seen_file
	items_file="$(mktemp "${MCPBASH_TMP_ROOT}/mcp-resource-templates-items.XXXXXX")"
	names_seen_file="$(mktemp "${MCPBASH_TMP_ROOT}/mcp-resource-templates-names.XXXXXX")"

	if [ -d "${resources_dir}" ]; then
		while IFS= read -r meta_path; do
			local meta has_template has_uri
			# Strip \r to handle CRLF line endings from Windows checkouts
			if ! meta="$(tr -d '\r' <"${meta_path}")"; then
				mcp_logging_warning "${MCP_RESOURCES_TEMPLATES_LOGGER}" "Unable to read ${meta_path}"
				continue
			fi
			if ! printf '%s' "${meta}" | "${MCPBASH_JSON_TOOL_BIN}" . >/dev/null 2>&1; then
				mcp_logging_warning "${MCP_RESOURCES_TEMPLATES_LOGGER}" "Malformed template metadata ${meta_path}, skipping"
				continue
			fi
			has_template="$(printf '%s' "${meta}" | "${MCPBASH_JSON_TOOL_BIN}" -r 'if (.uriTemplate | type == "string") then "yes" else "no" end' 2>/dev/null)"
			has_uri="$(printf '%s' "${meta}" | "${MCPBASH_JSON_TOOL_BIN}" -r 'if (.uri | type == "string") then "yes" else "no" end' 2>/dev/null)"

			if [ "${has_uri}" = "yes" ] && [ "${has_template}" = "yes" ]; then
				mcp_logging_warning "${MCP_RESOURCES_TEMPLATES_LOGGER}" "${meta_path}: uri and uriTemplate are mutually exclusive, skipping"
				continue
			fi
			if [ "${has_template}" != "yes" ]; then
				continue
			fi
			if [ "${has_uri}" = "yes" ]; then
				continue
			fi

			local normalized name
			if ! normalized="$(mcp_resources_templates_normalize "${meta}" "Auto-discovery ${meta_path}" "${resource_names_file}")"; then
				continue
			fi
			name="$(printf '%s' "${normalized}" | "${MCPBASH_JSON_TOOL_BIN}" -r '.name')"
			if grep -Fxq "${name}" "${names_seen_file}"; then
				mcp_logging_warning "${MCP_RESOURCES_TEMPLATES_LOGGER}" "Duplicate template name in auto-discovery: ${name} (keeping first)"
				continue
			fi
			printf '%s\n' "${name}" >>"${names_seen_file}"
			printf '%s\n' "${normalized}" >>"${items_file}"
		done < <(find "${resources_dir}" -type f -name "*.meta.json" ! -name ".*" 2>/dev/null | LC_ALL=C sort)
	fi

	local items_json="[]"
	if [ -s "${items_file}" ]; then
		local parsed
		if parsed="$("${MCPBASH_JSON_TOOL_BIN}" -s 'sort_by(.name)' "${items_file}" 2>/dev/null)"; then
			items_json="${parsed}"
		fi
	fi
	rm -f "${items_file}" "${names_seen_file}"
	printf '%s' "${items_json}"
}

mcp_resources_templates_refresh_registry() {
	local scan_root
	scan_root="$(mcp_resources_scan_root)"
	mcp_resources_templates_init

	local resources_available=true
	if [ -z "${MCP_RESOURCES_REGISTRY_JSON}" ]; then
		if ! mcp_resources_refresh_registry 2>/dev/null; then
			resources_available=false
		fi
		if [ -z "${MCP_RESOURCES_REGISTRY_JSON}" ]; then
			resources_available=false
		fi
	fi
	if [ "${resources_available}" = false ]; then
		mcp_logging_warning "${MCP_RESOURCES_TEMPLATES_LOGGER}" "Cannot check for name collisions: resource registry unavailable"
	fi

	local manual_status=0
	mcp_registry_register_apply "resourceTemplates"
	manual_status=$?
	if [ "${manual_status}" -eq 2 ]; then
		local err
		err="$(mcp_registry_register_error_for_kind "resourceTemplates")"
		if [ -z "${err}" ]; then
			err="Manual registration script returned empty output or non-zero"
		fi
		mcp_logging_error "${MCP_RESOURCES_TEMPLATES_LOGGER}" "${err}"
		return 1
	fi

	local now ttl
	now="$(date +%s)"
	ttl="${MCP_RESOURCES_TEMPLATES_TTL:-5}"
	case "${ttl}" in
	'' | *[!0-9]*) ttl=5 ;;
	0) ttl=5 ;;
	esac

	if [ -z "${MCP_RESOURCES_TEMPLATES_REGISTRY_JSON}" ] && [ -f "${MCP_RESOURCES_TEMPLATES_REGISTRY_PATH}" ]; then
		local tmp_json=""
		if tmp_json="$(cat "${MCP_RESOURCES_TEMPLATES_REGISTRY_PATH}")"; then
			if echo "${tmp_json}" | "${MCPBASH_JSON_TOOL_BIN}" . >/dev/null 2>&1; then
				MCP_RESOURCES_TEMPLATES_REGISTRY_JSON="${tmp_json}"
				MCP_RESOURCES_TEMPLATES_REGISTRY_HASH="$(echo "${tmp_json}" | "${MCPBASH_JSON_TOOL_BIN}" -r '.hash // empty')"
				MCP_RESOURCES_TEMPLATES_TOTAL="$(echo "${tmp_json}" | "${MCPBASH_JSON_TOOL_BIN}" '.total // 0')"
				if ! mcp_resources_templates_enforce_registry_limits "${MCP_RESOURCES_TEMPLATES_TOTAL}" "${MCP_RESOURCES_TEMPLATES_REGISTRY_JSON}"; then
					return 1
				fi
			else
				mcp_logging_warning "${MCP_RESOURCES_TEMPLATES_LOGGER}" "Discarding invalid resource templates registry cache"
				MCP_RESOURCES_TEMPLATES_REGISTRY_JSON=""
			fi
		else
			if mcp_logging_verbose_enabled; then
				mcp_logging_warning "${MCP_RESOURCES_TEMPLATES_LOGGER}" "Failed to read resource templates registry cache ${MCP_RESOURCES_TEMPLATES_REGISTRY_PATH}"
			else
				mcp_logging_warning "${MCP_RESOURCES_TEMPLATES_LOGGER}" "Failed to read resource templates registry cache"
			fi
			MCP_RESOURCES_TEMPLATES_REGISTRY_JSON=""
		fi
	fi

	if [ "${MCP_RESOURCES_TEMPLATES_MANUAL_UPDATED}" != "true" ] && [ -n "${MCP_RESOURCES_TEMPLATES_REGISTRY_JSON}" ] && [ $((now - MCP_RESOURCES_TEMPLATES_LAST_SCAN)) -lt "${ttl}" ]; then
		return 0
	fi

	local resource_names_file
	resource_names_file="$(mktemp "${MCPBASH_TMP_ROOT}/mcp-resource-template-resources.XXXXXX")"
	if [ "${resources_available}" = true ] && [ -n "${MCP_RESOURCES_REGISTRY_JSON}" ]; then
		printf '%s' "${MCP_RESOURCES_REGISTRY_JSON}" | "${MCPBASH_JSON_TOOL_BIN}" -r '.items[].name // empty' >"${resource_names_file}"
	fi
	mcp_resources_templates_collect_resource_names "${scan_root}" "${resource_names_file}"

	local auto_items_json manual_items_json merged_items_json
	auto_items_json="$(mcp_resources_templates_scan "${scan_root}" "${resource_names_file}")"
	manual_items_json="${MCP_RESOURCES_TEMPLATES_MANUAL_JSON:-[]}"
	if [ -z "${manual_items_json}" ]; then
		manual_items_json="[]"
	fi

	if [ -n "${resource_names_file}" ] && [ -f "${resource_names_file}" ] && [ -s "${resource_names_file}" ]; then
		local manual_filtered_file
		manual_filtered_file="$(mktemp "${MCPBASH_TMP_ROOT}/mcp-resource-template-manual-filtered.XXXXXX")"
		while IFS= read -r manual_item; do
			[ -z "${manual_item}" ] && continue
			local manual_name
			manual_name="$(printf '%s' "${manual_item}" | "${MCPBASH_JSON_TOOL_BIN}" -r '.name // empty' 2>/dev/null || printf '')"
			if [ -z "${manual_name}" ]; then
				continue
			fi
			if grep -Fxq "${manual_name}" "${resource_names_file}"; then
				mcp_logging_warning "${MCP_RESOURCES_TEMPLATES_LOGGER}" "Manual template name conflicts with existing resource '${manual_name}', skipping"
				continue
			fi
			printf '%s\n' "${manual_item}" >>"${manual_filtered_file}"
		done < <(printf '%s' "${manual_items_json}" | "${MCPBASH_JSON_TOOL_BIN}" -c '.[] // empty' 2>/dev/null)
		if [ -s "${manual_filtered_file}" ]; then
			local parsed
			if parsed="$("${MCPBASH_JSON_TOOL_BIN}" -s 'sort_by(.name)' "${manual_filtered_file}" 2>/dev/null)"; then
				manual_items_json="${parsed}"
			else
				manual_items_json="[]"
			fi
		else
			manual_items_json="[]"
		fi
		rm -f "${manual_filtered_file}"
	fi

	if [ -n "${resource_names_file}" ]; then
		rm -f "${resource_names_file}"
	fi

	local auto_names_file
	auto_names_file="$(mktemp "${MCPBASH_TMP_ROOT}/mcp-resource-template-auto-names.XXXXXX")"
	# Guard against null/empty: use (. // []) to ensure we iterate over an array
	printf '%s' "${auto_items_json}" | "${MCPBASH_JSON_TOOL_BIN}" -r '(. // []) | .[].name // empty' >"${auto_names_file}" 2>/dev/null || true
	while IFS= read -r manual_name; do
		[ -z "${manual_name}" ] && continue
		if [ -s "${auto_names_file}" ] && grep -Fxq "${manual_name}" "${auto_names_file}"; then
			mcp_logging_info "${MCP_RESOURCES_TEMPLATES_LOGGER}" "Manual template overrides auto-discovered template '${manual_name}'"
		fi
	done < <(printf '%s' "${manual_items_json}" | "${MCPBASH_JSON_TOOL_BIN}" -r '(. // []) | .[].name // empty' 2>/dev/null)
	rm -f "${auto_names_file}"

	merged_items_json="$("${MCPBASH_JSON_TOOL_BIN}" -n -c \
		--argjson auto "${auto_items_json:-[]}" \
		--argjson manual "${manual_items_json:-[]}" '
			($auto // []) as $a |
			($manual // []) as $m |
			($a | reduce .[] as $item ({}; .[$item.name] = $item)) as $auto_map |
			($m | reduce .[] as $item ($auto_map; .[$item.name] = $item)) as $merged |
			($merged | to_entries | sort_by(.key) | map(.value))
		')"

	local timestamp hash total
	timestamp="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
	hash="$(mcp_hash_string "${merged_items_json}")"
	total="$(printf '%s' "${merged_items_json}" | "${MCPBASH_JSON_TOOL_BIN}" 'length')"

	local previous_hash="${MCP_RESOURCES_TEMPLATES_REGISTRY_HASH}"
	MCP_RESOURCES_TEMPLATES_REGISTRY_JSON="$("${MCPBASH_JSON_TOOL_BIN}" -n \
		--arg ver "1" \
		--arg ts "${timestamp}" \
		--arg hash "${hash}" \
		--argjson items "${merged_items_json}" \
		--argjson total "${total}" \
		'{version: $ver|tonumber, generatedAt: $ts, items: $items, hash: $hash, total: $total}')"

	MCP_RESOURCES_TEMPLATES_REGISTRY_HASH="${hash}"
	MCP_RESOURCES_TEMPLATES_TOTAL="${total}"

	if ! mcp_resources_templates_enforce_registry_limits "${MCP_RESOURCES_TEMPLATES_TOTAL}" "${MCP_RESOURCES_TEMPLATES_REGISTRY_JSON}"; then
		return 1
	fi

	MCP_RESOURCES_TEMPLATES_LAST_SCAN="${now}"
	MCP_RESOURCES_TEMPLATES_MANUAL_UPDATED=false
	local fastpath_snapshot
	fastpath_snapshot="$(mcp_registry_fastpath_snapshot "${scan_root}")"
	mcp_registry_fastpath_store "resourceTemplates" "${fastpath_snapshot}" || true

	local write_rc=0
	mcp_registry_write_with_lock "${MCP_RESOURCES_TEMPLATES_REGISTRY_PATH}" "${MCP_RESOURCES_TEMPLATES_REGISTRY_JSON}" || write_rc=$?
	if [ "${write_rc}" -ne 0 ]; then
		return "${write_rc}"
	fi

	if [ "${previous_hash}" != "${MCP_RESOURCES_TEMPLATES_REGISTRY_HASH}" ]; then
		MCP_RESOURCES_CHANGED=true
	fi
}

mcp_resources_templates_list() {
	local limit="$1"
	local cursor="$2"
	# shellcheck disable=SC2034
	_MCP_RESOURCES_ERR_CODE=0
	# shellcheck disable=SC2034
	_MCP_RESOURCES_ERR_MESSAGE=""

	mcp_resources_templates_refresh_registry || {
		mcp_resources_error -32603 "Unable to load resource templates registry"
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

	local registry_hash="${MCP_RESOURCES_TEMPLATES_REGISTRY_HASH}"
	if [ -z "${registry_hash}" ] && [ -n "${MCP_RESOURCES_TEMPLATES_REGISTRY_JSON}" ]; then
		registry_hash="$(printf '%s' "${MCP_RESOURCES_TEMPLATES_REGISTRY_JSON}" | "${MCPBASH_JSON_TOOL_BIN}" -r '.hash // empty' 2>/dev/null || printf '')"
	fi

	local offset=0
	if [ -n "${cursor}" ] && [ -z "${registry_hash}" ]; then
		mcp_resources_error -32602 "Invalid cursor"
		return 1
	fi
	if [ -n "${cursor}" ]; then
		local decode_status=0
		local cursor_hash=""
		if ! cursor_hash="$(mcp_paginate_base64_urldecode "${cursor}" | "${MCPBASH_JSON_TOOL_BIN}" -r '.hash // empty' 2>/dev/null)"; then
			mcp_resources_error -32602 "Invalid cursor"
			return 1
		fi
		if [ -n "${registry_hash}" ] && [ "${cursor_hash}" != "${registry_hash}" ]; then
			mcp_resources_error -32602 "Invalid cursor"
			return 1
		fi
		offset="$(mcp_paginate_decode "${cursor}" "resourceTemplates" "${registry_hash}")" || decode_status=$?
		if [ "${decode_status}" -ne 0 ]; then
			mcp_resources_error -32602 "Invalid cursor"
			return 1
		fi
	fi

	local total="${MCP_RESOURCES_TEMPLATES_TOTAL}"
	local result_json
	result_json="$(echo "${MCP_RESOURCES_TEMPLATES_REGISTRY_JSON}" | "${MCPBASH_JSON_TOOL_BIN}" -c --argjson offset "$offset" --argjson limit "$numeric_limit" --argjson total "${total}" '
		{
			resourceTemplates: .items[$offset:$offset+$limit],
			_meta: {total: $total}
		}
	')"

	if ! result_json="$(mcp_paginate_attach_next_cursor "${result_json}" "resourceTemplates" "${offset}" "${numeric_limit}" "${total}" "${registry_hash}")"; then
		mcp_resources_error -32603 "Unable to encode resource template cursor"
		return 1
	fi

	printf '%s' "${result_json}"
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
	local script="${MCPBASH_HOME}/providers/file.sh"
	local tmp_err
	tmp_err="$(mktemp "${MCPBASH_TMP_ROOT}/mcp-resource-file.XXXXXX")"
	local output status
	if output="$(
		env \
			MCPBASH_HOME="${MCPBASH_HOME}" \
			MCP_RESOURCES_ROOTS="${MCP_RESOURCES_ROOTS:-${MCPBASH_RESOURCES_DIR}}" \
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
		mcp_resources_error -32602 "Resource not found"
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
	local script="${MCPBASH_HOME}/providers/${provider}.sh"
	# On Windows (Git Bash/MSYS), -x test is unreliable. If the provider script
	# exists but isn't executable, fall back to invoking it via bash when it looks
	# like a script (shebang or .sh/.bash extension).
	local provider_runner=("${script}")
	if [ ! -x "${script}" ]; then
		if [ -f "${script}" ]; then
			local first_line=""
			IFS= read -r first_line <"${script}" 2>/dev/null || first_line=""
			case "${script}" in
			*.sh | *.bash)
				provider_runner=(bash "${script}")
				;;
			*)
				case "${first_line}" in
				'#!'*)
					provider_runner=(bash "${script}")
					;;
				*)
					provider_runner=()
					;;
				esac
				;;
			esac
		else
			provider_runner=()
		fi
	fi

	if [ "${#provider_runner[@]}" -gt 0 ]; then
		local tmp_err
		tmp_err="$(mktemp "${MCPBASH_TMP_ROOT}/mcp-resource-provider.XXXXXX")"
		local output status
		if output="$(
			env \
				MCPBASH_HOME="${MCPBASH_HOME}" \
				MCP_RESOURCES_ROOTS="${MCP_RESOURCES_ROOTS:-${MCPBASH_RESOURCES_DIR}}" \
				"${provider_runner[@]}" "${uri}" 2>"${tmp_err}"
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
			mcp_resources_error -32602 "Resource not found"
			;;
		4)
			mcp_resources_error -32602 "${message:-Invalid resource specification}"
			;;
		5)
			mcp_resources_error -32603 "${message:-Resource fetch failed}"
			;;
		6)
			mcp_resources_error -32603 "${message:-Resource exceeded size limit}"
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
	# shellcheck disable=SC2034
	_MCP_RESOURCES_RESULT=""
	# shellcheck disable=SC2034
	_MCP_RESOURCES_ERR_CODE=0
	# shellcheck disable=SC2034
	_MCP_RESOURCES_ERR_MESSAGE=""
	mcp_resources_refresh_registry || {
		mcp_resources_error -32603 "Unable to load resources registry"
		return 1
	}
	local metadata
	metadata="$(mcp_resources_metadata_for_name "${name}" 2>/dev/null || echo "{}")"
	if [ -z "${metadata}" ] || [ "${metadata}" = "{}" ]; then
		if [ -z "${explicit_uri}" ]; then
			mcp_resources_error -32602 "Resource not found"
			return 1
		fi
		metadata='{}'
	fi

	if mcp_logging_is_enabled "debug"; then
		if mcp_logging_verbose_enabled; then
			mcp_logging_debug "${MCP_RESOURCES_LOGGER}" "Metadata resolved for name=${name:-<direct>} uri=${explicit_uri}"
		else
			local uri_scheme="${explicit_uri%%:*}"
			mcp_logging_debug "${MCP_RESOURCES_LOGGER}" "Metadata resolved for name=${name:-<direct>} scheme=${uri_scheme}"
		fi
	fi

	local uri provider mime
	uri="$(echo "${metadata}" | "${MCPBASH_JSON_TOOL_BIN}" -r --arg explicit "${explicit_uri}" 'if $explicit != "" then $explicit else .uri // "" end')"
	provider="$(echo "${metadata}" | "${MCPBASH_JSON_TOOL_BIN}" -r '.provider // "file"')"
	mime="$(echo "${metadata}" | "${MCPBASH_JSON_TOOL_BIN}" -r '.mimeType // "text/plain"')"

	if [ -z "${uri}" ]; then
		mcp_resources_error -32602 "Resource URI missing"
		return 1
	fi
	if [ -z "${provider}" ] || { [ "${provider}" != "file" ] && [ "${provider}" != "https" ] && [ "${provider}" != "git" ]; }; then
		local inferred
		inferred="$(mcp_resources_provider_from_uri "${uri}")"
		if [ -n "${inferred}" ]; then
			provider="${inferred}"
		else
			provider="file"
		fi
	fi
	if mcp_logging_is_enabled "debug"; then
		if mcp_logging_verbose_enabled; then
			mcp_logging_debug "${MCP_RESOURCES_LOGGER}" "Reading provider=${provider} uri=${uri}"
		else
			mcp_logging_debug "${MCP_RESOURCES_LOGGER}" "Reading provider=${provider}"
		fi
	fi
	local content_file
	content_file="$(mktemp "${MCPBASH_TMP_ROOT}/mcp-resource-read.XXXXXX")"
	if ! mcp_resources_read_via_provider "${provider}" "${uri}" >"${content_file}"; then
		rm -f "${content_file}"
		return 1
	fi
	local content_size
	content_size="$(wc -c <"${content_file}" | tr -d ' ')"
	mcp_logging_debug "${MCP_RESOURCES_LOGGER}" "Provider returned ${content_size} bytes"
	local limit="${MCPBASH_MAX_RESOURCE_BYTES:-${MCPBASH_MAX_TOOL_OUTPUT_SIZE:-10485760}}"
	case "${limit}" in
	'' | *[!0-9]*) limit=10485760 ;;
	esac
	if [ "${content_size}" -gt "${limit}" ]; then
		mcp_logging_error "${MCP_RESOURCES_LOGGER}" "Resource ${name:-<direct>} content ${content_size} bytes exceeds limit ${limit}" || true
		mcp_resources_error -32603 "Resource content exceeds ${limit} bytes"
		rm -f "${content_file}"
		return 1
	fi
	local result
	local content_obj
	if ! content_obj="$(mcp_resource_content_object_from_file "${content_file}" "${mime}" "${uri}")"; then
		rm -f "${content_file}"
		mcp_resources_error -32603 "Unable to encode resource content"
		return 1
	fi
	result="$("${MCPBASH_JSON_TOOL_BIN}" -n -c --argjson content "${content_obj}" '{
		contents: [$content]
	}')" || result=""
	rm -f "${content_file}"
	if [ -z "${result}" ]; then
		mcp_resources_error -32603 "Unable to encode resource content"
		return 1
	fi
	_MCP_RESOURCES_RESULT="${result}"
}
