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
	local wrapper_env="false"
	local label_snippets="false"

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
		--wrapper-env)
			mode="wrapper"
			wrapper_env="true"
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
  mcp-bash config [--project-root DIR] [--show|--json|--client NAME|--wrapper|--wrapper-env|--inspector]

Print MCP client configuration snippets for the current project.
  --wrapper   Generate auto-install wrapper script.
              Interactive: creates <project-root>/<name>.sh
              Piped/redirected: writes to stdout
  --wrapper-env Same as --wrapper but sources your shell profile (~/.zshrc, ~/.bash_profile, ~/.bashrc) before exec.
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
		if [ "${wrapper_env}" = "true" ]; then
			wrapper_content="$(
				cat <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SHELL_PROFILE=""

if [ -f "${HOME}/.zshrc" ]; then
	SHELL_PROFILE="${HOME}/.zshrc"
elif [ -f "${HOME}/.bash_profile" ]; then
	SHELL_PROFILE="${HOME}/.bash_profile"
elif [ -f "${HOME}/.bashrc" ]; then
	SHELL_PROFILE="${HOME}/.bashrc"
fi

if [ -n "${SHELL_PROFILE}" ]; then
	# shellcheck source=/dev/null
	. "${SHELL_PROFILE}"
fi

# Find mcp-bash: prefer PATH (via shell profile), then XDG location, then legacy
MCP_BASH=""
if command -v mcp-bash >/dev/null 2>&1; then
	MCP_BASH="$(command -v mcp-bash)"
elif [ -f "${HOME}/.local/bin/mcp-bash" ]; then
	MCP_BASH="${HOME}/.local/bin/mcp-bash"
elif [ -f "${MCPBASH_HOME:-}/bin/mcp-bash" ]; then
	MCP_BASH="${MCPBASH_HOME}/bin/mcp-bash"
fi

if [ -z "${MCP_BASH}" ]; then
	printf 'Error: mcp-bash not found in PATH or ~/.local/bin\n' >&2
	printf 'Install: curl -fsSL https://raw.githubusercontent.com/yaniv-golan/mcp-bash-framework/main/install.sh | bash\n' >&2
	exit 1
fi

export MCPBASH_PROJECT_ROOT="${SCRIPT_DIR}"
exec "${MCP_BASH}" "$@"
EOF
			)"
		else
			wrapper_content="$(
				cat <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Find mcp-bash: prefer PATH, then XDG location, then legacy
MCP_BASH=""
if command -v mcp-bash >/dev/null 2>&1; then
	MCP_BASH="$(command -v mcp-bash)"
elif [ -f "${HOME}/.local/bin/mcp-bash" ]; then
	MCP_BASH="${HOME}/.local/bin/mcp-bash"
elif [ -f "${MCPBASH_HOME:-}/bin/mcp-bash" ]; then
	MCP_BASH="${MCPBASH_HOME}/bin/mcp-bash"
fi

if [ -z "${MCP_BASH}" ]; then
	printf 'Error: mcp-bash not found in PATH or ~/.local/bin\n' >&2
	printf 'Install: curl -fsSL https://raw.githubusercontent.com/yaniv-golan/mcp-bash-framework/main/install.sh | bash\n' >&2
	exit 1
fi

export MCPBASH_PROJECT_ROOT="${SCRIPT_DIR}"
exec "${MCP_BASH}" "$@"
EOF
			)"
		fi

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
			local inspector_project_root="${MCPBASH_PROJECT_ROOT}"
			if [ -d "${inspector_project_root}" ]; then
				inspector_project_root="$(cd "${inspector_project_root}" && pwd -P 2>/dev/null || printf '%s' "${inspector_project_root}")"
			fi
			if command -v cygpath >/dev/null 2>&1; then
				inspector_project_root="$(cygpath -u "${inspector_project_root}")"
			fi
			env_arg="-e MCPBASH_PROJECT_ROOT=${inspector_project_root}"
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

	if [ "${mode}" = "show" ] && [ -z "${client_filter}" ]; then
		label_snippets="true"
	fi

	print_client() {
		local client="${1}"
		local display_command="${command_path_json}"
		local heading=""
		case "${client}" in
		claude-desktop)
			heading="Claude Desktop"
			if [ "${label_snippets}" = "true" ]; then
				printf '# %s\n' "${heading}"
			fi
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
			heading="Cursor"
			if [ "${label_snippets}" = "true" ]; then
				printf '# %s\n' "${heading}"
			fi
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
			heading="Claude CLI"
			if [ "${label_snippets}" = "true" ]; then
				printf '# %s\n' "${heading}"
			fi
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
			heading="Windsurf"
			if [ "${label_snippets}" = "true" ]; then
				printf '# %s\n' "${heading}"
			fi
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
			heading="LibreChat"
			if [ "${label_snippets}" = "true" ]; then
				printf '# %s\n' "${heading}"
			fi
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
