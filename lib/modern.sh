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
	# shellcheck disable=SC2034  # Read by lib/core.sh and handlers/discover.sh
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
# Usage: mcp_modern_apply_worker_context WORKER_KEY
mcp_modern_apply_worker_context() {
	local key="${1:-}"
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
		# The live-progress flusher runs in the main process: tell it the level.
		if [ -n "${key}" ] && [ -n "${MCPBASH_STATE_DIR:-}" ]; then
			printf '%s' "${level}" >"${MCPBASH_STATE_DIR}/loglevel.${key}" 2>/dev/null || true
		fi
	else
		mcp_logging_set_level "off"
		export MCP_LOG_STREAM=""
	fi
}

# Caching hints (ttlMs, cacheScope), which 2026-07-28 requires on
# server/discover, the list results and resources/read. Lists default to the
# registry refresh interval (5 s; 0 when MCPBASH_LOG_LEVEL=debug, so edits
# show up at once while developing), reads to 0. The scope is "private": the
# lists depend on the operator's allowlist and environment.
# Usage: mcp_modern_cache_ttl_ms list|read
mcp_modern_cache_ttl_ms() {
	local kind="$1" ttl
	if [ "${kind}" = "read" ]; then
		ttl="${MCPBASH_MODERN_READ_TTL_MS:-0}"
	elif [ "${MCPBASH_LOG_LEVEL:-}" = "debug" ] && [ -z "${MCPBASH_MODERN_LIST_TTL_MS:-}" ]; then
		ttl=0
	else
		ttl="${MCPBASH_MODERN_LIST_TTL_MS:-5000}"
	fi
	case "${ttl}" in
	'' | *[!0-9]*) ttl=0 ;;
	esac
	printf '%s' "${ttl}"
}

mcp_modern_cache_scope() {
	case "${MCPBASH_MODERN_CACHE_SCOPE:-private}" in
	public) printf 'public' ;;
	*) printf 'private' ;;
	esac
}

# Server capabilities for a modern client with capabilities CAPS_JSON. No
# listChanged or subscribe yet: on 2026-07-28 those mean subscriptions/listen,
# which the server doesn't serve yet. logging: a request's logLevel is
# honoured (log notifications are sent only when a request asks for them).
mcp_modern_server_capabilities() {
	local caps_json="$1"
	printf '%s' "${caps_json}" | "${MCPBASH_JSON_TOOL_BIN}" -c --argjson ui "${MCP_UI_SUPPORTED_MIMETYPES:-[]}" '
		{logging: {}, tools: {}, resources: {}, prompts: {}, completions: {}}
		+ (if (.extensions["io.modelcontextprotocol/ui"] // null) != null
			then {extensions: {"io.modelcontextprotocol/ui": {mimeTypes: $ui}}} else {} end)
	'
}

# Give a response to a modern request the shape 2026-07-28 requires: every
# result gets resultType "complete" and serverInfo in _meta (merged with the
# _meta it has); the lists and resources/read get caching hints. On errors,
# -32002 (resource not found) becomes -32602, and the legacy server codes
# (-32000..-32019, such as -32003 shutting down) become -32603: 2026-07-28
# defines its own codes from -32020 up. The response goes to jq on stdin
# (a tool result can be large).
# Usage: mcp_modern_decorate_response METHOD RESPONSE_JSON
mcp_modern_decorate_response() {
	local method="$1" response="$2"
	local cache="none" ttl=0
	case "${method}" in
	tools/list | prompts/list | resources/list | resources/templates/list) cache="list" ;;
	resources/read) cache="read" ;;
	esac
	if [ "${cache}" != "none" ]; then
		ttl="$(mcp_modern_cache_ttl_ms "${cache}")"
	fi
	local decorated
	# The server info (icons) can be large: it goes on stdin with the response.
	if decorated="$({
		mcp_spec_build_server_info
		printf '\n%s' "${response}"
	} | "${MCPBASH_JSON_TOOL_BIN}" -c -s \
		--arg cache "${cache}" \
		--argjson ttl "${ttl}" \
		--arg scope "$(mcp_modern_cache_scope)" '
		.[0] as $info | .[1]
		| if (.result | type) == "object" then
			.result |= (
				.resultType = (.resultType // "complete")
				| ._meta = ((._meta // {}) + {"io.modelcontextprotocol/serverInfo": $info})
				| if $cache != "none" then .ttlMs = $ttl | .cacheScope = $scope else . end
			)
		elif (.error.code | type) == "number" then
			.error.code |= (if . == -32002 then -32602 elif . <= -32000 and . >= -32019 then -32603 else . end)
		else . end
	' 2>/dev/null)" && [ -n "${decorated}" ]; then
		printf '%s' "${decorated}"
	else
		printf '%s' "${response}"
	fi
}
