#!/usr/bin/env bash
# CLI run-tool command and helpers.

set -euo pipefail

if [[ -z "${BASH_VERSION:-}" ]]; then
	printf 'Bash is required for mcp-bash run-tool; BASH_VERSION missing\n' >&2
	exit 1
fi

# Ensure roots helpers are available for validation.
if ! command -v mcp_roots_normalize_path >/dev/null 2>&1; then
	# shellcheck source=../roots.sh disable=SC1090,SC1091
	. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/roots.sh"
fi
if ! command -v mcp_json_extract_file_required >/dev/null 2>&1; then
	# shellcheck source=../json.sh disable=SC1090,SC1091
	. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/json.sh"
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
	MCP_TOOLS_REGISTRY_HASH="$(mcp_json_extract_file_required "${cache_path}" "-r" '.hash // empty' "run-tool: invalid tools registry cache")" || return 1
	if [ -z "${MCP_TOOLS_REGISTRY_HASH}" ]; then
		printf 'run-tool: invalid tools registry cache (missing hash)\n' >&2
		return 1
	fi
	# shellcheck disable=SC2034
	MCP_TOOLS_TOTAL="$(mcp_json_extract_file_required "${cache_path}" "-r" '.total // 0 | tostring' "run-tool: invalid tools registry cache")" || return 1
	case "${MCP_TOOLS_TOTAL}" in
	'' | *[!0-9]*)
		printf 'run-tool: invalid tools registry cache (non-numeric total)\n' >&2
		return 1
		;;
	esac
	# shellcheck disable=SC2034
	MCP_TOOLS_LAST_SCAN="$(date +%s)"
	MCP_TOOLS_TTL="${MCP_TOOLS_TTL:-31536000}"
}

mcp_cli_run_tool_prepare_roots() {
	local roots_arg="$1"
	# shellcheck disable=SC2034  # Consumed by roots helpers after CLI setup
	MCPBASH_ROOTS_PATHS=()
	# shellcheck disable=SC2034
	MCPBASH_ROOTS_URIS=()
	# shellcheck disable=SC2034
	MCPBASH_ROOTS_NAMES=()
	[ -z "${roots_arg}" ] && return 0
	local had_error=0
	local IFS=',' root
	for root in ${roots_arg}; do
		[ -n "${root}" ] || continue
		local norm
		if ! norm="$(mcp_roots_canonicalize_checked "${root}" "--roots" 1)"; then
			had_error=1
			continue
		fi
		mcp_roots_append_unique "${norm}" "$(basename "${norm}")"
	done
	# roots.sh is always sourced for CLI runs, so mcp_roots_wait_ready will see READY=1.
	# shellcheck disable=SC2034  # Used by mcp_roots_wait_ready downstream
	MCPBASH_ROOTS_READY=1
	return "${had_error}"
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
	local print_env="false"
	local allow_self="false"
	local allow_all="false"
	local allow_names=()
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
		--print-env)
			print_env="true"
			;;
		--allow-self)
			allow_self="true"
			;;
		--allow)
			shift
			if [ -z "${1:-}" ]; then
				printf 'run-tool: --allow requires a tool name\n' >&2
				exit 1
			fi
			allow_names+=("$1")
			;;
		--allow-all)
			allow_all="true"
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
                     [--minimal] [--project-root DIR] [--print-env]
                     [--allow-self] [--allow TOOL] [--allow-all]

Invoke a tool directly with the same env wiring used by the server.

Examples:
  # Allow just this invocation
  mcp-bash run-tool hello --allow-self --args @args.json
  mcp-bash run-tool hello --allow hello --args @args.json
  # Unsafe (trusted projects only):
  mcp-bash run-tool hello --allow-all --args @args.json
  mcp-bash run-tool hello --args @args.json --roots .
  mcp-bash run-tool hello --print-env --dry-run
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

	# Per-invocation allow policy for CLI runs. This keeps the global default
	# deny posture while letting explicit CLI calls opt in narrowly.
	if [ "${allow_all}" = "true" ]; then
		MCPBASH_TOOL_ALLOWLIST="*"
		export MCPBASH_TOOL_ALLOWLIST
	elif [ "${allow_self}" = "true" ] || [ "${#allow_names[@]}" -gt 0 ] 2>/dev/null; then
		local allowlist="${tool_name}"
		if [ "${allow_self}" != "true" ]; then
			allowlist=""
		fi
		local idx
		for idx in "${!allow_names[@]}"; do
			local entry="${allow_names[${idx}]}"
			[ -n "${entry}" ] || continue
			if [ -n "${allowlist}" ]; then
				allowlist="${allowlist} ${entry}"
			else
				allowlist="${entry}"
			fi
		done
		MCPBASH_TOOL_ALLOWLIST="${allowlist}"
		export MCPBASH_TOOL_ALLOWLIST
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

	if ! mcp_cli_run_tool_prepare_roots "${roots_arg}"; then
		printf 'run-tool: invalid --roots value; see log for details\n' >&2
		exit 1
	fi

	if [ "${MCPBASH_JSON_TOOL:-none}" = "none" ] || [ -z "${MCPBASH_JSON_TOOL_BIN:-}" ] || [ "${MCPBASH_MODE:-full}" = "minimal" ]; then
		if [ "${args_json}" != "{}" ]; then
			printf 'run-tool: JSON tooling required to parse --args\n' >&2
		else
			printf 'run-tool: JSON tooling required (jq or gojq)\n' >&2
		fi
		exit 1
	fi

	if [ "${print_env}" = "true" ]; then
		printf 'MCPBASH_PROJECT_ROOT=%s\n' "${MCPBASH_PROJECT_ROOT}"
		printf 'MCPBASH_HOME=%s\n' "${MCPBASH_HOME}"
		printf 'MCP_SDK=%s\n' "${MCP_SDK:-}"
		printf 'MCPBASH_MODE=%s\n' "${MCPBASH_MODE:-}"
		if [ "${#MCPBASH_ROOTS_PATHS[@]}" -gt 0 ] 2>/dev/null; then
			local idx
			for idx in "${!MCPBASH_ROOTS_PATHS[@]}"; do
				printf 'ROOT[%d]=%s\n' "${idx}" "${MCPBASH_ROOTS_PATHS[${idx}]}"
			done
		else
			printf 'ROOTS=none\n'
		fi
		exit 0
	fi

	if ! printf '%s' "${args_json}" | "${MCPBASH_JSON_TOOL_BIN}" -e 'type=="object"' >/dev/null 2>&1; then
		printf 'run-tool: --args must be a JSON object\n' >&2
		exit 1
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

	# Let the policy layer tailor error messages for explicit CLI invocations.
	MCPBASH_TOOL_POLICY_CONTEXT="run-tool"
	export MCPBASH_TOOL_POLICY_CONTEXT

	local result_json=""
	# CLI invocations don't have request _meta; pass empty object
	if mcp_tools_call "${tool_name}" "${args_json}" "${effective_timeout}" "{}"; then
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
