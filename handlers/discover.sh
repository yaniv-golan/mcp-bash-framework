#!/usr/bin/env bash
# server/discover (MCP 2026-07-28): what a modern client needs before its
# first request. Answered from static data only (server.meta.json, the
# instructions, the request's capabilities): no registry scan, no background
# helpers, so a probe stays fast and a throwaway probe process leaves nothing
# behind. Only reached with MCPBASH_MODERN_PROTOCOL=true (lib/modern.sh).

set -euo pipefail

mcp_handle_discover() {
	local method="$1"
	local json_payload="$2"
	local id
	if ! id="$(mcp_json_extract_id "${json_payload}")"; then
		id="null"
	fi
	if [ "${MCPBASH_REQUEST_ERA:-legacy}" != "modern" ]; then
		# Without the modern _meta a probing client reads this as "legacy".
		mcp_core_build_error_response "${id}" -32602 "server/discover needs _meta[\"io.modelcontextprotocol/protocolVersion\"]" ""
		return 0
	fi
	local caps server_info
	caps="$(printf '%s' "${MCPBASH_REQUEST_META}" | "${MCPBASH_JSON_TOOL_BIN}" -c '.caps // {}')"
	server_info="$(mcp_spec_build_server_info)"
	printf '%s' "${server_info}" | "${MCPBASH_JSON_TOOL_BIN}" -c \
		--argjson id "${id}" \
		--argjson versions "$(mcp_modern_supported_versions_json)" \
		--argjson capabilities "$(mcp_modern_server_capabilities "${caps}")" \
		--arg instructions "${MCPBASH_SERVER_INSTRUCTIONS:-}" \
		--argjson ttl "$(mcp_modern_cache_ttl_ms list)" \
		--arg scope "$(mcp_modern_cache_scope)" '
		. as $info
		| {jsonrpc: "2.0", id: $id, result: (
			{supportedVersions: $versions, capabilities: $capabilities}
			+ (if $instructions != "" then {instructions: $instructions} else {} end)
			+ {ttlMs: $ttl, cacheScope: $scope, resultType: "complete",
				_meta: {"io.modelcontextprotocol/serverInfo": $info}}
		)}'
}
