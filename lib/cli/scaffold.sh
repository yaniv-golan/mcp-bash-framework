#!/usr/bin/env bash
# Scaffold subcommands (server, tool, prompt, resource, test).

set -euo pipefail

if [[ -z "${BASH_VERSION:-}" ]]; then
	printf 'Bash is required for mcp-bash scaffolding; BASH_VERSION missing\n' >&2
	exit 1
fi

# Globals: MCPBASH_HOME (from bin), MCPBASH_PROJECT_ROOT and content dirs, usage() from bin.

cli_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/cli/common.sh
. "${cli_dir}/common.sh"

mcp_scaffold_tool() {
	local name="$1"
	mcp_scaffold_require_project_root
	initialize_scaffold_paths
	local scaffold_dir="${MCPBASH_HOME}/scaffold/tool"
	local target_dir="${MCPBASH_TOOLS_DIR}/${name}"
	mcp_scaffold_prepare "tool" "${name}" "${scaffold_dir}" "${target_dir}" "Tool"
	mcp_template_render "${scaffold_dir}/tool.sh" "${target_dir}/tool.sh" "__NAME__=${name}"
	chmod +x "${target_dir}/tool.sh"
	mcp_template_render "${scaffold_dir}/tool.meta.json" "${target_dir}/tool.meta.json" "__NAME__=${name}"
	mcp_template_render "${scaffold_dir}/README.md" "${target_dir}/README.md" "__NAME__=${name}"
	printf 'Scaffolded tool at %s\n' "${target_dir}"
	exit 0
}

mcp_scaffold_server() {
	local name="$1"
	if [ -z "${name}" ]; then
		printf 'Server name required\n' >&2
		exit 1
	fi
	if ! mcp_scaffold_validate_name "${name}"; then
		printf 'Invalid server name: use alphanumerics, dot, underscore, dash only; no paths or traversal.\n' >&2
		exit 1
	fi

	local project_root="${PWD%/}/${name}"
	if [ -e "${project_root}" ]; then
		printf 'Target %s already exists (remove it or choose a new server name)\n' "${project_root}" >&2
		exit 1
	fi

	mkdir -p "${project_root}"
	printf 'Created project at ./%s/\n\n' "${name}"

	# Reuse the same skeleton initializer as `init`, always creating the hello tool.
	mcp_init_project_skeleton "${project_root}" "${name}" "true"

	# Optional README from scaffold templates, if present.
	local server_scaffold_dir="${MCPBASH_HOME:-}"
	if [ -n "${server_scaffold_dir}" ]; then
		server_scaffold_dir="${server_scaffold_dir}/scaffold/server"
		if [ -d "${server_scaffold_dir}" ] && [ -f "${server_scaffold_dir}/README.md" ]; then
			cp "${server_scaffold_dir}/README.md" "${project_root}/README.md"
		fi
	fi

	printf '\nNext steps:\n'
	printf '  cd %s\n' "${name}"
	printf '  mcp-bash scaffold tool <name>\n'

	exit 0
}

mcp_scaffold_prompt() {
	local name="$1"
	mcp_scaffold_require_project_root
	initialize_scaffold_paths
	local scaffold_dir="${MCPBASH_HOME}/scaffold/prompt"
	local target_dir="${MCPBASH_PROMPTS_DIR}/${name}"
	mcp_scaffold_prepare "prompt" "${name}" "${scaffold_dir}" "${target_dir}" "Prompt"
	mcp_template_render "${scaffold_dir}/prompt.txt" "${target_dir}/${name}.txt" "__NAME__=${name}"
	mcp_template_render "${scaffold_dir}/prompt.meta.json" "${target_dir}/${name}.meta.json" "__NAME__=${name}"
	mcp_template_render "${scaffold_dir}/README.md" "${target_dir}/README.md" "__NAME__=${name}"
	printf 'Scaffolded prompt at %s\n' "${target_dir}"
	exit 0
}

mcp_scaffold_resource() {
	local name="$1"
	mcp_scaffold_require_project_root
	initialize_scaffold_paths
	local scaffold_dir="${MCPBASH_HOME}/scaffold/resource"
	local target_dir="${MCPBASH_RESOURCES_DIR}/${name}"
	mcp_scaffold_prepare "resource" "${name}" "${scaffold_dir}" "${target_dir}" "Resource"
	local resource_path="${target_dir}/${name}.txt"
	local resource_uri
	if ! resource_uri="$(mcp_file_uri_from_path "${resource_path}")"; then
		printf 'Unable to compute resource URI for %s\n' "${resource_path}" >&2
		exit 1
	fi
	mcp_template_render "${scaffold_dir}/resource.txt" "${resource_path}" "__NAME__=${name}"
	mcp_template_render "${scaffold_dir}/resource.meta.json" "${target_dir}/${name}.meta.json" "__NAME__=${name}" "__RESOURCE_URI__=${resource_uri}"
	mcp_template_render "${scaffold_dir}/README.md" "${target_dir}/README.md" "__NAME__=${name}"
	printf 'Scaffolded resource at %s\n' "${target_dir}"
	exit 0
}

mcp_scaffold_test() {
	mcp_scaffold_require_project_root
	initialize_scaffold_paths

	local test_dir="${MCPBASH_PROJECT_ROOT}/test"
	local scaffold_dir="${MCPBASH_HOME}/scaffold/test"

	if [ ! -d "${scaffold_dir}" ]; then
		printf 'Scaffold templates missing at %s\n' "${scaffold_dir}" >&2
		exit 1
	fi
	if [ -e "${test_dir}/run.sh" ]; then
		printf 'test/run.sh already exists (remove it to re-scaffold)\n' >&2
		exit 1
	fi
	if [ -e "${test_dir}/README.md" ]; then
		printf 'test/README.md already exists (remove it to re-scaffold)\n' >&2
		exit 1
	fi

	mkdir -p "${test_dir}"

	cp "${scaffold_dir}/run.sh" "${test_dir}/run.sh"
	chmod +x "${test_dir}/run.sh"
	cp "${scaffold_dir}/README.md" "${test_dir}/README.md"

	printf 'Scaffolded test harness at %s\n' "${test_dir}"
	printf '\nNext steps:\n'
	printf '  1. Edit test/run.sh and add run_test calls for your tools\n'
	printf '  2. Run: ./test/run.sh\n'
	exit 0
}
