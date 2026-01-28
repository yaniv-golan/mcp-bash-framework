#!/usr/bin/env bash
# Scaffold subcommands (server, tool, prompt, resource, completion, test).

set -euo pipefail

if [[ -z "${BASH_VERSION:-}" ]]; then
	printf 'Bash is required for mcp-bash scaffolding; BASH_VERSION missing\n' >&2
	exit 1
fi

# Globals: MCPBASH_HOME (from bin), MCPBASH_PROJECT_ROOT and content dirs, usage() from bin.

cli_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/cli/common.sh
. "${cli_dir}/common.sh"

mcp_scaffold_register_completion() {
	local name="$1"
	local script_path="$2"
	local server_dir="${MCPBASH_PROJECT_ROOT}/server.d"
	local register_file="${server_dir}/register.sh"
	mkdir -p "${server_dir}"

	if [ ! -f "${register_file}" ]; then
		cat >"${register_file}" <<'EOF'
#!/usr/bin/env bash
# Manual registration script; invoked when executable (manual overrides).
# Preferred pattern is declarative: server.d/register.json (see examples/09-registry-overrides/server.d/register.json).
# Helper functions remain available for compatibility.

set -euo pipefail

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
	exit 0
fi
return 0
EOF
		chmod +x "${register_file}"
	fi

	if grep -Fq "\"name\":\"${name}\"" "${register_file}" 2>/dev/null; then
		printf 'Completion %s already registered in %s\n' "${name}" "${register_file}"
		return 0
	fi

	local snippet_file="${register_file}.snippet.$$"
	cat >"${snippet_file}" <<EOF
# mcp-bash scaffold completion: ${name}
mcp_completion_manual_begin
mcp_completion_register_manual '{"name":"${name}","path":"${script_path}","timeoutSecs":5}'
mcp_completion_manual_finalize

EOF

	local tmp="${register_file}.tmp"
	if grep -q '^return 0$' "${register_file}" 2>/dev/null; then
		awk -v snippet_file="${snippet_file}" '
			BEGIN {
				while ((getline line < snippet_file) > 0) {
					snippet = snippet line ORS
				}
				close(snippet_file)
				inserted = 0
			}
			/^return 0$/ && inserted == 0 {
				printf "%s", snippet
				inserted = 1
			}
			{ print }
			END {
				if (inserted == 0) {
					printf "%s", snippet
				}
			}
		' "${register_file}" >"${tmp}"
		mv "${tmp}" "${register_file}"
	else
		cat "${snippet_file}" >>"${register_file}"
	fi
	rm -f "${snippet_file}"

	printf 'Registered completion %s in %s\n' "${name}" "${register_file}"
}

