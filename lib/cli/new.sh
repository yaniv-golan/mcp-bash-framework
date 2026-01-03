#!/usr/bin/env bash
# CLI new command - create project in a new directory.

set -euo pipefail

if [[ -z "${BASH_VERSION:-}" ]]; then
	printf 'Bash is required for mcp-bash new; BASH_VERSION missing\n' >&2
	exit 1
fi

cli_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/cli/common.sh
. "${cli_dir}/common.sh"

mcp_cli_new() {
	local name=""
	local create_hello="true"

	while [ $# -gt 0 ]; do
		case "$1" in
		--no-hello)
			create_hello="false"
			;;
		--help | -h)
			cat <<'EOF'
Usage:
  mcp-bash new <name> [--no-hello]

Create a new MCP server project in a new directory.

Creates:
  <name>/server.d/server.meta.json
  <name>/tools/hello/ (example tool, unless --no-hello)
  <name>/.gitignore (with .registry/ entry)
EOF
			exit 0
			;;
		-*)
			printf 'Unknown option: %s\n' "$1" >&2
			exit 1
			;;
		*)
			if [ -z "${name}" ]; then
				name="$1"
			else
				printf 'Unexpected argument: %s\n' "$1" >&2
				exit 1
			fi
			;;
		esac
		shift
	done

	if [ -z "${name}" ]; then
		printf 'Server name required\n' >&2
		exit 1
	fi

	if ! mcp_scaffold_validate_name "${name}"; then
		printf 'Invalid server name: use alphanumerics, underscore, dash only (1-64 chars); no dots, paths, or traversal (Some clients including Claude Desktop rejects dots).\n' >&2
		exit 1
	fi

	local project_root="${PWD%/}/${name}"
	if [ -e "${project_root}" ]; then
		printf 'Target %s already exists (remove it or choose a new server name)\n' "${project_root}" >&2
		exit 1
	fi

	mkdir -p "${project_root}"
	printf 'Created project at ./%s/\n\n' "${name}"

	mcp_init_project_skeleton "${project_root}" "${name}" "${create_hello}"

	local server_scaffold_dir="${MCPBASH_HOME:-}/scaffold/server"
	if [ -d "${server_scaffold_dir}" ] && [ -f "${server_scaffold_dir}/README.md" ]; then
		cp "${server_scaffold_dir}/README.md" "${project_root}/README.md"
	fi

	printf '\nNext steps:\n'
	printf '  cd %s\n' "${name}"
	printf '  mcp-bash scaffold tool <name>     # create a tool\n'
	printf '  mcp-bash config --client cursor   # get client config\n'
	printf '  mcp-bash bundle                   # create distributable package\n'

	exit 0
}
