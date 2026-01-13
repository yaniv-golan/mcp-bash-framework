#!/usr/bin/env bash
# Health/readiness probe for proxy deployments.

set -euo pipefail

# Project health check helpers ------------------------------------------------
# These are exported for use in server.d/health-checks.sh

mcp_health_check_command() {
	local cmd="$1"
	local msg="${2:-Required command: ${cmd}}"

	if command -v "${cmd}" >/dev/null 2>&1; then
		printf '  ✓ %s\n' "${msg}" >&2
		return 0
	else
		printf '  ✗ %s (not found in PATH)\n' "${msg}" >&2
		return 1
	fi
}

mcp_health_check_env() {
	local var="$1"
	local msg="${2:-Required env var: ${var}}"

	if [ -n "${!var:-}" ]; then
		printf '  ✓ %s\n' "${msg}" >&2
		return 0
	else
		printf '  ✗ %s (not set)\n' "${msg}" >&2
		return 1
	fi
}

# shellcheck disable=SC2120  # Optional arg defaults to MCPBASH_PROJECT_ROOT
mcp_health_run_project_checks() {
	local project_root="${1:-${MCPBASH_PROJECT_ROOT:-}}"
	local checks_file="${project_root}/server.d/health-checks.sh"

	if [ ! -f "${checks_file}" ]; then
		return 0
	fi

	# Validate ownership/permissions (same checks as register.sh)
	if ! mcp_registry_register_check_permissions "${checks_file}"; then
		printf '  ⚠ Skipping health-checks.sh: ownership/permissions issue\n' >&2
		return 0
	fi

	printf 'Running project health checks...\n' >&2

	# Export helper functions for the hook
	export -f mcp_health_check_command
	export -f mcp_health_check_env

	# Source and run in subshell (redirect stdout to stderr to avoid contaminating JSON output)
	local rc=0
	(
		# shellcheck disable=SC1090
		source "${checks_file}"
	) >&2 || rc=$?

	if [ ${rc} -eq 0 ]; then
		printf '  ✓ Project health checks passed\n' >&2
	else
		printf '  ✗ Project health checks failed\n' >&2
	fi

	return ${rc}
}

mcp_cli_health_resolve_project_root() {
	local override_root="$1"
	local resolved=""

	if [ -n "${override_root}" ]; then
		if [ ! -d "${override_root}" ]; then
			printf 'mcp-bash health: project root not found: %s\n' "${override_root}" >&2
			return 2
		fi
		resolved="$(cd -P "${override_root}" && pwd)"
	elif [ -n "${MCPBASH_PROJECT_ROOT:-}" ]; then
		if [ ! -d "${MCPBASH_PROJECT_ROOT}" ]; then
			printf 'mcp-bash health: MCPBASH_PROJECT_ROOT does not exist: %s\n' "${MCPBASH_PROJECT_ROOT}" >&2
			return 2
		fi
		resolved="$(cd -P "${MCPBASH_PROJECT_ROOT}" && pwd)"
	else
		if ! resolved="$(mcp_runtime_find_project_root "${PWD}")"; then
			printf '%s\n' "mcp-bash health: no project root detected (set MCPBASH_PROJECT_ROOT or use --project-root)" >&2
			return 2
		fi
	fi

	printf '%s' "${resolved}"
	return 0
}

mcp_cli_health_normalize_timeout() {
	local value="$1"
	case "${value}" in
	'' | *[!0-9]*) printf '5' ;;
	0) printf '5' ;;
	*) printf '%s' "${value}" ;;
	esac
}

