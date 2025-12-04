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

if ! command -v mcp_uri_file_uri_from_path >/dev/null 2>&1; then
	# shellcheck disable=SC1090
	. "${MCPBASH_HOME:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}/lib/uri.sh"
fi

if ! command -v mcp_registry_resolve_scan_root >/dev/null 2>&1; then
	# shellcheck disable=SC1090
	. "${MCPBASH_HOME:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}/lib/registry.sh"
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
			path: (.path // "")
		}) |
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
	local params
	if ! params="$("${MCPBASH_JSON_TOOL_BIN}" -n -c \
		--arg sub "${subscription_id}" \
		--arg uri "${uri}" \
		--argjson resource "${payload}" '{
			subscriptionId: $sub,
			subscription: {id: $sub, uri: $uri},
			resource: $resource
		}' 2>/dev/null)"; then
		params="$("${MCPBASH_JSON_TOOL_BIN}" -n -c --arg sub "${subscription_id}" --arg uri "${uri}" '{
			subscriptionId: $sub,
			subscription: {id: $sub, uri: $uri},
			resource: {contents: []}
		}')" || params='{"subscriptionId":""}'
	fi
	rpc_send_line_direct "$("${MCPBASH_JSON_TOOL_BIN}" -n -c --argjson params "${params}" '{"jsonrpc":"2.0","method":"notifications/resources/updated","params":$params}')"
}

