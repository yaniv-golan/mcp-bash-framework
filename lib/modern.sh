#!/usr/bin/env bash
# Modern-era requests (MCP 2026-07-28): stateless requests that carry the
# protocol version and the client's capabilities in params._meta, served next
# to the legacy initialize session in the same process.
#
# Off unless MCPBASH_MODERN_PROTOCOL=true. Until server-to-client input
# requests (roots, elicitation) and subscriptions/listen exist on this path,
# a client that goes modern would get less than it gets from the legacy
# session, so the server answers server/discover only when switched on.
# Minimal mode (no JSON tool) is legacy-only.

set -euo pipefail

MCP_MODERN_PROTOCOL_VERSION="2026-07-28"

# Era of the request being dispatched, and a compact summary of its modern
# _meta ({version, hasCaps, caps, logLevel}). Set by mcp_modern_classify for
# one request; workers forked for that request inherit them.
MCPBASH_REQUEST_ERA="legacy"
MCPBASH_REQUEST_META=""

mcp_modern_enabled() {
	[ "${MCPBASH_MODERN_PROTOCOL:-false}" = "true" ] || return 1
	[ "${MCPBASH_JSON_TOOL:-none}" != "none" ] || return 1
	if mcp_runtime_is_minimal_mode; then
		return 1
	fi
	return 0
}

# Every version this server speaks: the modern one first, then the legacy
# ones (reached through initialize).
mcp_modern_supported_versions_json() {
	printf '["%s",%s' "${MCP_MODERN_PROTOCOL_VERSION}" "$(mcp_spec_supported_protocols_json | cut -c2-)"
}