mcp_cli_health_probe() {
	if mcp_runtime_is_minimal_mode; then
		printf '%s\n' '{"status":"error","reason":"json_tool_missing"}'
		return 2
	fi

	# shellcheck disable=SC2034  # Reset discovery TTLs for probe run.
	MCP_TOOLS_LAST_SCAN=0
	# shellcheck disable=SC2034
	MCP_RESOURCES_LAST_SCAN=0
	# shellcheck disable=SC2034
	MCP_PROMPTS_LAST_SCAN=0

	local tools_status="ok" resources_status="ok" prompts_status="ok" project_status="ok"
	local fatal=0 any_fail=0

	if ! mcp_tools_refresh_registry; then
		tools_status="failed"
		case "$?" in
		2) fatal=1 ;;
		*) any_fail=1 ;;
		esac
	fi
	if ! mcp_resources_refresh_registry; then
		resources_status="failed"
		case "$?" in
		2) fatal=1 ;;
		*) any_fail=1 ;;
		esac
	fi
	if ! mcp_prompts_refresh_registry; then
		prompts_status="failed"
		case "$?" in
		2) fatal=1 ;;
		*) any_fail=1 ;;
		esac
	fi

	# Run optional project health checks (server.d/health-checks.sh)
	# shellcheck disable=SC2119  # Uses MCPBASH_PROJECT_ROOT default
	if ! mcp_health_run_project_checks; then
		project_status="failed"
		any_fail=1
	fi

	local mode="full" overall="ok"
	if mcp_runtime_is_minimal_mode; then
		mode="minimal"
	fi
	if [ "${fatal}" -eq 1 ] || [ "${any_fail}" -eq 1 ]; then
		overall="unhealthy"
	fi

	local js_overall js_mode js_tool js_res js_prom js_json_tool js_proj
	js_overall="$(mcp_json_quote_text "${overall}")"
	js_mode="$(mcp_json_quote_text "${mode}")"
	js_tool="$(mcp_json_quote_text "${tools_status}")"
	js_res="$(mcp_json_quote_text "${resources_status}")"
	js_prom="$(mcp_json_quote_text "${prompts_status}")"
	js_json_tool="$(mcp_json_quote_text "${MCPBASH_JSON_TOOL:-none}")"
	js_proj="$(mcp_json_quote_text "${project_status}")"

	printf '{"status":%s,"mode":%s,"jsonTool":%s,"tools":%s,"resources":%s,"prompts":%s,"projectChecks":%s}\n' \
		"${js_overall}" \
		"${js_mode}" \
		"${js_json_tool}" \
		"${js_tool}" \
		"${js_res}" \
		"${js_prom}" \
		"${js_proj}"

	if [ "${fatal}" -eq 1 ] || [ "${any_fail}" -eq 1 ]; then
		return 1
	fi

	return 0
}

mcp_cli_health() {
	local project_root=""
	local timeout_secs="${MCPBASH_HEALTH_TIMEOUT_SECS:-5}"

	while [ $# -gt 0 ]; do
		case "$1" in
		--project-root)
			shift
			project_root="${1:-}"
			;;
		--timeout)
			shift
			timeout_secs="${1:-}"
			;;
		--health | --ready) ;;
		*)
			usage
			exit 1
			;;
		esac
		shift
	done

	require_bash_runtime
	initialize_runtime_paths

	MCPBASH_LOG_LEVEL="error"
	MCPBASH_QUIET="true"
	export MCPBASH_LOG_LEVEL MCPBASH_QUIET

	local resolved_root status
	resolved_root="$(mcp_cli_health_resolve_project_root "${project_root}")"
	status=$?
	if [ "${status}" -ne 0 ]; then
		exit "${status}"
	fi

	MCPBASH_PROJECT_ROOT="${resolved_root}"
	export MCPBASH_PROJECT_ROOT

	mcp_runtime_init_paths "cli"
	mcp_lock_init
	mcp_runtime_detect_json_tool
	mcp_runtime_log_batch_mode
	if ! mcp_auth_init; then
		exit 2
	fi

	MCPBASH_REGISTRY_REFRESH_NO_NOTIFY="true"
	MCPBASH_REGISTRY_REFRESH_NO_WRITE="true"
	export MCPBASH_REGISTRY_REFRESH_NO_NOTIFY MCPBASH_REGISTRY_REFRESH_NO_WRITE

	timeout_secs="$(
		mcp_cli_health_normalize_timeout "${timeout_secs}"
	)"

	# errexit-safe: capture exit code without toggling shell state
	local rc=0 probe_rc=0
	with_timeout "${timeout_secs}" -- mcp_cli_health_probe && probe_rc=0 || probe_rc=$?

	case "${probe_rc}" in
	0) rc=0 ;;
	124) rc=1 ;;
	*) rc="${probe_rc}" ;;
	esac

	exit "${rc}"
}
