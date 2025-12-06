#!/usr/bin/env bash
# CLI validate command.

set -euo pipefail

if [[ -z "${BASH_VERSION:-}" ]]; then
	printf 'Bash is required for mcp-bash validate; BASH_VERSION missing\n' >&2
	exit 1
fi

# Globals: usage() from bin, MCPBASH_PROJECT_ROOT and runtime globals set by initialize_runtime_paths.

mcp_cli_validate() {
	local project_root=""
	local fix="false"

	while [ $# -gt 0 ]; do
		case "$1" in
		--project-root)
			shift
			project_root="${1:-}"
			;;
		--fix)
			fix="true"
			;;
		--help | -h)
			cat <<'EOF'
Usage:
  mcp-bash validate [--project-root DIR] [--fix]

Validate the current MCP project structure and metadata.
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

	project_root="${MCPBASH_PROJECT_ROOT}"
	printf 'Validating project at %s...\n\n' "${project_root}"

	local errors=0
	local warnings=0
	local fixes_applied=0
	local json_tool_available="false"
	local tools_root="${MCPBASH_TOOLS_DIR}"
	local prompts_root="${MCPBASH_PROMPTS_DIR}"
	local resources_root="${MCPBASH_RESOURCES_DIR}"

	if [ "${MCPBASH_JSON_TOOL:-none}" != "none" ] && [ -n "${MCPBASH_JSON_TOOL_BIN:-}" ]; then
		json_tool_available="true"
	fi

	local output counts

	output="$(mcp_validate_server_meta "${json_tool_available}")"
	printf '%s\n' "${output}" | sed '$d'
	counts="$(printf '%s\n' "${output}" | tail -n 1)"
	# shellcheck disable=SC2086  # Intentional splitting of counts
	set -- ${counts}
	errors=$((errors + $1))
	warnings=$((warnings + $2))

	output="$(mcp_validate_tools "${tools_root}" "${json_tool_available}" "${fix}")"
	printf '%s\n' "${output}" | sed '$d'
	counts="$(printf '%s\n' "${output}" | tail -n 1)"
	# shellcheck disable=SC2086  # Intentional splitting of counts
	set -- ${counts}
	errors=$((errors + $1))
	warnings=$((warnings + $2))
	fixes_applied=$((fixes_applied + $3))

	output="$(mcp_validate_prompts "${prompts_root}" "${json_tool_available}" "${fix}")"
	printf '%s\n' "${output}" | sed '$d'
	counts="$(printf '%s\n' "${output}" | tail -n 1)"
	# shellcheck disable=SC2086  # Intentional splitting of counts
	set -- ${counts}
	errors=$((errors + $1))
	warnings=$((warnings + $2))
	fixes_applied=$((fixes_applied + $3))

	output="$(mcp_validate_resources "${resources_root}" "${json_tool_available}" "${fix}")"
	printf '%s\n' "${output}" | sed '$d'
	counts="$(printf '%s\n' "${output}" | tail -n 1)"
	# shellcheck disable=SC2086  # Intentional splitting of counts
	set -- ${counts}
	errors=$((errors + $1))
	warnings=$((warnings + $2))
	fixes_applied=$((fixes_applied + $3))

	printf '\n'
	if [ "${fix}" = "true" ]; then
		if [ "${errors}" -gt 0 ]; then
			printf '%d error(s) remaining. Please fix manually.\n' "${errors}"
			exit 1
		fi
		if [ "${fixes_applied}" -gt 0 ]; then
			printf 'All remaining issues are warnings. %d file(s) were auto-fixed.\n' "${fixes_applied}"
		else
			printf 'All checks passed (no errors).\n'
		fi
		exit 0
	fi

	if [ "${errors}" -gt 0 ]; then
		printf '%d error(s) found. Run '\''mcp-bash validate --fix'\'' to fix auto-fixable issues.\n' "${errors}"
		exit 1
	fi

	printf 'All checks passed (warnings: %d).\n' "${warnings}"
	exit 0
}
