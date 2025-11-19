#!/usr/bin/env bash
# Resource discovery and providers.

set -euo pipefail

MCP_RESOURCES_REGISTRY_JSON=""
MCP_RESOURCES_REGISTRY_HASH=""
MCP_RESOURCES_REGISTRY_PATH=""
# shellcheck disable=SC2034
MCP_RESOURCES_TOTAL=0
# shellcheck disable=SC2034
MCP_RESOURCES_ERR_CODE=0
# shellcheck disable=SC2034
MCP_RESOURCES_ERR_MESSAGE=""
MCP_RESOURCES_TTL="${MCP_RESOURCES_TTL:-5}"
MCP_RESOURCES_LAST_SCAN=0
MCP_RESOURCES_CHANGED=false
MCP_RESOURCES_MANUAL_ACTIVE=false
MCP_RESOURCES_MANUAL_BUFFER=""
MCP_RESOURCES_MANUAL_DELIM=$'\036'
MCP_RESOURCES_LOGGER="${MCP_RESOURCES_LOGGER:-mcp.resources}"


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
	if ! registry_json="$(printf '%s' "${MCP_RESOURCES_MANUAL_BUFFER}" | awk -v RS='\036' '{if ($0 != "") print $0}' | jq -s '
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
	items_json="$(echo "${registry_json}" | jq -c '.items')"
	local hash
	hash="$(mcp_resources_hash_payload "${items_json}")"
	local total
	total="$(echo "${registry_json}" | jq '.total')"

	# Update hash
	registry_json="$(echo "${registry_json}" | jq --arg hash "${hash}" '.hash = $hash')"

	local previous_hash="${MCP_RESOURCES_REGISTRY_HASH}"
	MCP_RESOURCES_REGISTRY_JSON="${registry_json}"
	MCP_RESOURCES_REGISTRY_HASH="${hash}"
	MCP_RESOURCES_TOTAL="${total}"

	if ! mcp_resources_enforce_registry_limits "${MCP_RESOURCES_TOTAL}" "${registry_json}"; then
		mcp_resources_manual_abort
		return 1
	fi

	MCP_RESOURCES_LAST_SCAN="$(date +%s)"
	if [ "${previous_hash}" != "${MCP_RESOURCES_REGISTRY_HASH}" ]; then
		MCP_RESOURCES_CHANGED=true
	fi
	printf '%s' "${registry_json}" >"${MCP_RESOURCES_REGISTRY_PATH}"
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
	if command -v sha256sum >/dev/null 2>&1; then
		printf '%s' "${payload}" | sha256sum | awk '{print $1}'
		return
	fi
	if command -v shasum >/dev/null 2>&1; then
		printf '%s' "${payload}" | shasum -a 256 | awk '{print $1}'
		return
	fi
	printf '%s' "${payload}" | cksum | awk '{print $1}'
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
	local enriched
	enriched="$(echo "${payload}" | jq -c --arg sub "${subscription_id}" '. + {subscriptionId: $sub}')"
	rpc_send_line_direct "$(jq -n --argjson params "${enriched}" '{"jsonrpc":"2.0","method":"notifications/resources/updated","params":$params}')"
}

mcp_resources_emit_error() {
	local subscription_id="$1"
	local code="$2"
	local message="$3"
	local payload
	payload="$(jq -n --arg sub "${subscription_id}" --argjson code "${code}" --arg msg "${message}" '{
		subscriptionId: $sub,
		error: {code: $code, message: $msg}
	}')"
	rpc_send_line_direct "$(jq -n --argjson params "${payload}" '{"jsonrpc":"2.0","method":"notifications/resources/updated","params":$params}')"
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
		if result="$(mcp_resources_read "${name}" "${uri}")"; then
			local new_fingerprint
			new_fingerprint="$(mcp_resources_hash_payload "${result}")"
			if [ "${new_fingerprint}" != "${fingerprint}" ]; then
				mcp_resources_subscription_store "${subscription_id}" "${name}" "${uri}" "${new_fingerprint}"
				mcp_resources_emit_update "${subscription_id}" "${result}"
			fi
		else
			local code message error_fingerprint
			code="${MCP_RESOURCES_ERR_CODE:- -32603}"
			message="${MCP_RESOURCES_ERR_MESSAGE:-Unable to read resource}"
			error_fingerprint="ERROR:${code}:$(mcp_resources_hash_payload "${message}")"
			if [ "${error_fingerprint}" != "${fingerprint}" ]; then
				mcp_resources_subscription_store "${subscription_id}" "${name}" "${uri}" "${error_fingerprint}"
				mcp_resources_emit_error "${subscription_id}" "${code}" "${message}"
			fi
		fi
	done
}
mcp_resources_registry_max_bytes() {
	local limit="${MCPBASH_REGISTRY_MAX_BYTES:-104857600}"
	case "${limit}" in
	'' | *[!0-9]*) limit=104857600 ;;
	esac
	printf '%s' "${limit}"
}

