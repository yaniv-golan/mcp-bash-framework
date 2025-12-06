#!/usr/bin/env bash
# CLI registry commands.

set -euo pipefail

if [[ -z "${BASH_VERSION:-}" ]]; then
	printf 'Bash is required for mcp-bash registry CLI; BASH_VERSION missing\n' >&2
	exit 1
fi

# Globals: usage() from bin, MCPBASH_PROJECT_ROOT, MCPBASH_HOME, runtime globals set by initialize_runtime_paths.

mcp_registry_refresh_cli() {
	local project_root=""
	local quiet="false"
	local no_notify="false"
	local filter_path=""

	while [ $# -gt 0 ]; do
		case "$1" in
		--project-root)
			shift
			project_root="${1:-}"
			;;
		--quiet)
			quiet="true"
			;;
		--no-notify)
			no_notify="true"
			;;
		--filter)
			shift
			filter_path="${1:-}"
			;;
		*)
			usage
			exit 1
			;;
		esac
		shift
	done

	# Set PROJECT_ROOT before library load
	if [ -n "${project_root}" ]; then
		MCPBASH_PROJECT_ROOT="${project_root}"
		export MCPBASH_PROJECT_ROOT
		no_notify="true" # implied by --project-root (offline mode)
	fi

	# Quiet mode (set before library load for logging)
	if [ "${quiet}" = "true" ]; then
		MCPBASH_LOG_LEVEL="error"
		MCPBASH_QUIET="true"
		export MCPBASH_LOG_LEVEL MCPBASH_QUIET
	fi

	# Filter path
	if [ -n "${filter_path}" ]; then
		export MCPBASH_REGISTRY_REFRESH_PATH="${filter_path}"
	fi

	# Load libraries and init paths with CLI mode
	require_bash_runtime
	initialize_runtime_paths
	mcp_runtime_init_paths "cli"
	mcp_lock_init
	mcp_runtime_detect_json_tool
	mcp_runtime_log_batch_mode

	if [ "${no_notify}" = "true" ]; then
		MCPBASH_REGISTRY_REFRESH_NO_NOTIFY="true"
		export MCPBASH_REGISTRY_REFRESH_NO_NOTIFY
	fi

	local mode="full"
	if mcp_runtime_is_minimal_mode; then
		mode="minimal"
	fi

	local tools_status="ok"
	local resources_status="ok"
	local prompts_status="ok"
	local tools_error=""
	local resources_error=""
	local prompts_error=""
	local fatal=0
	local any_fail=0

	if mcp_runtime_is_minimal_mode; then
		tools_status="skipped"
		resources_status="skipped"
		prompts_status="skipped"
		tools_error="minimal mode"
		resources_error="minimal mode"
		prompts_error="minimal mode"
	else
		# shellcheck disable=SC2034  # Globals consumed by refresh helpers
		MCP_TOOLS_LAST_SCAN=0
		# shellcheck disable=SC2034
		MCP_RESOURCES_LAST_SCAN=0
		# shellcheck disable=SC2034
		MCP_PROMPTS_LAST_SCAN=0

		mcp_tools_refresh_registry || {
			case "$?" in
			2) fatal=1 ;;
			*) any_fail=1 ;;
			esac
			tools_status="failed"
			tools_error="refresh failed"
		}
		mcp_resources_refresh_registry || {
			case "$?" in
			2) fatal=1 ;;
			*) any_fail=1 ;;
			esac
			resources_status="failed"
			resources_error="refresh failed"
		}
		mcp_prompts_refresh_registry || {
			case "$?" in
			2) fatal=1 ;;
			*) any_fail=1 ;;
			esac
			prompts_status="failed"
			prompts_error="refresh failed"
		}
	fi

	local tools_error_json resources_error_json prompts_error_json
	tools_error_json="null"
	resources_error_json="null"
	prompts_error_json="null"
	if [ -n "${tools_error}" ]; then
		tools_error_json="$(mcp_json_quote_text "${tools_error}")"
	fi
	if [ -n "${resources_error}" ]; then
		resources_error_json="$(mcp_json_quote_text "${resources_error}")"
	fi
	if [ -n "${prompts_error}" ]; then
		prompts_error_json="$(mcp_json_quote_text "${prompts_error}")"
	fi

	cat <<EOF
{
  "tools": {"status":"${tools_status}","count":${MCP_TOOLS_TOTAL:-0},"error":${tools_error_json}},
  "resources": {"status":"${resources_status}","count":${MCP_RESOURCES_TOTAL:-0},"error":${resources_error_json}},
  "prompts": {"status":"${prompts_status}","count":${MCP_PROMPTS_TOTAL:-0},"error":${prompts_error_json}},
  "notificationsSent": false,
  "mode": "${mode}"
}
EOF

	if [ "${fatal}" -eq 1 ]; then
		exit 2
	fi
	if [ "${any_fail}" -eq 1 ]; then
		exit 1
	fi
	exit 0
}

mcp_registry_status_cli() {
	local project_root=""

	while [ $# -gt 0 ]; do
		case "$1" in
		--project-root)
			shift
			project_root="${1:-}"
			;;
		*)
			usage
			exit 1
			;;
		esac
		shift
	done

	if [ -n "${project_root}" ]; then
		MCPBASH_PROJECT_ROOT="${project_root}"
		export MCPBASH_PROJECT_ROOT
	fi

	require_bash_runtime
	initialize_runtime_paths
	mcp_runtime_init_paths "cli"
	mcp_runtime_detect_json_tool

	local json_ok="false"
	if [ "${MCPBASH_JSON_TOOL:-none}" != "none" ] && [ -n "${MCPBASH_JSON_TOOL_BIN:-}" ]; then
		json_ok="true"
	fi

	read_registry_file() {
		local kind="$1"
		local path="${MCPBASH_PROJECT_ROOT}/.registry/${kind}.json"
		local status="missing"
		local count=0
		local hash=""
		local mtime=0
		if [ -f "${path}" ]; then
			status="present"
			mtime="$(mcp_registry_stat_mtime "${path}")"
			if [ "${json_ok}" = "true" ]; then
				count="$("${MCPBASH_JSON_TOOL_BIN}" -r '.total // (.tools? // .resources? // .prompts? // [] | length) // 0' "${path}" 2>/dev/null || printf '0')"
				hash="$("${MCPBASH_JSON_TOOL_BIN}" -r '.hash // ""' "${path}" 2>/dev/null || printf '')"
			fi
		fi
		cat <<EOF
{"status":"${status}","path":"${path}","count":${count:-0},"hash":"${hash}","mtime":${mtime:-0}}
EOF
	}

	local tools_json resources_json prompts_json
	tools_json="$(read_registry_file "tools")"
	resources_json="$(read_registry_file "resources")"
	prompts_json="$(read_registry_file "prompts")"

	cat <<EOF
{
  "projectRoot": "${MCPBASH_PROJECT_ROOT}",
  "jsonTool": "${MCPBASH_JSON_TOOL:-none}",
  "tools": ${tools_json},
  "resources": ${resources_json},
  "prompts": ${prompts_json}
}
EOF
}
