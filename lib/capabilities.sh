#!/usr/bin/env bash
# Extension capabilities management for MCP Apps and other protocol extensions.
# Tracks which extensions the client supports during capability negotiation.

set -euo pipefail

# Track client extension support (initialized in mcp_extensions_init)
# Using 0/1 instead of true/false for consistency with elicitation.sh
MCPBASH_CLIENT_SUPPORTS_UI="${MCPBASH_CLIENT_SUPPORTS_UI:-0}"

# Associative array to store extension data (requires bash 4+)
# Populated during initialize with client-advertised extension capabilities
declare -gA _MCP_CLIENT_EXTENSIONS 2>/dev/null || true

# UI extension identifier per MCP Apps spec (SEP-1865)
# Guard against re-sourcing (readonly fails if already declared)
if ! declare -p MCP_UI_EXTENSION_ID &>/dev/null; then
	readonly MCP_UI_EXTENSION_ID="io.modelcontextprotocol/ui"
fi

# Supported MIME types for UI extension
if ! declare -p MCP_UI_SUPPORTED_MIMETYPES &>/dev/null; then
	readonly MCP_UI_SUPPORTED_MIMETYPES='["text/html;profile=mcp-app"]'
fi

# --- State file paths for subprocess access ---

mcp_extensions_ui_support_flag_path() {
	printf '%s/extensions.ui.support' "${MCPBASH_STATE_DIR}"
}

mcp_extensions_ui_mimetypes_path() {
	printf '%s/extensions.ui.mimetypes' "${MCPBASH_STATE_DIR}"
}

mcp_extensions_write_ui_support_flag() {
	local value="$1"
	printf '%s' "${value}" >"$(mcp_extensions_ui_support_flag_path 2>/dev/null)" 2>/dev/null || true
}

mcp_extensions_write_ui_mimetypes() {
	local mimetypes="$1"
	printf '%s' "${mimetypes}" >"$(mcp_extensions_ui_mimetypes_path 2>/dev/null)" 2>/dev/null || true
}

# --- Initialization ---

# Initialize extension capabilities from client capabilities JSON
# Called from handlers/lifecycle.sh during initialize
mcp_extensions_init() {
	local client_caps="${1:-{}}"
	MCPBASH_CLIENT_SUPPORTS_UI=0

	# Check for io.modelcontextprotocol/ui extension
	# Client advertises via: capabilities.extensions["io.modelcontextprotocol/ui"]
	local ui_ext=""
	if [ "${MCPBASH_JSON_TOOL:-none}" != "none" ]; then
		ui_ext="$(printf '%s' "${client_caps}" | "${MCPBASH_JSON_TOOL_BIN}" -c '.extensions["io.modelcontextprotocol/ui"] // empty' 2>/dev/null || true)"
	fi

	if [ -n "${ui_ext}" ] && [ "${ui_ext}" != "null" ]; then
		MCPBASH_CLIENT_SUPPORTS_UI=1
		_MCP_CLIENT_EXTENSIONS["${MCP_UI_EXTENSION_ID}"]="${ui_ext}"

		# Extract supported MIME types from client (for future use)
		local client_mimetypes
		client_mimetypes="$(printf '%s' "${ui_ext}" | "${MCPBASH_JSON_TOOL_BIN}" -c '.mimeTypes // []' 2>/dev/null || printf '[]')"
		mcp_extensions_write_ui_mimetypes "${client_mimetypes}"
	else
		# Fallback for environments without JSON tooling: string match
		case "${client_caps}" in
		*\"io.modelcontextprotocol/ui\"*)
			MCPBASH_CLIENT_SUPPORTS_UI=1
			;;
		esac
	fi

	mcp_extensions_write_ui_support_flag "${MCPBASH_CLIENT_SUPPORTS_UI}"
}

# --- Query functions ---

# Check if client supports UI extension
# Returns: 0 if supported, 1 if not
mcp_client_supports_ui() {
	if [ "${MCPBASH_CLIENT_SUPPORTS_UI}" = "1" ]; then
		return 0
	fi
	# Check state file for subprocess context
	local flag
	flag="$(cat "$(mcp_extensions_ui_support_flag_path 2>/dev/null)" 2>/dev/null || true)"
	[ "${flag}" = "1" ]
}

# Check if client supports a specific extension by ID
# Usage: mcp_client_supports_extension "io.modelcontextprotocol/ui"
# Returns: 0 if supported, 1 if not
mcp_client_supports_extension() {
	local extension_id="$1"

	case "${extension_id}" in
	"${MCP_UI_EXTENSION_ID}")
		mcp_client_supports_ui
		return $?
		;;
	*)
		# Check associative array for other extensions
		if [ -n "${_MCP_CLIENT_EXTENSIONS[${extension_id}]:-}" ]; then
			return 0
		fi
		return 1
		;;
	esac
}

# Get extension data for a supported extension
# Returns: JSON string of extension capabilities, or empty string
mcp_client_extension_data() {
	local extension_id="$1"
	printf '%s' "${_MCP_CLIENT_EXTENSIONS[${extension_id}]:-}"
}

# --- Server capability building ---

# Build server extension capabilities for initialize response
# Only includes extensions that the client also supports (capability negotiation)
mcp_extensions_build_server_capabilities() {
	local extensions="{}"

	# Only advertise UI extension if client supports it
	if mcp_client_supports_ui; then
		if [ "${MCPBASH_JSON_TOOL:-none}" != "none" ]; then
			extensions="$(printf '%s' "${extensions}" | "${MCPBASH_JSON_TOOL_BIN}" -c \
				--argjson mimetypes "${MCP_UI_SUPPORTED_MIMETYPES}" \
				'.["io.modelcontextprotocol/ui"] = {mimeTypes: $mimetypes}')"
		else
			# Minimal mode fallback
			extensions='{"io.modelcontextprotocol/ui":{"mimeTypes":["text/html;profile=mcp-app"]}}'
		fi
	fi

	printf '%s' "${extensions}"
}

# Merge extension capabilities into full server capabilities JSON
# Usage: mcp_extensions_merge_capabilities '{"tools":{},...}'
# Returns: Capabilities JSON with extensions field added
mcp_extensions_merge_capabilities() {
	local base_capabilities="$1"
	local extensions
	extensions="$(mcp_extensions_build_server_capabilities)"

	# Only add extensions field if non-empty
	if [ "${extensions}" = "{}" ]; then
		printf '%s' "${base_capabilities}"
		return
	fi

	if [ "${MCPBASH_JSON_TOOL:-none}" != "none" ]; then
		printf '%s' "${base_capabilities}" | "${MCPBASH_JSON_TOOL_BIN}" -c \
			--argjson ext "${extensions}" \
			'. + {extensions: $ext}'
	else
		# Minimal mode: simple string manipulation (assumes base_capabilities ends with })
		local without_brace="${base_capabilities%\}}"
		printf '%s,"extensions":%s}' "${without_brace}" "${extensions}"
	fi
}