mcp_resources_enforce_registry_limits() {
	local total="$1"
	local json_payload="$2"
	local limit
	local size
	limit="$(mcp_resources_registry_max_bytes)"
	size="$(LC_ALL=C printf '%s' "${json_payload}" | wc -c | tr -d ' ')"
	if [ "${size}" -gt "${limit}" ]; then
		mcp_resources_error -32603 "Resources registry exceeds ${limit} byte cap"
		return 1
	fi
	if [ "${total}" -gt 500 ]; then
		mcp_logging_warning "${MCP_RESOURCES_LOGGER}" "Resources registry contains ${total} entries; consider manual registration"
	fi
	return 0
}

mcp_resources_error() {
	MCP_RESOURCES_ERR_CODE="$1"
	MCP_RESOURCES_ERR_MESSAGE="$2"
}


mcp_resources_init() {
	if [ -z "${MCP_RESOURCES_REGISTRY_PATH}" ]; then
		MCP_RESOURCES_REGISTRY_PATH="${MCPBASH_REGISTRY_DIR}/resources.json"
	fi
	mkdir -p "${MCPBASH_REGISTRY_DIR}"
	mkdir -p "${MCPBASH_ROOT}/resources" >/dev/null 2>&1 || true
}

mcp_resources_apply_manual_json() {
	local manual_json="$1"
	local registry_json

	# Basic validation of input structure
	if ! echo "${manual_json}" | jq -e '.resources | type == "array"' >/dev/null 2>&1; then
		# If not present or not array, treat as empty
		manual_json='{"resources":[]}'
	fi

	local timestamp
	timestamp="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

	# Construct registry structure
	registry_json="$(echo "${manual_json}" | jq --arg ts "${timestamp}" '{
		version: 1,
		generatedAt: $ts,
		items: .resources,
		total: (.resources | length)
	}')"

	# Calculate hash of items
	local items_json
	items_json="$(echo "${registry_json}" | jq -c '.items')"
	local hash
	hash="$(mcp_resources_hash_payload "${items_json}")"

	# Add hash to registry
	registry_json="$(echo "${registry_json}" | jq --arg hash "${hash}" '.hash = $hash')"

	local new_hash="${hash}"
	if [ "${new_hash}" != "${MCP_RESOURCES_REGISTRY_HASH}" ]; then
		MCP_RESOURCES_CHANGED=true
	fi
	MCP_RESOURCES_REGISTRY_JSON="${registry_json}"
	MCP_RESOURCES_REGISTRY_HASH="${new_hash}"
	MCP_RESOURCES_TOTAL="$(echo "${registry_json}" | jq '.total')"

	if ! mcp_resources_enforce_registry_limits "${MCP_RESOURCES_TOTAL}" "${registry_json}"; then
		return 1
	fi
	MCP_RESOURCES_LAST_SCAN="$(date +%s)"
	printf '%s' "${registry_json}" >"${MCP_RESOURCES_REGISTRY_PATH}"
}

mcp_resources_run_manual_script() {
	if [ ! -x "${MCPBASH_REGISTER_SCRIPT}" ]; then
		return 1
	fi

	mcp_resources_manual_begin

	local script_output_file
	script_output_file="$(mktemp "${MCPBASH_TMP_ROOT}/mcp-resources-manual-output.XXXXXX")"
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
		mcp_resources_manual_abort
		mcp_resources_error -32603 "Manual registration script failed"
		if [ -n "${script_output}" ]; then
			mcp_logging_error "${MCP_RESOURCES_LOGGER}" "Manual registration script output: ${script_output}"
		fi
		return 1
	fi

	if [ -z "${MCP_RESOURCES_MANUAL_BUFFER}" ] && [ -n "${script_output}" ]; then
		mcp_resources_manual_abort
		if ! mcp_resources_apply_manual_json "${script_output}"; then
			return 1
		fi
		return 0
	fi

	if [ -n "${script_output}" ]; then
		mcp_logging_warning "${MCP_RESOURCES_LOGGER}" "Manual registration script output: ${script_output}"
	fi

	if ! mcp_resources_manual_finalize; then
		return 1
	fi
	return 0
}