mcp_resources_emit_error() {
	local subscription_id="$1"
	local code="$2"
	local message="$3"
	local uri="${4:-}"
	local payload
	if [ -z "${uri}" ]; then
		uri=""
	fi
	payload="$("${MCPBASH_JSON_TOOL_BIN}" -n -c \
		--arg sub "${subscription_id}" \
		--arg uri "${uri}" \
		--argjson code "${code}" \
		--arg msg "${message}" '{
			subscriptionId: $sub,
			subscription: {id: $sub, uri: $uri},
			error: {code: $code, message: $msg}
		}')"
	rpc_send_line_direct "$("${MCPBASH_JSON_TOOL_BIN}" -n -c --argjson params "${payload}" '{"jsonrpc":"2.0","method":"notifications/resources/updated","params":$params}')"
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
	if mcp_registry_register_apply "resources"; then
		mcp_logging_debug "${MCP_RESOURCES_LOGGER}" "Refresh satisfied by manual script"
		return 0
	else
		local manual_status=$?
		if [ "${manual_status}" -eq 2 ]; then
			local err
			err="$(mcp_registry_register_error_for_kind "resources")"
			if [ -z "${err}" ]; then
				err="Manual registration script returned empty output or non-zero"
			fi
			mcp_logging_error "${MCP_RESOURCES_LOGGER}" "${err}"
			return 1
		fi
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

			if [ -f "${meta_json}" ]; then
				local meta
				meta="$(cat "${meta_json}")"
				local j_name
				j_name="$(printf '%s' "${meta}" | "${MCPBASH_JSON_TOOL_BIN}" -r '.name // empty' 2>/dev/null)"
				[ -n "${j_name}" ] && name="${j_name}"
				description="$(printf '%s' "${meta}" | "${MCPBASH_JSON_TOOL_BIN}" -r '.description // empty' 2>/dev/null)"
				uri="$(printf '%s' "${meta}" | "${MCPBASH_JSON_TOOL_BIN}" -r '.uri // empty' 2>/dev/null)"
				mime="$(printf '%s' "${meta}" | "${MCPBASH_JSON_TOOL_BIN}" -r '.mimeType // "text/plain"' 2>/dev/null)"
				provider="$(printf '%s' "${meta}" | "${MCPBASH_JSON_TOOL_BIN}" -r '.provider // empty' 2>/dev/null)"
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

			"${MCPBASH_JSON_TOOL_BIN}" -n \
				--arg name "$name" \
				--arg desc "$description" \
				--arg path "$rel_path" \
				--arg uri "$uri" \
				--arg mime "$mime" \
				--arg provider "$provider" \
				'{name: $name, description: $desc, path: $path, uri: $uri, mimeType: $mime, provider: $provider}' >>"${items_file}"
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
		items_json="$("${MCPBASH_JSON_TOOL_BIN}" -s '.' "${items_file}")"
	fi
	rm -f "${items_file}" "${names_seen_file}"

	local hash
	hash="$(mcp_resources_hash_payload "${items_json}")"
	local total
	total="$(printf '%s' "${items_json}" | "${MCPBASH_JSON_TOOL_BIN}" 'length')"

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
	if ! offset="$(mcp_paginate_decode "${cursor}" "resources" "${hash}")"; then
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
	# Like tools/list, this result includes a `total` field as an allowed
	# extension. The MCP ListResourcesResult schema permits additional
	# properties, so clients that do not care about the count can ignore it.
	result_json="$(echo "${MCP_RESOURCES_REGISTRY_JSON}" | "${MCPBASH_JSON_TOOL_BIN}" -c --argjson offset "$offset" --argjson limit "$numeric_limit" --argjson total "${total}" '
		{
			resources: .items[$offset:$offset+$limit],
			total: $total
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

mcp_resources_templates_list() {
	local limit="$1"
	local cursor="$2"
	# shellcheck disable=SC2034
	_MCP_RESOURCES_ERR_CODE=0
	# shellcheck disable=SC2034
	_MCP_RESOURCES_ERR_MESSAGE=""
	# For now, no templates are discovered; return an empty, paginated-compliant payload.

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

	local hash="resource-templates-v1"
	local offset=0
	if [ -n "${cursor}" ]; then
		if ! offset="$(mcp_paginate_decode "${cursor}" "resourceTemplates" "${hash}")"; then
			mcp_resources_error -32602 "Invalid cursor"
			return 1
		fi
	fi

	local result_json
	result_json="$("${MCPBASH_JSON_TOOL_BIN}" -n -c '{resourceTemplates: [], total: 0}')"

	if ! result_json="$(mcp_paginate_attach_next_cursor "${result_json}" "resourceTemplates" "${offset}" "${numeric_limit}" 0 "${hash}")"; then
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
	local script="${MCPBASH_HOME}/providers/${provider}.sh"
	if [ -x "${script}" ]; then
		local tmp_err
		tmp_err="$(mktemp "${MCPBASH_TMP_ROOT}/mcp-resource-provider.XXXXXX")"
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
			mcp_resources_error -32601 "Resource not found"
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
			mcp_resources_error -32601 "Resource not found"
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
	local content
	if ! content="$(mcp_resources_read_via_provider "${provider}" "${uri}")"; then
		return 1
	fi
	mcp_logging_debug "${MCP_RESOURCES_LOGGER}" "Provider returned ${#content} bytes"
	local limit="${MCPBASH_MAX_RESOURCE_BYTES:-${MCPBASH_MAX_TOOL_OUTPUT_SIZE:-10485760}}"
	case "${limit}" in
	'' | *[!0-9]*) limit=10485760 ;;
	esac
	local content_size
	content_size="$(LC_ALL=C printf '%s' "${content}" | wc -c | tr -d ' ')"
	if [ "${content_size}" -gt "${limit}" ]; then
		mcp_logging_error "${MCP_RESOURCES_LOGGER}" "Resource ${name:-<direct>} content ${content_size} bytes exceeds limit ${limit}" || true
		mcp_resources_error -32603 "Resource content exceeds ${limit} bytes"
		return 1
	fi
	local result
	result="$("${MCPBASH_JSON_TOOL_BIN}" -n -c --arg uri "${uri}" --arg mime "${mime}" --arg content "${content}" '{
		contents: [
			{
				uri: $uri,
				mimeType: $mime,
				text: $content
			}
		]
	}')"
	_MCP_RESOURCES_RESULT="${result}"
}
