#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source shell profiles to get PATH (pyenv, nvm, rbenv, etc.)
# GUI apps like Claude Desktop do not inherit terminal environment.
# shellcheck disable=SC1090
_source_profile() { [ -f "$1" ] && . "$1" >/dev/null 2>&1 || true; }

_source_profile "${HOME}/.zprofile"
_source_profile "${HOME}/.zshrc"
_source_profile "${HOME}/.bash_profile"
_source_profile "${HOME}/.profile"
_source_profile "${HOME}/.bashrc"

# Find mcp-bash
MCP_BASH=""
if command -v mcp-bash >/dev/null 2>&1; then
	MCP_BASH="$(command -v mcp-bash)"
elif [ -f "${HOME}/.local/bin/mcp-bash" ]; then
	MCP_BASH="${HOME}/.local/bin/mcp-bash"
elif [ -f "${SCRIPT_DIR}/../../bin/mcp-bash" ]; then
	MCP_BASH="${SCRIPT_DIR}/../../bin/mcp-bash"
fi

if [ -z "${MCP_BASH}" ]; then
	printf 'Error: mcp-bash not found\n' >&2
	exit 1
fi

export MCPBASH_PROJECT_ROOT="${SCRIPT_DIR}"
export MCPBASH_TOOL_ALLOWLIST="*"
exec "${MCP_BASH}" "$@"