mcp_resources_refresh_registry() {
	mcp_resources_init
	mcp_logging_debug "${MCP_RESOURCES_LOGGER}" "Refresh start register=${MCPBASH_REGISTER_SCRIPT} exists=$([[ -x ${MCPBASH_REGISTER_SCRIPT} ]] && echo yes || echo no) ttl=${MCP_RESOURCES_TTL:-5}"
	if [ -x "${MCPBASH_REGISTER_SCRIPT}" ]; then
		mcp_logging_debug "${MCP_RESOURCES_LOGGER}" "Invoking manual registration script"
		if mcp_resources_run_manual_script; then
			mcp_logging_debug "${MCP_RESOURCES_LOGGER}" "Refresh satisfied by manual script"
			return 0
		fi
		mcp_logging_error "${MCP_RESOURCES_LOGGER}" "Manual registration script returned empty output or non-zero"
		return 1
	fi
	local now
	now="$(date +%s)"

	if [ -z "${MCP_RESOURCES_REGISTRY_JSON}" ] && [ -f "${MCP_RESOURCES_REGISTRY_PATH}" ]; then
		MCP_RESOURCES_REGISTRY_JSON="$(cat "${MCP_RESOURCES_REGISTRY_PATH}")"
		# Validate and extract meta
		if echo "${MCP_RESOURCES_REGISTRY_JSON}" | jq . >/dev/null 2>&1; then
			MCP_RESOURCES_REGISTRY_HASH="$(echo "${MCP_RESOURCES_REGISTRY_JSON}" | jq -r '.hash // empty')"
			MCP_RESOURCES_TOTAL="$(echo "${MCP_RESOURCES_REGISTRY_JSON}" | jq '.total // 0')"
			if ! mcp_resources_enforce_registry_limits "${MCP_RESOURCES_TOTAL}" "${MCP_RESOURCES_REGISTRY_JSON}"; then
				return 1
			fi
		else
			# Corrupt cache, ignore
			MCP_RESOURCES_REGISTRY_JSON=""
		fi
	fi
	if [ -n "${MCP_RESOURCES_REGISTRY_JSON}" ] && [ $((now - MCP_RESOURCES_LAST_SCAN)) -lt "${MCP_RESOURCES_TTL}" ]; then
		mcp_logging_debug "${MCP_RESOURCES_LOGGER}" "Refresh skipped due to ttl (last=${MCP_RESOURCES_LAST_SCAN})"
		return 0
	fi
	local previous_hash="${MCP_RESOURCES_REGISTRY_HASH}"
	mcp_resources_scan || return 1
	MCP_RESOURCES_LAST_SCAN="${now}"
	mcp_logging_debug "${MCP_RESOURCES_LOGGER}" "Refresh completed scan hash=${MCP_RESOURCES_REGISTRY_HASH}"
	if [ "${previous_hash}" != "${MCP_RESOURCES_REGISTRY_HASH}" ]; then
		MCP_RESOURCES_CHANGED=true
	fi
}

mcp_resources_scan() {
	local resources_dir="${MCPBASH_ROOT}/resources"
	local items_file
	items_file="$(mktemp "${MCPBASH_TMP_ROOT}/mcp-resources-items.XXXXXX")"

	if [ -d "${resources_dir}" ]; then
		find "${resources_dir}" -type f ! -name ".*" ! -name "*.meta.json" 2>/dev/null | sort | while read -r path; do
			local rel_path="${path#${MCPBASH_ROOT}/}"
			local base_name="$(basename "${path}")"
			local name="${base_name%.*}"
			local dir_name="$(dirname "${path}")"
			local meta_json="${dir_name}/${base_name}.meta.json"
			local description=""
			local uri=""
			local mime="text/plain"
			local provider=""

			if [ -f "${meta_json}" ]; then
				local meta
				meta="$(cat "${meta_json}")"
				local j_name
				j_name="$(printf '%s' "${meta}" | jq -r '.name // empty' 2>/dev/null)"
				[ -n "${j_name}" ] && name="${j_name}"
				description="$(printf '%s' "${meta}" | jq -r '.description // empty' 2>/dev/null)"
				uri="$(printf '%s' "${meta}" | jq -r '.uri // empty' 2>/dev/null)"
				mime="$(printf '%s' "${meta}" | jq -r '.mimeType // "text/plain"' 2>/dev/null)"
				provider="$(printf '%s' "${meta}" | jq -r '.provider // empty' 2>/dev/null)"
			fi

			if [ -z "${uri}" ]; then
				local header
				header="$(head -n 10 "${path}")"
				local mcp_line
				mcp_line="$(echo "${header}" | grep "mcp:" | head -n 1)"
				if [ -n "${mcp_line}" ]; then
					local json_payload
					json_payload="$(echo "${mcp_line}" | sed 's/.*mcp://')"
					local h_name
					h_name="$(echo "${json_payload}" | jq -r '.name // empty' 2>/dev/null)"
					[ -n "${h_name}" ] && name="${h_name}"
					local h_uri
					h_uri="$(echo "${json_payload}" | jq -r '.uri // empty' 2>/dev/null)"
					[ -n "${h_uri}" ] && uri="${h_uri}"
					local h_desc
					h_desc="$(echo "${json_payload}" | jq -r '.description // empty' 2>/dev/null)"
					[ -n "${h_desc}" ] && description="${h_desc}"
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

			jq -n \
				--arg name "$name" \
				--arg desc "$description" \
				--arg path "$rel_path" \
				--arg uri "$uri" \
				--arg mime "$mime" \
				--arg provider "$provider" \
				'{name: $name, description: $desc, path: $path, uri: $uri, mimeType: $mime, provider: $provider}' >>"${items_file}"
		done
	fi

	local timestamp
	timestamp="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
	local items_json="[]"
	if [ -s "${items_file}" ]; then
		items_json="$(jq -s '.' "${items_file}")"
	fi
	rm -f "${items_file}"

	local hash
	hash="$(mcp_resources_hash_payload "${items_json}")"
	local total
	total="$(printf '%s' "${items_json}" | jq 'length')"

	MCP_RESOURCES_REGISTRY_JSON="$(jq -n \
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

	printf '%s' "${MCP_RESOURCES_REGISTRY_JSON}" >"${MCP_RESOURCES_REGISTRY_PATH}"
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
	MCP_RESOURCES_ERR_CODE=0
	# shellcheck disable=SC2034
	MCP_RESOURCES_ERR_MESSAGE=""

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

	local result_json
	result_json="$(echo "${MCP_RESOURCES_REGISTRY_JSON}" | jq -c --argjson offset "$offset" --argjson limit "$numeric_limit" '
		{
			items: .items[$offset:$offset+$limit],
			total: .total
		}
	')"

	# Check if we have a next cursor
	local total
	total="$(echo "${result_json}" | jq '.total')"
	if [ $((offset + numeric_limit)) -lt "${total}" ]; then
		local next_offset=$((offset + numeric_limit))
		local cursor_payload
		cursor_payload="$(jq -n --arg ver "1" --arg col "resources" --argjson off "$next_offset" --arg hash "${MCP_RESOURCES_REGISTRY_HASH}" '{ver: $ver|tonumber, collection: $col, offset: $off, hash: $hash}')"
		local encoded
		encoded="$(printf '%s' "${cursor_payload}" | base64 | tr -d '\n' | tr -d '=')"
		result_json="$(echo "${result_json}" | jq --arg next "${encoded}" '.nextCursor = $next')"
	fi

	printf '%s' "${result_json}"
}

