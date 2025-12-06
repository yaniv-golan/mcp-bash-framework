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
	local mode="show" # show | json | wrapper
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
		--wrapper)
			mode="wrapper"
			;;
		--client)
			shift
			client_filter="${1:-}"
			;;
		--help | -h)
			cat <<'EOF'
Usage:
  mcp-bash config [--project-root DIR] [--show|--json|--client NAME|--wrapper]

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
		printf '  "command": "%s",\n' "${command_path}"
		printf '  "args": []'
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

	if [ "${mode}" = "wrapper" ]; then
		cat <<EOF
#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="\$(cd "\$(dirname "\${BASH_SOURCE[0]}")" && pwd)"
FRAMEWORK_DIR="\${MCPBASH_HOME:-\$HOME/mcp-bash-framework}"

if [ ! -f "\${FRAMEWORK_DIR}/bin/mcp-bash" ]; then
	echo "Installing mcp-bash framework..." >&2
	git clone --depth 1 https://github.com/yaniv-golan/mcp-bash-framework.git "\${FRAMEWORK_DIR}"
fi

export MCPBASH_PROJECT_ROOT="\${SCRIPT_DIR}"
exec "\${FRAMEWORK_DIR}/bin/mcp-bash" "\$@"
EOF
		exit 0
	fi

	print_client() {
		local client="${1}"
		local display_env=""
		local display_command="${command_path}"
		if [ -n "${MCPBASH_PROJECT_ROOT}" ]; then
			display_env="\"env\": {\"MCPBASH_PROJECT_ROOT\": \"${MCPBASH_PROJECT_ROOT}\"}"
		fi
		case "${client}" in
		claude-desktop)
			printf '{\n'
			printf '  "mcpServers": {\n'
			printf '    "%s": {\n' "${server_name}"
			printf '      "command": "%s"' "${display_command}"
			if [ -n "${display_env}" ]; then
				printf ',\n      %s' "${display_env}"
			fi
			printf '\n    }\n'
			printf '  }\n'
			printf '}\n\n'
			;;
		cursor)
			printf '{\n'
			printf '  "mcpServers": {\n'
			printf '    "%s": {\n' "${server_name}"
			printf '      "command": "%s"' "${display_command}"
			if [ -n "${display_env}" ]; then
				printf ',\n      %s' "${display_env}"
			fi
			printf '\n    }\n'
			printf '  }\n'
			printf '}\n\n'
			;;
		claude-cli)
			printf '{\n'
			printf '  "name": "%s",\n' "${server_name}"
			printf '  "command": "%s"' "${display_command}"
			if [ -n "${display_env}" ]; then
				printf ',\n  %s' "${display_env}"
			fi
			printf '\n}\n\n'
			;;
		windsurf)
			printf '{\n'
			printf '  "mcpServers": {\n'
			printf '    "%s": {\n' "${server_name}"
			printf '      "command": "%s"' "${display_command}"
			if [ -n "${display_env}" ]; then
				printf ',\n      %s' "${display_env}"
			fi
			printf '\n    }\n'
			printf '  }\n'
			printf '}\n\n'
			;;
		librechat)
			printf '{\n'
			printf '  "name": "%s",\n' "${server_name}"
			printf '  "command": "%s"' "${display_command}"
			if [ -n "${display_env}" ]; then
				printf ',\n  %s' "${display_env}"
			fi
			printf '\n}\n\n'
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
