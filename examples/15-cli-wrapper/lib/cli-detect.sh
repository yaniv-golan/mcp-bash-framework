#!/usr/bin/env bash
set -euo pipefail
# lib/cli-detect.sh — detect external CLIs in restricted PATH environments.
# Copy this file into your MCP server project's lib/ directory.
# See docs/BEST-PRACTICES.md §4.4 for full documentation.

# Detect a CLI by searching version manager shim locations.
# Usage: CLI_PATH=$(mcp_detect_cli mycli "pip install pkg") || mcp_fail "not found"
#
# Override: Set ${NAME}_CLI (e.g., MYCLI_CLI) to skip detection.
# Bash 3.2 compatible (no ${var^^}).
mcp_detect_cli() {
	local name="$1" install_hint="$2"

	# Check user override (e.g., MYCLI_CLI for "mycli")
	local var_name
	var_name="$(printf '%s_CLI' "$name" | tr '[:lower:]-' '[:upper:]_')"
	local override=""
	eval "override=\"\${${var_name}:-}\""
	[[ -n "$override" ]] && {
		printf '%s\n' "$override"
		return 0
	}

	# Search common locations (version managers, Homebrew, system)
	local candidate
	for candidate in \
		"${HOME}/.pyenv/shims/${name}" \
		"${HOME}/.asdf/shims/${name}" \
		"${HOME}/.local/share/mise/shims/${name}" \
		"${HOME}/.rbenv/shims/${name}" \
		"${HOME}/.goenv/shims/${name}" \
		"${HOME}/.local/bin/${name}" \
		"${HOME}/.cargo/bin/${name}" \
		"${HOME}/.volta/bin/${name}" \
		"${HOME}/.local/share/fnm/aliases/default/bin/${name}" \
		"/opt/homebrew/bin/${name}" \
		"/usr/local/bin/${name}" \
		"/usr/bin/${name}" \
		"/bin/${name}"; do
		[[ -x "$candidate" ]] && {
			printf '%s\n' "$candidate"
			return 0
		}
	done

	# nvm: check all installed node versions (use newest)
	local nvm_match
	for nvm_match in "${HOME}"/.nvm/versions/node/*/bin/"${name}"; do
		[[ -x "$nvm_match" ]] && {
			printf '%s\n' "$nvm_match"
			return 0
		}
	done

	# Fall back to PATH
	command -v "$name" 2>/dev/null && return 0

	# Not found — emit actionable error
	printf 'ERROR: %s not found.' "$name" >&2
	[[ -n "$install_hint" ]] && printf ' Install: %s' "$install_hint" >&2
	printf ' Or set %s=/path/to/%s\n' "$var_name" "$name" >&2
	return 1
}
