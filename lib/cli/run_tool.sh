#!/usr/bin/env bash
# CLI run-tool command and helpers.

set -euo pipefail

if [[ -z "${BASH_VERSION:-}" ]]; then
	printf 'Bash is required for mcp-bash run-tool; BASH_VERSION missing\n' >&2
	exit 1
fi

# Globals: usage() from bin, MCPBASH_PROJECT_ROOT, MCPBASH_JSON_TOOL[_BIN], MCPBASH_MODE and runtime globals set by initialize_runtime_paths.

mcp_cli_run_tool_load_cache() {
	local cache_path="${MCPBASH_PROJECT_ROOT}/.registry/tools.json"
	if [ ! -f "${cache_path}" ]; then
		printf 'run-tool: registry cache missing (expected %s)\n' "${cache_path}" >&2
		return 1
	fi
	if [ "${MCPBASH_JSON_TOOL:-none}" = "none" ] || [ -z "${MCPBASH_JSON_TOOL_BIN:-}" ]; then
		printf 'run-tool: JSON tooling required for --no-refresh\n' >&2
		return 1
	fi
	# shellcheck disable=SC2034  # Globals consumed by tools/runtime after CLI setup
	MCP_TOOLS_REGISTRY_JSON="$(cat "${cache_path}")"
	# shellcheck disable=SC2034
	MCP_TOOLS_REGISTRY_PATH="${cache_path}"
	# shellcheck disable=SC2034
	MCP_TOOLS_REGISTRY_HASH="$("${MCPBASH_JSON_TOOL_BIN}" -r '.hash // empty' "${cache_path}" 2>/dev/null || printf '')"
	# shellcheck disable=SC2034
	MCP_TOOLS_TOTAL="$("${MCPBASH_JSON_TOOL_BIN}" -r '.total // 0' "${cache_path}" 2>/dev/null || printf '0')"
	# shellcheck disable=SC2034
	MCP_TOOLS_LAST_SCAN="$(date +%s)"
	MCP_TOOLS_TTL="${MCP_TOOLS_TTL:-31536000}"
}

mcp_cli_run_tool_prepare_roots() {
	local roots_arg="$1"
	MCPBASH_ROOTS_PATHS=()
	MCPBASH_ROOTS_URIS=()
	MCPBASH_ROOTS_NAMES=()
	[ -z "${roots_arg}" ] && return 0
	local IFS=',' root
	for root in ${roots_arg}; do
		[ -n "${root}" ] || continue
		local norm
		norm="$(mcp_path_normalize --physical "${root}")"
		[ -n "${norm}" ] || continue
		MCPBASH_ROOTS_PATHS+=("${norm}")
		MCPBASH_ROOTS_URIS+=("file://${norm}")
		MCPBASH_ROOTS_NAMES+=("$(basename "${norm}")")
	done
	# roots.sh is always sourced for CLI runs, so mcp_roots_wait_ready will see READY=1.
	# shellcheck disable=SC2034  # Used by mcp_roots_wait_ready downstream
	MCPBASH_ROOTS_READY=1
}

mcp_cli_run_tool() {
	local project_root=""
	local args_json="{}"
	local roots_arg=""
	local dry_run="false"
	local timeout_override=""
	local verbose="false"
	local no_refresh="false"
	local minimal="false"
	local tool_name=""

	while [ $# -gt 0 ]; do
		case "$1" in
		--args)
			shift
			args_json="${1:-}"
			if [ -z "${args_json}" ]; then
				args_json="{}"
			fi
			;;
		--roots)
			shift
			roots_arg="${1:-}"
			;;
		--dry-run)
			dry_run="true"
			;;
		--timeout)
			shift
			timeout_override="${1:-}"
			;;
		--verbose)
			verbose="true"
			;;
		--no-refresh)
			no_refresh="true"
			;;
		--minimal)
			minimal="true"
			;;
		--project-root)
			shift
			project_root="${1:-}"
			;;
		--help | -h)
			cat <<'EOF'
Usage:
  mcp-bash run-tool <name> [--args JSON] [--roots paths] [--dry-run]
                     [--timeout SECS] [--verbose] [--no-refresh]
                     [--minimal] [--project-root DIR]

