#!/usr/bin/env bash
# Shared helpers for CLI subcommands (scaffold/init/etc.).

set -euo pipefail

if [[ -z "${BASH_VERSION:-}" ]]; then
	printf 'Bash is required for mcp-bash CLI helpers; BASH_VERSION missing\n' >&2
	exit 1
fi

# Globals used:
# - MCPBASH_PROJECT_ROOT, MCPBASH_HOME, MCPBASH_TOOLS_DIR, MCPBASH_RESOURCES_DIR, MCPBASH_PROMPTS_DIR, MCPBASH_COMPLETIONS_DIR
# - MCPBASH_JSON_TOOL, MCPBASH_JSON_TOOL_BIN (via runtime helpers)
# - MCPBASH_PROTOCOL_VERSION (set in bin/mcp-bash)

mcp_template_render() {
	local template="$1"
	local output="$2"
	shift 2
	local content
	content="$(cat "${template}")"
	for pair in "$@"; do
		local key="${pair%%=*}"
		local value="${pair#*=}"
		content="${content//${key}/${value}}"
	done
	printf '%s' "${content}" >"${output}"
}

mcp_load_uri_helpers() {
	if declare -F mcp_uri_file_uri_from_path >/dev/null 2>&1; then
		return 0
	fi
	local script_dir
	script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
	# shellcheck source=../uri.sh disable=SC1090,SC1091
	. "${script_dir}/../uri.sh"
}

mcp_file_uri_from_path() {
	mcp_load_uri_helpers
	mcp_uri_file_uri_from_path "$1"
}

