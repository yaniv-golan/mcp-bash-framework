#!/usr/bin/env bash
# CLI init command.

set -euo pipefail

if [[ -z "${BASH_VERSION:-}" ]]; then
	printf 'Bash is required for mcp-bash init; BASH_VERSION missing\n' >&2
	exit 1
fi

# Globals: MCPBASH_HOME (from bin), usage() from bin.

cli_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/cli/common.sh
. "${cli_dir}/common.sh"

mcp_cli_init() {
	local name=""
	local create_hello="true"

	while [ $# -gt 0 ]; do
		case "$1" in
		--name)
			shift
			name="${1:-}"
			;;
		--no-hello)
			create_hello="false"
			;;
		--help | -h)
			cat <<'EOF'
Usage:
  mcp-bash init [--name NAME] [--no-hello]

Initialize an MCP server project in the current directory.

Creates:
  server.d/server.meta.json
  tools/hello/ (example tool, unless --no-hello)
  .gitignore (with .registry/ entry)
EOF
			exit 0
			;;
		*)
			usage
			exit 1
			;;
		esac
		shift
	done

	local project_root
	project_root="$(pwd)"

	if [ -z "${name}" ]; then
		name="$(basename "${project_root}")"
	fi

	printf 'Initializing MCP server project...\n\n'
	mcp_init_project_skeleton "${project_root}" "${name}" "${create_hello}"

	printf '\nYour MCP server "%s" is ready!\n\n' "${name}"
	printf 'Test immediately:\n'
	printf '  npx @modelcontextprotocol/inspector --transport stdio -- mcp-bash\n\n'
	printf 'Add more tools:\n'
	printf '  mcp-bash scaffold tool <name>\n'

	exit 0
}
