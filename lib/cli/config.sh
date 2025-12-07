#!/usr/bin/env bash
# CLI config command.

set -euo pipefail

if [[ -z "${BASH_VERSION:-}" ]]; then
	printf 'Bash is required for mcp-bash config; BASH_VERSION missing\n' >&2
	exit 1
fi

# Globals: usage() from bin, MCPBASH_HOME and runtime globals set by initialize_runtime_paths.

cli_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/cli/common.sh
. "${cli_dir}/common.sh"

mcp_cli_config() {
	local project_root=""
	local mode="show" # show | json | wrapper | inspector
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
		--inspector)
			mode="inspector"
			;;
		--client)
			shift
			client_filter="${1:-}"
			;;
		--help | -h)
			cat <<'EOF'
Usage:
  mcp-bash config [--project-root DIR] [--show|--json|--client NAME|--wrapper|--inspector]

Print MCP client configuration snippets for the current project.
  --wrapper   Generate auto-install wrapper script.
              Interactive: creates <project-root>/<name>.sh
              Piped/redirected: writes to stdout
  --inspector Print a ready-to-run MCP Inspector command (stdio transport)
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
	local server_name_json
	local command_path_json
	local project_root_json=""
	local has_project_root="false"

	server_name_json="$(mcp_json_escape_string "${server_name}")"
	command_path_json="$(mcp_json_escape_string "${command_path}")"
	if [ -n "${MCPBASH_PROJECT_ROOT}" ]; then
		has_project_root="true"
		project_root_json="$(mcp_json_escape_string "${MCPBASH_PROJECT_ROOT}")"
	fi
	if [ "${mode}" = "json" ]; then
		printf '{\n'
		printf '  "name": %s,\n' "${server_name_json}"
		printf '  "command": %s,\n' "${command_path_json}"
		printf '  "args": []'
		if [ "${has_project_root}" = "true" ]; then
			printf ',\n  "env": {\n'
			printf '    "MCPBASH_PROJECT_ROOT": %s\n' "${project_root_json}"
			printf '  }\n'
		else
			printf '\n'
		fi
		printf '}\n'
		exit 0
	fi

	if [ "${mode}" = "wrapper" ]; then
		local wrapper_content
		wrapper_content="$(
			cat <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FRAMEWORK_DIR="${MCPBASH_HOME:-$HOME/mcp-bash-framework}"

if [ ! -f "${FRAMEWORK_DIR}/bin/mcp-bash" ]; then
	printf 'Error: mcp-bash framework not found at %s\n' "${FRAMEWORK_DIR}" >&2
	printf 'Install: git clone https://github.com/yaniv-golan/mcp-bash-framework.git "%s"\n' "${FRAMEWORK_DIR}" >&2
	exit 1
fi

export MCPBASH_PROJECT_ROOT="${SCRIPT_DIR}"
exec "${FRAMEWORK_DIR}/bin/mcp-bash" "$@"
EOF
		)"

		# Validate server name is safe for use as filename
		if ! mcp_scaffold_validate_name "${server_name}"; then
			printf 'Server name "%s" contains invalid characters for filename.\n' "${server_name}" >&2
			printf 'Use alphanumerics, dot, underscore, dash only. Pipe to cat for stdout.\n' >&2
			printf '%s\n' "${wrapper_content}"
			exit 0
		fi

		# Non-TTY (piped/redirected): write to stdout
		if [[ ! -t 1 ]]; then
			printf '%s\n' "${wrapper_content}"
			exit 0
		fi

		# Interactive TTY mode: create file in project root

		local wrapper_filename="${server_name}.sh"
		local wrapper_path="${MCPBASH_PROJECT_ROOT}/${wrapper_filename}"

		if [[ -e "${wrapper_path}" ]]; then
			printf 'File already exists: %s\n' "${wrapper_path}" >&2
			printf 'Delete the file and retry, or pipe to cat for stdout.\n' >&2
			exit 1
		fi

		printf '%s\n' "${wrapper_content}" >"${wrapper_path}"
		chmod +x "${wrapper_path}"
		printf 'Wrapper script created: %s\n' "${wrapper_path}" >&2
		exit 0
	fi

	if [ "${mode}" = "inspector" ]; then
		local env_arg=""
		if [ "${has_project_root}" = "true" ]; then
			env_arg="-e MCPBASH_PROJECT_ROOT=${MCPBASH_PROJECT_ROOT}"
		fi
		local command_escaped
		command_escaped="$(printf '%q' "${command_path}")"

		if [ -n "${env_arg}" ]; then
			printf 'npx @modelcontextprotocol/inspector %s --transport stdio -- %s\n' "${env_arg}" "${command_escaped}"
		else
			printf 'npx @modelcontextprotocol/inspector --transport stdio -- %s\n' "${command_escaped}"
		fi
		exit 0
	fi

	print_client() {
		local client="${1}"
		local display_command="${command_path_json}"
		case "${client}" in
		claude-desktop)
			printf '{\n'
			printf '  "mcpServers": {\n'
			printf '    %s: {\n' "${server_name_json}"
			printf '      "command": %s' "${display_command}"
			if [ "${has_project_root}" = "true" ]; then
				printf ',\n      "env": {\n'
				printf '        "MCPBASH_PROJECT_ROOT": %s\n' "${project_root_json}"
				printf '      }'
			fi
			printf '\n    }\n'
			printf '  }\n'
			printf '}\n\n'
			;;
		cursor)
			printf '{\n'
			printf '  "mcpServers": {\n'
			printf '    %s: {\n' "${server_name_json}"
			printf '      "command": %s' "${display_command}"
			if [ "${has_project_root}" = "true" ]; then
				printf ',\n      "env": {\n'
				printf '        "MCPBASH_PROJECT_ROOT": %s\n' "${project_root_json}"
				printf '      }'
			fi
			printf '\n    }\n'
			printf '  }\n'
			printf '}\n\n'
			;;
		claude-cli)
			printf '{\n'
			printf '  "name": %s,\n' "${server_name_json}"
			printf '  "command": %s' "${display_command}"
			if [ "${has_project_root}" = "true" ]; then
				printf ',\n  "env": {\n'
				printf '    "MCPBASH_PROJECT_ROOT": %s\n' "${project_root_json}"
				printf '  }'
			fi
			printf '\n}\n\n'
			;;
		windsurf)
			printf '{\n'
			printf '  "mcpServers": {\n'
			printf '    %s: {\n' "${server_name_json}"
			printf '      "command": %s' "${display_command}"
			if [ "${has_project_root}" = "true" ]; then
				printf ',\n      "env": {\n'
				printf '        "MCPBASH_PROJECT_ROOT": %s\n' "${project_root_json}"
				printf '      }'
			fi
			printf '\n    }\n'
			printf '  }\n'
			printf '}\n\n'
			;;
		librechat)
			printf '{\n'
			printf '  "name": %s,\n' "${server_name_json}"
			printf '  "command": %s' "${display_command}"
			if [ "${has_project_root}" = "true" ]; then
				printf ',\n  "env": {\n'
				printf '    "MCPBASH_PROJECT_ROOT": %s\n' "${project_root_json}"
				printf '  }'
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