mcp_scaffold_validate_name() {
	local name="$1"
	# Allow simple names only: alnum, underscore, dash; no slashes, traversal, or dots (Some clients including Claude Desktop rejects them).
	if [ -z "${name}" ]; then
		return 1
	fi
	case "${name}" in
	*/* | *..*) return 1 ;;
	esac
	if ! [[ "${name}" =~ ^[A-Za-z0-9_-]{1,64}$ ]]; then
		return 1
	fi
	return 0
}

mcp_scaffold_prepare() {
	local kind="$1"
	local name="$2"
	local scaffold_dir="$3"
	local target_dir="$4"
	local label="$5"

	if [ -z "${name}" ]; then
		printf '%s name required\n' "${label}" >&2
		exit 1
	fi
	if ! mcp_scaffold_validate_name "${name}"; then
		printf 'Invalid %s name: use alphanumerics, underscore, dash only (1-64 chars); no dots, paths, or traversal (Some clients including Claude Desktop rejects dots).\n' "${kind}" >&2
		exit 1
	fi
	if [ ! -d "${scaffold_dir}" ]; then
		printf 'Scaffold templates missing at %s\n' "${scaffold_dir}" >&2
		exit 1
	fi
	if [ -e "${target_dir}" ]; then
		printf 'Target %s already exists (remove it or choose a new %s name)\n' "${target_dir}" "${kind}" >&2
		exit 1
	fi
	mkdir -p "${target_dir}"
}

# Require MCPBASH_PROJECT_ROOT for scaffolding commands
mcp_scaffold_require_project_root() {
	# Prefer explicit MCPBASH_PROJECT_ROOT when set, otherwise auto-detect based
	# on the current directory. Scaffolding never falls back to the bootstrap
	# project – a real project root is required.
	if [ -n "${MCPBASH_PROJECT_ROOT:-}" ]; then
		if [ ! -d "${MCPBASH_PROJECT_ROOT}" ]; then
			printf 'mcp-bash scaffold: MCPBASH_PROJECT_ROOT directory does not exist: %s\n' "${MCPBASH_PROJECT_ROOT}" >&2
			printf 'Create it first: mkdir -p %s\n' "${MCPBASH_PROJECT_ROOT}" >&2
			exit 1
		fi
		return 0
	fi

	# Load runtime helpers so we can reuse the project root discovery logic.
	require_bash_runtime
	initialize_runtime_paths

	if MCPBASH_PROJECT_ROOT="$(mcp_runtime_find_project_root "${PWD}")"; then
		export MCPBASH_PROJECT_ROOT
		return 0
	fi

	mcp_runtime_project_not_found_error
}

# Initialize paths for scaffolding (lighter than full runtime init)
initialize_scaffold_paths() {
	local script_dir=""
	if [ -z "${MCPBASH_HOME:-}" ]; then
		script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
		MCPBASH_HOME="$(cd "${script_dir}/.." && pwd)"
	else
		script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
	fi

	# Set content directory paths based on MCPBASH_PROJECT_ROOT
	if [ -z "${MCPBASH_TOOLS_DIR:-}" ]; then
		MCPBASH_TOOLS_DIR="${MCPBASH_PROJECT_ROOT}/tools"
	fi
	if [ -z "${MCPBASH_RESOURCES_DIR:-}" ]; then
		MCPBASH_RESOURCES_DIR="${MCPBASH_PROJECT_ROOT}/resources"
	fi
	if [ -z "${MCPBASH_PROMPTS_DIR:-}" ]; then
		MCPBASH_PROMPTS_DIR="${MCPBASH_PROJECT_ROOT}/prompts"
	fi
	if [ -z "${MCPBASH_COMPLETIONS_DIR:-}" ]; then
		MCPBASH_COMPLETIONS_DIR="${MCPBASH_PROJECT_ROOT}/completions"
	fi
	if [ -z "${MCPBASH_UI_DIR:-}" ]; then
		MCPBASH_UI_DIR="${MCPBASH_PROJECT_ROOT}/ui"
	fi
}

mcp_init_project_skeleton() {
	local project_root="$1"
	local name="$2"
	local create_hello="${3:-true}"

	# Load runtime helpers for title-casing.
	require_bash_runtime
	initialize_runtime_paths

	local title
	title="$(mcp_runtime_titlecase "${name}")"

	# server.d/server.meta.json
	local server_dir="${project_root}/server.d"
	local server_meta="${server_dir}/server.meta.json"
	if [ -f "${server_meta}" ]; then
		printf '  Skipped existing %s\n' "${server_meta}"
	else
		mkdir -p "${server_dir}"
		local server_template="${MCPBASH_HOME}/scaffold/server/server.meta.json"
		if [ -f "${server_template}" ]; then
			mcp_template_render "${server_template}" "${server_meta}" "__NAME__=${name}" "__TITLE__=${title}"
		else
			cat >"${server_meta}" <<EOF
{
  "name": "${name}",
  "title": "${title}",
  "version": "0.1.0",
  "description": "Description of your MCP server"
}
EOF
		fi
		printf '  Created %s\n' "${server_meta}"
	fi

	# tools/ directory
	local tools_dir="${project_root}/tools"
	if [ ! -d "${tools_dir}" ]; then
		mkdir -p "${tools_dir}"
		printf '  Created %s\n' "${tools_dir}"
	fi

	# .gitignore with registry/log entries
	local gitignore="${project_root}/.gitignore"
	if [ ! -f "${gitignore}" ]; then
		cat >"${gitignore}" <<'EOF'
# mcp-bash registry cache
.registry/

# Logs
*.log

# OS files
.DS_Store
Thumbs.db
EOF
		printf '  Created %s\n' "${gitignore}"
	else
		local updated_gitignore="false"
		if ! grep -qF '.registry/' "${gitignore}" 2>/dev/null; then
			printf '\n# mcp-bash registry cache\n.registry/\n' >>"${gitignore}"
			updated_gitignore="true"
		fi
		if ! grep -qF '*.log' "${gitignore}" 2>/dev/null; then
			printf '\n# Logs\n*.log\n' >>"${gitignore}"
			updated_gitignore="true"
		fi
		if ! grep -qF '.DS_Store' "${gitignore}" 2>/dev/null; then
			printf '\n# OS files\n.DS_Store\n' >>"${gitignore}"
			updated_gitignore="true"
		fi
		if ! grep -qF 'Thumbs.db' "${gitignore}" 2>/dev/null; then
			if ! grep -qF 'OS files' "${gitignore}" 2>/dev/null; then
				printf '\n# OS files\n' >>"${gitignore}"
			fi
			printf 'Thumbs.db\n' >>"${gitignore}"
			updated_gitignore="true"
		fi
		if [ "${updated_gitignore}" = "true" ]; then
			printf '  Updated %s\n' "${gitignore}"
		else
			printf '  Skipped existing %s\n' "${gitignore}"
		fi
	fi

	# Optional hello tool
	if [ "${create_hello}" = "true" ]; then
		local hello_dir="${tools_dir}/hello"
		if [ -d "${hello_dir}" ]; then
			printf '  Skipped existing hello tool at %s\n' "${hello_dir}"
		else
			mkdir -p "${hello_dir}"
			cat >"${hello_dir}/tool.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
source "${MCP_SDK:?MCP_SDK environment variable not set}/tool-sdk.sh"

name="$(mcp_args_get '.name // "World"')"

mcp_result_success "$(mcp_json_obj message "Hello, ${name}!")"
EOF
			chmod +x "${hello_dir}/tool.sh"
			cat >"${hello_dir}/tool.meta.json" <<'EOF'
{
  "name": "hello",
  "description": "A simple greeting tool - delete this once you add your own tools",
  "inputSchema": {
    "type": "object",
    "properties": {
      "name": {
        "type": "string",
        "description": "Name to greet (default: World)"
      }
    }
  },
  "outputSchema": {
    "type": "object",
    "required": ["success", "result"],
    "properties": {
      "success": { "type": "boolean" },
      "result": {
        "type": "object",
        "properties": {
          "message": { "type": "string" }
        }
      }
    }
  }
}
EOF
			printf '  Created hello tool at %s\n' "${hello_dir}"
		fi
	fi
}
