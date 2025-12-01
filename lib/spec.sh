#!/usr/bin/env bash
# Capability negotiation helpers.

set -euo pipefail

mcp_spec_supported_protocols() {
	# Default protocol 2025-06-18 with explicit back-compat for earlier releases.
	printf '%s' "2025-06-18 2025-03-26 2024-11-05"
}

mcp_spec_resolve_protocol_version() {
	local requested="$1"
	local version

	if [ -z "${requested}" ]; then
		printf '%s' "${MCPBASH_PROTOCOL_VERSION}"
		return 0
	fi

	for version in $(mcp_spec_supported_protocols); do
		if [ "${requested}" = "${version}" ]; then
			printf '%s' "${version}"
			return 0
		fi
	done

	return 1
}

mcp_spec_capabilities_full() {
	cat <<'EOF'
{"logging":{},"tools":{"listChanged":true},"resources":{"subscribe":true,"listChanged":true},"prompts":{"listChanged":true},"completion":{}}
EOF
}

mcp_spec_capabilities_backport_20250326() {
	# Older protocol maintains core surface but omits listChanged flags added in 2025-06-18.
	cat <<'EOF'
{"logging":{},"tools":{},"resources":{"subscribe":true},"prompts":{},"completion":{}}
EOF
}

mcp_spec_capabilities_backport_20241105() {
	# Legacy protocol support for clients pinned to 2024-11-05; no listChanged flags.
	cat <<'EOF'
{"logging":{},"tools":{},"resources":{"subscribe":true},"prompts":{},"completion":{}}
EOF
}

mcp_spec_capabilities_minimal() {
	printf '{"logging":{}}'
}

mcp_spec_capabilities_for_runtime() {
	local protocol="${1:-${MCPBASH_NEGOTIATED_PROTOCOL_VERSION:-${MCPBASH_PROTOCOL_VERSION}}}"

	if mcp_runtime_is_minimal_mode; then
		mcp_spec_capabilities_minimal
	else
		case "${protocol}" in
		2025-03-26)
			mcp_spec_capabilities_backport_20250326
			;;
		2024-11-05)
			mcp_spec_capabilities_backport_20241105
			;;
		*)
			mcp_spec_capabilities_full
			;;
		esac
	fi
}

mcp_spec_build_initialize_response() {
	local id_json="$1"
	local capabilities_json="$2"
	local protocol="${3:-${MCPBASH_NEGOTIATED_PROTOCOL_VERSION:-${MCPBASH_PROTOCOL_VERSION}}}"

	# Build serverInfo with required fields and optional fields when set
	local server_info
	server_info="$(mcp_spec_build_server_info)"

	printf '{"jsonrpc":"2.0","id":%s,"result":{"protocolVersion":"%s","capabilities":%s,"serverInfo":%s}}' \
		"${id_json}" \
		"${protocol}" \
		"${capabilities_json}" \
		"${server_info}"
}

mcp_spec_build_server_info() {
	# Build serverInfo object with required fields (name, version, title)
	# and optional fields (description, icons, websiteUrl) when set.

	# If we have JSON tooling, use jq for clean construction
	if [ "${MCPBASH_JSON_TOOL:-none}" != "none" ]; then
		local jq_args=()
		jq_args+=(--arg name "${MCPBASH_SERVER_NAME}")
		jq_args+=(--arg version "${MCPBASH_SERVER_VERSION}")
		jq_args+=(--arg title "${MCPBASH_SERVER_TITLE}")

		local jq_filter='{name: $name, version: $version, title: $title}'

		# Add optional fields
		if [ -n "${MCPBASH_SERVER_DESCRIPTION:-}" ]; then
			jq_args+=(--arg description "${MCPBASH_SERVER_DESCRIPTION}")
			jq_filter="${jq_filter} + {description: \$description}"
		fi

		if [ -n "${MCPBASH_SERVER_WEBSITE_URL:-}" ]; then
			jq_args+=(--arg websiteUrl "${MCPBASH_SERVER_WEBSITE_URL}")
			jq_filter="${jq_filter} + {websiteUrl: \$websiteUrl}"
		fi

		if [ -n "${MCPBASH_SERVER_ICONS:-}" ]; then
			jq_args+=(--argjson icons "${MCPBASH_SERVER_ICONS}")
			jq_filter="${jq_filter} + {icons: \$icons}"
		fi

		"${MCPBASH_JSON_TOOL_BIN}" -c -n "${jq_args[@]}" "${jq_filter}"
	else
		# Minimal mode: just required fields with simple printf
		printf '{"name":"%s","version":"%s","title":"%s"}' \
			"${MCPBASH_SERVER_NAME}" \
			"${MCPBASH_SERVER_VERSION}" \
			"${MCPBASH_SERVER_TITLE}"
	fi
}
