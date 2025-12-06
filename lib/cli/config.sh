#!/usr/bin/env bash
# CLI config command.

set -euo pipefail

if [[ -z "${BASH_VERSION:-}" ]]; then
	printf 'Bash is required for mcp-bash config; BASH_VERSION missing\n' >&2
	exit 1
fi

# Globals: usage() from bin, MCPBASH_HOME and runtime globals set by initialize_runtime_paths.

mcp_cli_config() {
	local project_root=""
	local mode="show" # show | json
	local client_filter=""

	while [ $# -gt 0 ]; do
		case "$1" in
		--project-root)
			shift
			project_root="${1:-}"
			;;
		--show)
			mode="show"
			;;
		--json)
			mode="json"
			;;
		--client)
			shift
			client_filter="${1:-}"
			;;
		--help | -h)
			cat <<'EOF'
Usage:
  mcp-bash config [--project-root DIR] [--show|--json|--client NAME]

Print MCP client configuration snippets for the current project.
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

	# Allow explicit project override
	if [ -n "${project_root}" ]; then
		MCPBASH_PROJECT_ROOT="${project_root}"
		export MCPBASH_PROJECT_ROOT
	fi

	require_bash_runtime
	initialize_runtime_paths
	mcp_runtime_init_paths "cli"
	mcp_runtime_detect_json_tool
	mcp_runtime_load_server_meta

	local server_name="${MCPBASH_SERVER_NAME}"
	local command_path="${MCPBASH_HOME}/bin/mcp-bash"
	if [ "${mode}" = "json" ]; then
		printf '{\n'
		printf '  "name": "%s",\n' "${server_name}"
		printf '  "command": "%s"' "${command_path}"
		if [ -n "${MCPBASH_PROJECT_ROOT}" ]; then
			printf ',\n  "env": {\n'
			printf '    "MCPBASH_PROJECT_ROOT": "%s"\n' "${MCPBASH_PROJECT_ROOT}"
			printf '  }\n'
		else
			printf '\n'
		fi
		printf '}\n'
		exit 0
	fi

	print_client() {
		local client="${1}"
		case "${client}" in
		claude-desktop)
			printf 'Claude Desktop:\n'
			printf '  Add this to your Claude config (replace "~" with your home dir):\n'
			printf '  {\n'
			printf '    "mcpServers": {\n'
			printf '      "%s": {\n' "${server_name}"
			printf '        "command": "%s",\n' "${command_path}"
			if [ -n "${MCPBASH_PROJECT_ROOT}" ]; then
				printf '        "env": {\n'
				printf '          "MCPBASH_PROJECT_ROOT": "%s"\n' "${MCPBASH_PROJECT_ROOT}"
				printf '        }\n'
				printf '      }\n'
				printf '    }\n'
				printf '  }\n\n'
			else
				printf '      }\n'
				printf '    }\n'
				printf '  }\n\n'
			fi
			;;
		cursor)
			local display_path="${command_path}"
			if [ -n "${MCPBASH_PROJECT_ROOT}" ]; then
				display_path="${display_path} (MCPBASH_PROJECT_ROOT=${MCPBASH_PROJECT_ROOT})"
			fi
			printf 'Cursor:\n'
			printf '  Command: %s\n\n' "${display_path}"
			;;
		claude-cli)
			local display_cli="${command_path}"
			if [ -n "${MCPBASH_PROJECT_ROOT}" ]; then
				display_cli="${display_cli} (set MCPBASH_PROJECT_ROOT=${MCPBASH_PROJECT_ROOT})"
			fi
			printf 'Claude CLI:\n'
			printf '  Command: %s\n\n' "${display_cli}"
			;;
		windsurf)
			local display_ws="${command_path}"
			if [ -n "${MCPBASH_PROJECT_ROOT}" ]; then
				display_ws="${display_ws} (set MCPBASH_PROJECT_ROOT=${MCPBASH_PROJECT_ROOT})"
			fi
			printf 'Windsurf:\n'
			printf '  Config file: %s\n\n' "${display_ws}"
			printf '  Add this to \"mcpServers\":\n'
			printf '  {\n'
			printf '    \"%s\": {\n' "${server_name}"
			printf '      \"command\": \"%s\",\n' "${command_path}"
			printf '      \"env\": {\n'
			printf '        \"MCPBASH_PROJECT_ROOT\": \"%s\"\n' "${project_root}"
			printf '      }\n'
			printf '    }\n'
			printf '  }\n\n'
			;;
		librechat)
			printf 'LibreChat:\n'
			printf '  Use the following server descriptor (see LibreChat MCP docs for where to place it):\n\n'
			printf '  {\n'
			printf '    \"name\": \"%s\",\n' "${server_name}"
			printf '    \"command\": \"%s\",\n' "${command_path}"
			printf '    \"env\": {\n'
			printf '      \"MCPBASH_PROJECT_ROOT\": \"%s\"\n' "${project_root}"
			printf '    }\n'
			printf '  }\n\n'
			;;
		esac
	}

	if [ -n "${client_filter}" ]; then
		print_client "${client_filter}"
	else
		print_client "claude-desktop"
		print_client "cursor"
		print_client "claude-cli"
		print_client "windsurf"
		print_client "librechat"
	fi

	exit 0
}