Invoke a tool directly with the same env wiring used by the server.
EOF
			exit 0
			;;
		--)
			shift
			break
			;;
		-*)
			usage
			exit 1
			;;
		*)
			if [ -z "${tool_name}" ]; then
				tool_name="${1}"
			else
				printf 'run-tool: unexpected argument: %s\n' "$1" >&2
				exit 1
			fi
			;;
		esac
		shift
	done

	if [ -z "${tool_name}" ]; then
		if [ $# -gt 0 ]; then
			tool_name="$1"
			shift
		else
			printf 'run-tool: tool name required\n' >&2
			exit 1
		fi
	fi

	# Allow explicit project override
	if [ -n "${project_root}" ]; then
		MCPBASH_PROJECT_ROOT="${project_root}"
		export MCPBASH_PROJECT_ROOT
	fi

	require_bash_runtime
	initialize_runtime_paths
	if [ "${minimal}" = "true" ]; then
		MCPBASH_FORCE_MINIMAL=true
		export MCPBASH_FORCE_MINIMAL
	fi
	mcp_runtime_init_paths "cli"
	mcp_runtime_detect_json_tool

	if [ "${no_refresh}" = "true" ]; then
		mcp_cli_run_tool_load_cache || exit 1
	fi

	mcp_cli_run_tool_prepare_roots "${roots_arg}"

	if [ "${MCPBASH_JSON_TOOL:-none}" != "none" ] && [ -n "${MCPBASH_JSON_TOOL_BIN:-}" ] && [ "${MCPBASH_MODE:-full}" != "minimal" ]; then
		if ! printf '%s' "${args_json}" | "${MCPBASH_JSON_TOOL_BIN}" -e 'type=="object"' >/dev/null 2>&1; then
			printf 'run-tool: --args must be a JSON object\n' >&2
			exit 1
		fi
	else
		if [ "${args_json}" != "{}" ]; then
			printf 'run-tool: JSON tooling required to parse --args\n' >&2
			exit 1
		fi
	fi

	local metadata=""
	if ! metadata="$(mcp_tools_metadata_for_name "${tool_name}")"; then
		printf 'run-tool: tool not found: %s\n' "${tool_name}" >&2
		exit 1
	fi

	local metadata_timeout
	metadata_timeout="$(printf '%s' "${metadata}" | "${MCPBASH_JSON_TOOL_BIN:-}" -r '.timeoutSecs // "" | tostring' 2>/dev/null || printf '')"
	if [ "${metadata_timeout}" = "null" ]; then
		metadata_timeout=""
	fi
	local effective_timeout="${timeout_override:-${metadata_timeout}}"

	if [ "${dry_run}" = "true" ]; then
		local roots_count=0
		if [ "${#MCPBASH_ROOTS_PATHS[@]}" -gt 0 ] 2>/dev/null; then
			roots_count="${#MCPBASH_ROOTS_PATHS[@]}"
		fi
		printf 'Tool: %s\n' "${tool_name}"
		printf 'Args: %s bytes\n' "$(printf '%s' "${args_json}" | wc -c | tr -d ' ')"
		printf 'Roots: %d\n' "${roots_count}"
		printf 'Timeout: %s\n' "${effective_timeout:-none}"
		printf 'Status: Ready to execute (re-run without --dry-run to run)\n'
		exit 0
	fi

	if [ "${verbose}" = "true" ]; then
		MCPBASH_TOOL_STREAM_STDERR=true
		export MCPBASH_TOOL_STREAM_STDERR
	fi

	local result_json=""
	if mcp_tools_call "${tool_name}" "${args_json}" "${effective_timeout}"; then
		result_json="${_MCP_TOOLS_RESULT:-}"
		printf '%s\n' "${result_json}"
		exit 0
	else
		if [ -n "${_MCP_TOOLS_RESULT:-}" ]; then
			printf '%s\n' "${_MCP_TOOLS_RESULT}"
		else
			printf 'run-tool: tool execution failed\n'
		fi
		exit 1
	fi
}
