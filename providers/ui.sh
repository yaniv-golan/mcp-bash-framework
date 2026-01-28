#!/usr/bin/env bash
# UI Resource Provider for mcp-bash
# Serves HTML content from ui:// URIs per MCP Apps specification (SEP-1865)
#
# URI formats:
#   ui://resource-name          (authority only)
#   ui://server-name/path       (authority + path)
#
# Exit codes:
#   0 = success (HTML content on stdout)
#   2 = access denied
#   3 = not found
#   4 = invalid URI scheme

set -euo pipefail

# Source UI libraries for template support (provider runs as subprocess)
if [ -n "${MCPBASH_HOME:-}" ]; then
	# Set required environment variables if not already set
	: "${MCPBASH_STATE_DIR:=${MCPBASH_PROJECT_ROOT:-.}/.mcp-bash}"
	: "${MCPBASH_REGISTRY_DIR:=${MCPBASH_STATE_DIR}}"
	: "${MCPBASH_TOOLS_DIR:=${MCPBASH_PROJECT_ROOT:-}/tools}"
	: "${MCPBASH_UI_DIR:=${MCPBASH_PROJECT_ROOT:-}/ui}"
	export MCPBASH_STATE_DIR MCPBASH_REGISTRY_DIR MCPBASH_TOOLS_DIR MCPBASH_UI_DIR

	# Source JSON tool detection first
	if [ -f "${MCPBASH_HOME}/lib/json.sh" ]; then
		# shellcheck source=/dev/null
		. "${MCPBASH_HOME}/lib/json.sh"
		mcp_json_detect_tool >/dev/null 2>&1 || true
	fi
	# Source UI library
	if [ -f "${MCPBASH_HOME}/lib/ui.sh" ]; then
		# shellcheck source=/dev/null
		. "${MCPBASH_HOME}/lib/ui.sh"
	fi
	# Source UI templates library
	if [ -f "${MCPBASH_HOME}/lib/ui-templates.sh" ]; then
		# shellcheck source=/dev/null
		. "${MCPBASH_HOME}/lib/ui-templates.sh"
	fi
fi

uri="${1:-}"

# Validate URI scheme
if [[ ! "${uri}" =~ ^ui:// ]]; then
	printf '%s\n' "Invalid URI scheme: expected ui://" >&2
	exit 4
fi

# Extract resource name, handling both formats:
# - ui://weather-dashboard -> weather-dashboard (authority only)
# - ui://server/path/to/app -> path/to/app (authority + path)
without_scheme="${uri#ui://}"
resource_name=""
if [[ "${without_scheme}" == */* ]]; then
	# Has path component - extract everything after first /
	resource_name="${without_scheme#*/}"
else
	# Authority only - use as resource name
	resource_name="${without_scheme}"
fi

if [ -z "${resource_name}" ]; then
	printf '%s\n' "Empty resource name in URI: ${uri}" >&2
	exit 3
fi

# Prevent directory traversal attacks
case "${resource_name}" in
*..* | /*)
	printf '%s\n' "Invalid resource name: ${resource_name}" >&2
	exit 2
	;;
esac

# Resolve resource to filesystem path
# Priority order:
#   1. tools/NAME/ui/index.html (tool-specific UI)
#   2. ui/NAME/index.html (standalone UI)
#   3. Registry-defined custom paths (handled by lib/ui.sh after Phase 2)

mcp_ui_resolve_path() {
	local name="$1"
	local tools_dir="${MCPBASH_TOOLS_DIR:-${MCPBASH_PROJECT_ROOT:-}/tools}"
	local ui_dir="${MCPBASH_UI_DIR:-${MCPBASH_PROJECT_ROOT:-}/ui}"

	# For nested paths like "path/to/app", extract path after first component
	local sub_path="${name#*/}"
	[ "${sub_path}" = "${name}" ] && sub_path=""

	# Priority 1: Tool-specific UI (single-level names only)
	if [ -z "${sub_path}" ]; then
		local tool_ui="${tools_dir}/${name}/ui/index.html"
		if [ -f "${tool_ui}" ]; then
			printf '%s' "${tool_ui}"
			return 0
		fi
	fi

	# Priority 2: Standalone UI directory
	local standalone_ui="${ui_dir}/${name}/index.html"
	if [ -f "${standalone_ui}" ]; then
		printf '%s' "${standalone_ui}"
		return 0
	fi

	# Priority 3: Check registry for custom paths (if lib/ui.sh is loaded)
	if declare -F mcp_ui_get_path_from_registry >/dev/null 2>&1; then
		local registry_path
		if registry_path="$(mcp_ui_get_path_from_registry "${name}")"; then
			if [ -n "${registry_path}" ] && [ -f "${registry_path}" ]; then
				printf '%s' "${registry_path}"
				return 0
			fi
		fi
	fi

	return 1
}

# Try to get content via mcp_ui_get_content (supports templates)
if declare -F mcp_ui_get_content >/dev/null 2>&1; then
	if content="$(mcp_ui_get_content "${resource_name}" 2>/dev/null)"; then
		printf '%s' "${content}"
		exit 0
	fi
fi

# Fallback: resolve to static file
html_path=""
if ! html_path="$(mcp_ui_resolve_path "${resource_name}")"; then
	printf '%s\n' "UI resource not found: ${resource_name}" >&2
	exit 3
fi

if [ -z "${html_path}" ] || [ ! -f "${html_path}" ]; then
	printf '%s\n' "UI resource not found: ${resource_name}" >&2
	exit 3
fi

# Reject symlinks (security: prevent path swapping attacks)
if [ -L "${html_path}" ]; then
	printf '%s\n' "Symlinks not allowed for UI resources" >&2
	exit 2
fi

# Check size limits if configured
max_size="${MCPBASH_MAX_UI_RESOURCE_BYTES:-1048576}"  # Default 1MB
if command -v stat >/dev/null 2>&1; then
	# Portable stat: try GNU format first, fall back to BSD format
	file_size=""
	if file_size="$(stat -c%s "${html_path}" 2>/dev/null)"; then
		: # GNU stat worked
	elif file_size="$(stat -f%z "${html_path}" 2>/dev/null)"; then
		: # BSD stat worked
	fi

	if [ -n "${file_size}" ] && [ "${file_size}" -gt "${max_size}" ]; then
		printf '%s\n' "UI resource too large: ${file_size} bytes (max: ${max_size})" >&2
		exit 3
	fi
fi

# Output HTML content
# Use fd 3 to prevent race conditions (same pattern as file provider)
if ! exec 3<"${html_path}"; then
	exit 3
fi

# Final symlink check after open (TOCTOU protection)
if [ -L "${html_path}" ]; then
	exec 3<&-
	exit 2
fi

cat <&3
exec 3<&-
