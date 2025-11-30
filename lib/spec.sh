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
	printf '{"jsonrpc":"2.0","id":%s,"result":{"protocolVersion":"%s","capabilities":%s,"serverInfo":{"name":"%s","version":"%s","title":"%s"}}}' \
		"${id_json}" \
		"${protocol}" \
		"${capabilities_json}" \
		"${MCPBASH_SERVER_NAME}" \
		"${MCPBASH_SERVER_VERSION}" \
		"${MCPBASH_SERVER_TITLE}"
}