# Decide the era of one request. A request is modern when its
# params._meta has io.modelcontextprotocol/protocolVersion. The substring
# check keeps legacy traffic free of an extra jq run; jq decides.
mcp_modern_classify() {
	local json_line="$1"
	MCPBASH_REQUEST_ERA="legacy"
	MCPBASH_REQUEST_META=""
	mcp_modern_enabled || return 0
	case "${json_line}" in
	*'io.modelcontextprotocol/protocolVersion'*) ;;
	*) return 0 ;;
	esac
	local meta
	meta="$(printf '%s' "${json_line}" | "${MCPBASH_JSON_TOOL_BIN}" -c '
		(.params._meta // null) as $m
		| if ($m | type) == "object" and ($m | has("io.modelcontextprotocol/protocolVersion")) then
			{
				version: $m["io.modelcontextprotocol/protocolVersion"],
				hasCaps: ($m | has("io.modelcontextprotocol/clientCapabilities")),
				caps: (($m["io.modelcontextprotocol/clientCapabilities"] // {}) | if type == "object" then . else {} end),
				logLevel: ($m["io.modelcontextprotocol/logLevel"] // null)
			}
		else empty end
	' 2>/dev/null || true)"
	[ -n "${meta}" ] || return 0
	MCPBASH_REQUEST_ERA="modern"
	MCPBASH_REQUEST_META="${meta}"
}

# Methods a legacy session has that 2026-07-28 removed or replaced.
mcp_modern_method_removed() {
	case "$1" in
	initialize | initialized | notifications/initialized | shutdown | exit | ping) return 0 ;;
	logging/setLevel | resources/subscribe | resources/unsubscribe) return 0 ;;
	roots/* | notifications/roots/*) return 0 ;;
	esac
	return 1
}

# Print the error response for a modern request the server refuses, or
# nothing when it may be served. Unknown versions get -32022 (with the
# versions the server speaks); a request without the required _meta keys
# gets -32602; a removed method gets -32601.
mcp_modern_refusal() {
	local method="$1"
	local id_json="$2"
	local checks version has_caps level
	checks="$(printf '%s' "${MCPBASH_REQUEST_META}" | "${MCPBASH_JSON_TOOL_BIN}" -r '
		[(.version | if type == "string" then . else tojson end), (.hasCaps | tostring), (.logLevel // "" | tostring)] | @tsv
	' 2>/dev/null || true)"
	version="${checks%%	*}"
	checks="${checks#*	}"
	has_caps="${checks%%	*}"
	level="${checks#*	}"
	if [ "${version}" != "${MCP_MODERN_PROTOCOL_VERSION}" ]; then
		local requested_json
		requested_json="$(printf '%s' "${MCPBASH_REQUEST_META}" | "${MCPBASH_JSON_TOOL_BIN}" -c '.version' 2>/dev/null || printf 'null')"
		mcp_core_build_error_response "${id_json}" -32022 "Unsupported protocol version" \
			"{\"supported\":$(mcp_modern_supported_versions_json),\"requested\":${requested_json}}"
		return 0
	fi
	if [ "${has_caps}" != "true" ]; then
		mcp_core_build_error_response "${id_json}" -32602 "Missing _meta[\"io.modelcontextprotocol/clientCapabilities\"]" ""
		return 0
	fi
	case "${level}" in
	'' | debug | info | notice | warning | error | critical | alert | emergency) ;;
	*)
		mcp_core_build_error_response "${id_json}" -32602 "Invalid _meta[\"io.modelcontextprotocol/logLevel\"]" ""
		return 0
		;;
	esac
	if mcp_modern_method_removed "${method}"; then
		mcp_core_build_error_response "${id_json}" -32601 "Method not found" ""
		return 0
	fi
	return 0
}

# Run inside the worker forked for one modern request, before the handler.
# Every client-capability global comes from this request's _meta only, never
# from a legacy session that initialized this process.
mcp_modern_apply_worker_context() {
	export MCPBASH_PROTOCOL_ERA="modern"
	# shellcheck disable=SC2034  # Read by the handlers and spec helpers
	MCPBASH_NEGOTIATED_PROTOCOL_VERSION="${MCP_MODERN_PROTOCOL_VERSION}"

	local caps ui="0"
	caps="$(printf '%s' "${MCPBASH_REQUEST_META}" | "${MCPBASH_JSON_TOOL_BIN}" -c '.caps // {}' 2>/dev/null || printf '{}')"
	if printf '%s' "${caps}" | "${MCPBASH_JSON_TOOL_BIN}" -e '.extensions["io.modelcontextprotocol/ui"] // empty | . != null' >/dev/null 2>&1; then
		ui="1"
	fi
	export MCPBASH_CLIENT_SUPPORTS_UI="${ui}"

	# Nothing on this path may ask the client anything: stdio forbids
	# server-to-client requests in 2026-07-28, and their replacement
	# (input_required results) isn't built yet. Elicitation is unavailable
	# and roots come from MCPBASH_ROOTS, config/roots.json or the project root.
	# shellcheck disable=SC2034
	MCPBASH_CLIENT_SUPPORTS_ELICITATION=0
	# shellcheck disable=SC2034
	MCPBASH_CLIENT_ELICIT_FORM=0
	# shellcheck disable=SC2034
	MCPBASH_CLIENT_ELICIT_URL=0
	# shellcheck disable=SC2034
	MCPBASH_CLIENT_SUPPORTS_ROOTS=0
	# shellcheck disable=SC2034
	MCPBASH_CLIENT_SUPPORTS_ROOTS_LIST_CHANGED=0
	# shellcheck disable=SC2034
	MCPBASH_ROOTS_PENDING_REQUEST=0
	# shellcheck disable=SC2034
	MCPBASH_ROOTS_PENDING_REQUEST_ID=""
	mcp_roots_load_all_fallbacks >/dev/null 2>&1 || true
	# shellcheck disable=SC2034
	MCPBASH_ROOTS_READY=1

	# Log notifications only when the request asked for them, at its level.
	local level
	level="$(printf '%s' "${MCPBASH_REQUEST_META}" | "${MCPBASH_JSON_TOOL_BIN}" -r '.logLevel // ""' 2>/dev/null || true)"
	if [ -n "${level}" ]; then
		mcp_logging_set_level "${level}"
	else
		mcp_logging_set_level "off"
		export MCP_LOG_STREAM=""
	fi
}