mcp_resources_consume_notification() {
	if [ "${MCP_RESOURCES_CHANGED}" = true ]; then
		MCP_RESOURCES_CHANGED=false
		printf '{"jsonrpc":"2.0","method":"notifications/resources/list_changed","params":{}}'
	else
		printf ''
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
	if ! metadata="$(echo "${MCP_RESOURCES_REGISTRY_JSON}" | jq -c --arg name "${name}" '.items[] | select(.name == $name)' | head -n 1)"; then
		return 1
	fi
	if [ -z "${metadata}" ]; then
		return 1
	fi
	printf '%s' "${metadata}"
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
	local script="${MCPBASH_ROOT}/providers/file.sh"
	local tmp_err
	tmp_err="$(mktemp "${MCPBASH_TMP_ROOT}/mcp-resource-file.XXXXXX")"
	local output status
	if output="$(
		env \
			MCPBASH_ROOT="${MCPBASH_ROOT}" \
			MCP_RESOURCES_ROOTS="${MCP_RESOURCES_ROOTS:-${MCPBASH_ROOT}}" \
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
	local script="${MCPBASH_ROOT}/providers/${provider}.sh"
	if [ -x "${script}" ]; then
		local tmp_err
		tmp_err="$(mktemp "${MCPBASH_TMP_ROOT}/mcp-resource-provider.XXXXXX")"
		local output status
		if output="$(
			env \
				MCPBASH_ROOT="${MCPBASH_ROOT}" \
				MCP_RESOURCES_ROOTS="${MCP_RESOURCES_ROOTS:-${MCPBASH_ROOT}}" \
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

	mcp_logging_debug "${MCP_RESOURCES_LOGGER}" "Metadata resolved for name=${name:-<direct>} uri=${explicit_uri}"

	local uri provider mime
	uri="$(echo "${metadata}" | jq -r --arg explicit "${explicit_uri}" 'if $explicit != "" then $explicit else .uri // "" end')"
	provider="$(echo "${metadata}" | jq -r '.provider // "file"')"
	mime="$(echo "${metadata}" | jq -r '.mimeType // "text/plain"')"

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
	mcp_logging_debug "${MCP_RESOURCES_LOGGER}" "Reading provider=${provider} uri=${uri}"
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
	result="$(jq -n --arg uri "${uri}" --arg mime "${mime}" --arg content "${content}" '{
		uri: $uri,
		mimeType: $mime,
		base64: false,
		content: $content
	}')"
	printf '%s' "${result}"
}
