#!/usr/bin/env bash
# Conditional library sourcing helper.
# Reduces boilerplate for "source X if function Y is not defined" pattern.

set -euo pipefail

# Conditionally source a library if a check function is not defined.
# Usage: mcp_require <lib_name> <check_function>
# Example: mcp_require registry mcp_registry_resolve_scan_root
#
# Sources ${MCPBASH_HOME}/lib/<lib_name>.sh if <check_function> is not already
# defined. This provides idempotent sourcing with minimal overhead.
mcp_require() {
	local lib="$1" func="$2"
	# shellcheck disable=SC1090
	command -v "${func}" >/dev/null 2>&1 || . "${MCPBASH_HOME}/lib/${lib}.sh"
}