mcp_scaffold_tool() {
	local name=""
	local with_ui=false

	# Parse arguments (handles both positional and flags)
	while [[ $# -gt 0 ]]; do
		case "$1" in
		--ui)
			with_ui=true
			shift
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
			shift
			;;
		esac
	done

	mcp_scaffold_require_project_root
	initialize_scaffold_paths
	local scaffold_dir="${MCPBASH_HOME}/scaffold/tool"
	local target_dir="${MCPBASH_TOOLS_DIR}/${name}"
	mcp_scaffold_prepare "tool" "${name}" "${scaffold_dir}" "${target_dir}" "Tool"

	mcp_template_render "${scaffold_dir}/tool.sh" "${target_dir}/tool.sh" "__NAME__=${name}"
	chmod +x "${target_dir}/tool.sh"

	# Always use standard tool.meta.json (no _meta.ui needed - framework auto-infers)
	mcp_template_render "${scaffold_dir}/tool.meta.json" "${target_dir}/tool.meta.json" "__NAME__=${name}"

	if [ "${with_ui}" = true ]; then
		# Also scaffold UI directory
		local ui_scaffold_dir="${MCPBASH_HOME}/scaffold/ui"
		if [ ! -d "${ui_scaffold_dir}" ]; then
			printf 'Error: UI scaffold template not found at %s\n' "${ui_scaffold_dir}" >&2
			exit 1
		fi
		local ui_target_dir="${target_dir}/ui"
		mkdir -p "${ui_target_dir}"
		mcp_template_render "${ui_scaffold_dir}/index.html" "${ui_target_dir}/index.html" "__NAME__=${name}"
		mcp_template_render "${ui_scaffold_dir}/ui.meta.json" "${ui_target_dir}/ui.meta.json" "__NAME__=${name}"
	fi

	mcp_template_render "${scaffold_dir}/README.md" "${target_dir}/README.md" "__NAME__=${name}"
	mcp_template_render "${scaffold_dir}/smoke.sh" "${target_dir}/smoke.sh" "__NAME__=${name}"
	chmod +x "${target_dir}/smoke.sh"

	printf 'Scaffolded tool at %s\n' "${target_dir}"
	if [ "${with_ui}" = true ]; then
		printf 'Scaffolded UI at %s/ui\n' "${target_dir}"
	fi
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

mcp_scaffold_completion() {
	local name="$1"
	mcp_scaffold_require_project_root
	initialize_scaffold_paths
	local scaffold_dir="${MCPBASH_HOME}/scaffold/completion"
	local target_dir="${MCPBASH_COMPLETIONS_DIR}/${name}"
	mcp_scaffold_prepare "completion" "${name}" "${scaffold_dir}" "${target_dir}" "Completion"

	mcp_template_render "${scaffold_dir}/completion.sh" "${target_dir}/completion.sh" "__NAME__=${name}"
	chmod +x "${target_dir}/completion.sh"
	mcp_template_render "${scaffold_dir}/README.md" "${target_dir}/README.md" "__NAME__=${name}"

	local script_path="completions/${name}/completion.sh"
	mcp_scaffold_register_completion "${name}" "${script_path}"

	printf 'Scaffolded completion at %s\n' "${target_dir}"
	exit 0
}

mcp_scaffold_ui() {
	local name=""
	local for_tool=""

	# Parse arguments (handles both positional and flags)
	while [[ $# -gt 0 ]]; do
		case "$1" in
		--tool)
			for_tool="$2"
			shift 2
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
			shift
			;;
		esac
	done

	mcp_scaffold_require_project_root
	initialize_scaffold_paths

	local scaffold_dir="${MCPBASH_HOME}/scaffold/ui"
	local target_dir

	if [ -n "${for_tool}" ]; then
		# Tool-associated UI - validate tool exists
		if [ ! -d "${MCPBASH_TOOLS_DIR}/${for_tool}" ]; then
			printf 'Error: Tool directory not found: tools/%s\n' "${for_tool}" >&2
			exit 1
		fi
		# Default name to tool name if not provided
		[ -z "${name}" ] && name="${for_tool}"
		target_dir="${MCPBASH_TOOLS_DIR}/${for_tool}/ui"
	else
		# Standalone UI - name is required
		if [ -z "${name}" ]; then
			printf 'Error: UI name required for standalone UIs\n' >&2
			exit 1
		fi
		target_dir="${MCPBASH_UI_DIR}/${name}"
	fi

	# mcp_scaffold_prepare handles: empty name, invalid name, missing templates, existing target_dir
	mcp_scaffold_prepare "ui" "${name}" "${scaffold_dir}" "${target_dir}" "UI"

	mcp_template_render "${scaffold_dir}/index.html" "${target_dir}/index.html" "__NAME__=${name}"
	mcp_template_render "${scaffold_dir}/ui.meta.json" "${target_dir}/ui.meta.json" "__NAME__=${name}"

	# Only create README for standalone UIs (tool has its own README)
	if [ -z "${for_tool}" ]; then
		mcp_template_render "${scaffold_dir}/README.md" "${target_dir}/README.md" "__NAME__=${name}"
	fi

	printf 'Scaffolded UI at %s\n' "${target_dir}"

	if [ -n "${for_tool}" ]; then
		printf '\nThe framework will automatically link this UI to the tool.\n'
		printf 'No manual _meta.ui configuration needed.\n'
	fi

	exit 0
}
