#!/usr/bin/env bash
# Target Runtime Environment: JSON tooling detection, minimal-mode controls, and compatibility flags.
# Path resolution for framework/project separation.

# shellcheck disable=SC2034
: "${MCPBASH_JSON_TOOL:=}"
# shellcheck disable=SC2034
: "${MCPBASH_JSON_TOOL_BIN:=}"
: "${MCPBASH_MODE:=}"
: "${MCPBASH_TMP_ROOT:=}"
: "${MCPBASH_LOCK_ROOT:=}"
: "${MCPBASH_STATE_DIR:=}"
: "${MCPBASH_STATE_SEED:=}"
: "${MCPBASH_CLEANUP_REGISTERED:=false}"
: "${MCPBASH_JOB_CONTROL_ENABLED:=false}"
: "${MCPBASH_PROCESS_GROUP_WARNED:=false}"
: "${MCPBASH_LOG_JSON_TOOL:=quiet}"
: "${MCPBASH_BOOTSTRAP_STAGED:=false}"
: "${MCPBASH_BOOTSTRAP_TMP_DIR:=}"
: "${MCPBASH_HOME:=}"
: "${MCPBASH_TRANSPORT:=}"
: "${MCPBASH_TRANSPORT_STDIO:=false}"

# Path normalization helpers (Bash 3.2+). Load if not already present.
if ! command -v mcp_path_normalize >/dev/null 2>&1; then
	# shellcheck source=lib/path.sh disable=SC1090,SC1091
	. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/path.sh"
fi

# Provide a no-op verbose check when logging.sh is not loaded (unit tests source runtime directly).
if ! command -v mcp_logging_verbose_enabled >/dev/null 2>&1; then
	mcp_logging_verbose_enabled() {
		return 1
	}
fi

# Content directory variables (set by mcp_runtime_init_paths)
: "${MCPBASH_REGISTRY_DIR:=}"
: "${MCPBASH_TOOLS_DIR:=}"
: "${MCPBASH_RESOURCES_DIR:=}"
: "${MCPBASH_PROMPTS_DIR:=}"
: "${MCPBASH_SERVER_DIR:=}"

mcp_runtime_log_allowed() {
	if [ "${MCPBASH_QUIET:-false}" = "true" ]; then
		return 1
	fi
	case "${MCPBASH_LOG_LEVEL:-info}" in
	error | critical | alert | emergency) return 1 ;;
	esac
	return 0
}

mcp_runtime_detect_transport() {
	# Transport detection is currently limited to stdio. If an unsupported value
	# is provided, fall back to stdio and warn on stderr to avoid stdout noise.
	local transport="${MCPBASH_TRANSPORT:-}"
	if [ -z "${transport}" ] && [ -n "${MCP_TRANSPORT:-}" ]; then
		transport="${MCP_TRANSPORT}"
	fi
	if [ -z "${transport}" ]; then
		transport="stdio"
	fi
	transport="$(printf '%s' "${transport}" | tr '[:upper:]' '[:lower:]')"

	case "${transport}" in
	stdio) ;;
	*)
		if mcp_runtime_log_allowed; then
			printf '%s\n' "mcp-bash: unsupported transport '${transport}'; defaulting to stdio." >&2
		fi
		transport="stdio"
		;;
	esac

	MCPBASH_TRANSPORT="${transport}"
	if [ "${transport}" = "stdio" ]; then
		MCPBASH_TRANSPORT_STDIO="true"
	else
		MCPBASH_TRANSPORT_STDIO="false"
	fi
	export MCPBASH_TRANSPORT MCPBASH_TRANSPORT_STDIO
}

mcp_runtime_is_stdio_transport() {
	[ "${MCPBASH_TRANSPORT_STDIO:-false}" = "true" ]
}

mcp_runtime_find_project_root() {
	# Walk up from the given directory to find a project marker (server.d/server.meta.json),
	# skipping any paths that live under MCPBASH_HOME (framework layout, examples, scaffold).
	# Prints the detected project root on success.
	local start_dir="${1:-${PWD}}"
	local dir="${start_dir}"

	# Resolve symlinks where possible for predictable behavior across platforms.
	dir="$(mcp_path_normalize --physical "${dir}")"

	while [ -n "${dir}" ] && [ "${dir}" != "/" ]; do
		# Skip framework-internal paths (bootstrap/, examples/, scaffold/, etc.)
		if [ -n "${MCPBASH_HOME:-}" ]; then
			case "${dir}" in
			"${MCPBASH_HOME}" | "${MCPBASH_HOME}/"*)
				dir="$(dirname "${dir}")"
				continue
				;;
			esac
		fi

		if [ -f "${dir}/server.d/server.meta.json" ]; then
			printf '%s' "${dir}"
			return 0
		fi

		dir="$(dirname "${dir}")"
	done

	return 1
}

mcp_runtime_project_not_found_error() {
	cat >&2 <<'EOF'
Error: No MCP project found.

Could not find server.d/server.meta.json in the current directory or any parent.

To create a new project here:
  mcp-bash init --name my-server

To specify a project explicitly:
  use --project-root /path/to/project or set MCPBASH_PROJECT_ROOT
EOF
	exit 1
}

mcp_runtime_stage_bootstrap_project() {
	if [ "${MCPBASH_BOOTSTRAP_STAGED}" = "true" ]; then
		return 0
	fi

	local bootstrap_dir="${MCPBASH_HOME}/bootstrap"
	if [ ! -d "${bootstrap_dir}" ]; then
		printf 'mcp-bash: bootstrap project missing at %s\n' "${bootstrap_dir}" >&2
		exit 1
	fi

	local tmp_base tmp_root
	tmp_base="${TMPDIR:-/tmp}"
	tmp_base="${tmp_base%/}"
	tmp_root="$(mktemp -d "${tmp_base}/mcpbash.bootstrap.XXXXXX")"
	if [ -z "${tmp_root}" ] || [ ! -d "${tmp_root}" ]; then
		printf 'mcp-bash: unable to create temporary bootstrap workspace\n' >&2
		exit 1
	fi

	# Copy helper content into a disposable workspace.
	cp -a "${bootstrap_dir}/." "${tmp_root}/" 2>/dev/null || true
	mkdir -p "${tmp_root}/tools" "${tmp_root}/resources" "${tmp_root}/prompts" "${tmp_root}/server.d"

	# Copy VERSION file so smart defaults can detect framework version.
	if [ -f "${MCPBASH_HOME}/VERSION" ]; then
		cp "${MCPBASH_HOME}/VERSION" "${tmp_root}/VERSION" 2>/dev/null || true
	fi

	MCPBASH_PROJECT_ROOT="${tmp_root}"
	export MCPBASH_PROJECT_ROOT

	# Override registry dir to avoid reusing caller-provided caches.
	MCPBASH_REGISTRY_DIR="${tmp_root}/.registry"
	export MCPBASH_REGISTRY_DIR
	mkdir -p "${MCPBASH_REGISTRY_DIR}" >/dev/null 2>&1 || true

	MCPBASH_BOOTSTRAP_TMP_DIR="${tmp_root}"
	MCPBASH_BOOTSTRAP_STAGED="true"

	if mcp_runtime_log_allowed; then
		printf 'mcp-bash: no project configured; starting getting-started helper (temporary workspace %s)\n' "${tmp_root}" >&2
	fi
}

mcp_runtime_init_paths() {
	local mode="${1:-server}"
	local allow_bootstrap="${2:-}"

	if [ -z "${allow_bootstrap}" ]; then
		if [ "${mode}" = "server" ]; then
			allow_bootstrap="true"
		else
			allow_bootstrap="false"
		fi
	fi

	# Resolve project root:
	# 1. Respect MCPBASH_PROJECT_ROOT if set (and ensure it exists)
	# 2. Otherwise, auto-detect from current directory
	# 3. For server mode with bootstrap allowed, stage bootstrap project
	# 4. Otherwise, emit a clear error
	if [ -n "${MCPBASH_PROJECT_ROOT:-}" ]; then
		if [ ! -d "${MCPBASH_PROJECT_ROOT}" ]; then
			printf 'mcp-bash: MCPBASH_PROJECT_ROOT directory does not exist: %s\n' "${MCPBASH_PROJECT_ROOT}" >&2
			printf 'Set MCPBASH_PROJECT_ROOT to an existing project directory or create it first.\n' >&2
			exit 1
		fi
	elif MCPBASH_PROJECT_ROOT="$(mcp_runtime_find_project_root "${PWD}")"; then
		export MCPBASH_PROJECT_ROOT
	elif [ "${allow_bootstrap}" = "true" ] && [ "${mode}" = "server" ]; then
		mcp_runtime_stage_bootstrap_project
	else
		mcp_runtime_project_not_found_error
	fi

	# Normalize PROJECT_ROOT (strip trailing slash for consistent path construction)
	MCPBASH_PROJECT_ROOT="${MCPBASH_PROJECT_ROOT%/}"

	# Temporary/state directories
	if [ -z "${MCPBASH_TMP_ROOT}" ]; then
		local tmp="${TMPDIR:-/tmp}"
		tmp="${tmp%/}"
		MCPBASH_TMP_ROOT="${tmp}"
	fi

	# State/lock paths - mode-dependent
	if [ "${mode}" = "cli" ]; then
		# CLI: simpler paths, shared locks, no cleanup needed
		if [ -z "${MCPBASH_STATE_DIR}" ]; then
			MCPBASH_STATE_DIR="${MCPBASH_TMP_ROOT}/mcpbash.state.$$"
		fi
		if [ -z "${MCPBASH_LOCK_ROOT}" ]; then
			MCPBASH_LOCK_ROOT="${MCPBASH_TMP_ROOT}/mcpbash.locks"
		fi
	else
		# Server: instance-isolated paths with cleanup
		if [ -z "${MCPBASH_STATE_SEED}" ]; then
			MCPBASH_STATE_SEED="${RANDOM}" # STATE_SEED initialized once per boot.
		fi
		if [ -z "${MCPBASH_STATE_DIR}" ]; then
			local pid_component
			if [ -n "${BASHPID-}" ]; then
				pid_component="${BASHPID}"
			else
				pid_component="$$"
			fi
			MCPBASH_STATE_DIR="${MCPBASH_TMP_ROOT}/mcpbash.state.${PPID}.${pid_component}.${MCPBASH_STATE_SEED}"
		fi
		# Default lock root is instance-scoped to avoid cross-process interference (e.g., lingering servers on Windows).
		if [ -z "${MCPBASH_LOCK_ROOT}" ]; then
			MCPBASH_LOCK_ROOT="${MCPBASH_STATE_DIR}/locks"
		fi
	fi

	# Create state directory (needed for fastpath caching in registry refresh)
	(umask 077 && mkdir -p "${MCPBASH_STATE_DIR}") >/dev/null 2>&1 || true
	(umask 077 && mkdir -p "${MCPBASH_LOCK_ROOT}") >/dev/null 2>&1 || true

	# Content directories: explicit override → project default
	# Registry: hidden .registry in project for cache files
	if [ -z "${MCPBASH_REGISTRY_DIR}" ]; then
		MCPBASH_REGISTRY_DIR="${MCPBASH_PROJECT_ROOT}/.registry"
	fi
	(umask 077 && mkdir -p "${MCPBASH_REGISTRY_DIR}") >/dev/null 2>&1 || true

	# Tools directory
	if [ -z "${MCPBASH_TOOLS_DIR}" ]; then
		MCPBASH_TOOLS_DIR="${MCPBASH_PROJECT_ROOT}/tools"
	fi
	mkdir -p "${MCPBASH_TOOLS_DIR}" >/dev/null 2>&1 || true

	# Resources directory
	if [ -z "${MCPBASH_RESOURCES_DIR}" ]; then
		MCPBASH_RESOURCES_DIR="${MCPBASH_PROJECT_ROOT}/resources"
	fi
	mkdir -p "${MCPBASH_RESOURCES_DIR}" >/dev/null 2>&1 || true

	# Prompts directory
	if [ -z "${MCPBASH_PROMPTS_DIR}" ]; then
		MCPBASH_PROMPTS_DIR="${MCPBASH_PROJECT_ROOT}/prompts"
	fi
	mkdir -p "${MCPBASH_PROMPTS_DIR}" >/dev/null 2>&1 || true

	# Server hooks directory
	if [ -z "${MCPBASH_SERVER_DIR}" ]; then
		MCPBASH_SERVER_DIR="${MCPBASH_PROJECT_ROOT}/server.d"
	fi
	mkdir -p "${MCPBASH_SERVER_DIR}" >/dev/null 2>&1 || true

	# Debug: log resolved paths
	mcp_runtime_log_resolved_paths
}

# Log all resolved paths when MCPBASH_LOG_LEVEL=debug
mcp_runtime_log_resolved_paths() {
	if [ "${MCPBASH_LOG_LEVEL:-info}" = "debug" ]; then
		# shellcheck disable=SC2153  # Logging the resolved values intentionally
		cat >&2 <<EOF
mcp-bash: Resolved paths:
  MCPBASH_HOME=${MCPBASH_HOME}
  MCPBASH_PROJECT_ROOT=${MCPBASH_PROJECT_ROOT}
  MCPBASH_TOOLS_DIR=${MCPBASH_TOOLS_DIR}
  MCPBASH_RESOURCES_DIR=${MCPBASH_RESOURCES_DIR}
  MCPBASH_PROMPTS_DIR=${MCPBASH_PROMPTS_DIR}
  MCPBASH_SERVER_DIR=${MCPBASH_SERVER_DIR}
  MCPBASH_REGISTRY_DIR=${MCPBASH_REGISTRY_DIR}
EOF
	fi
}

mcp_runtime_cleanup() {
	if [ "${MCPBASH_CLEANUP_REGISTERED}" = "true" ]; then
		return
	fi
	MCPBASH_CLEANUP_REGISTERED="true"
	if declare -f mcp_core_stop_progress_flusher >/dev/null 2>&1; then
		mcp_core_stop_progress_flusher
	fi
	if declare -f mcp_core_stop_resource_poll >/dev/null 2>&1; then
		mcp_core_stop_resource_poll
	fi

	mcp_io_log_corruption_summary

	# Skip cleanup if MCPBASH_PRESERVE_STATE is set (useful for debugging)
	if [ "${MCPBASH_PRESERVE_STATE:-}" = "true" ]; then
		if [ -n "${MCPBASH_STATE_DIR}" ]; then
			printf 'mcp-bash: state preserved at %s\n' "${MCPBASH_STATE_DIR}" >&2
		fi
		mcp_runtime_cleanup_bootstrap
		return
	fi

	if [ -n "${MCPBASH_STATE_DIR}" ] && [ -d "${MCPBASH_STATE_DIR}" ]; then
		mcp_runtime_safe_rmrf "${MCPBASH_STATE_DIR}"
	fi

	if [ -n "${MCPBASH_LOCK_ROOT}" ] && [ -d "${MCPBASH_LOCK_ROOT}" ]; then
		mcp_runtime_safe_rmrf "${MCPBASH_LOCK_ROOT}"
	fi

	mcp_runtime_cleanup_bootstrap
}

mcp_runtime_safe_rmrf() {
	local target="$1"
	if [ -z "${target}" ] || [ "${target}" = "/" ]; then
		printf '%s\n' "mcp-bash: refusing to remove unsafe path '${target:-/}'" >&2
		return 1
	fi
	case "${target}" in
	"${MCPBASH_TMP_ROOT}"/mcpbash.state.* | "${MCPBASH_TMP_ROOT}"/mcpbash.locks* | "${MCPBASH_TMP_ROOT}"/mcpbash.bootstrap.*)
		rm -rf "${target}"
		;;
	*)
		printf '%s\n' "mcp-bash: refusing to remove '${target}' outside TMP root" >&2
		return 1
		;;
	esac
}

mcp_runtime_cleanup_bootstrap() {
	if [ "${MCPBASH_BOOTSTRAP_STAGED:-false}" != "true" ]; then
		return
	fi
	if [ -z "${MCPBASH_BOOTSTRAP_TMP_DIR:-}" ]; then
		return
	fi
	if [ ! -d "${MCPBASH_BOOTSTRAP_TMP_DIR}" ]; then
		return
	fi
	mcp_runtime_safe_rmrf "${MCPBASH_BOOTSTRAP_TMP_DIR}"
}

mcp_runtime_detect_json_tool() {
	# JSON tool detection: detection order is gojq → jq.
	if mcp_runtime_force_minimal_mode_requested; then
		MCPBASH_MODE="minimal"
		MCPBASH_JSON_TOOL="none"
		MCPBASH_JSON_TOOL_BIN=""
		printf '%s\n' 'Minimal mode forced via MCPBASH_FORCE_MINIMAL=true; JSON tooling disabled.' >&2
		return 0
	fi

	local candidate=""

	candidate="$(command -v gojq 2>/dev/null || true)"
	if [ -n "${candidate}" ]; then
		MCPBASH_JSON_TOOL="gojq"
		MCPBASH_JSON_TOOL_BIN="${candidate}"
		MCPBASH_MODE="full"
		if mcp_runtime_log_allowed && { [ "${MCPBASH_LOG_JSON_TOOL}" = "log" ] || mcp_logging_verbose_enabled; }; then
			if mcp_logging_verbose_enabled; then
				printf '%s\n' "JSON tooling: gojq at ${candidate}; full protocol surface enabled." >&2
			else
				printf '%s\n' "JSON tooling: gojq; full protocol surface enabled." >&2
			fi
		fi
		return 0
	fi

	candidate="$(command -v jq 2>/dev/null || true)"
	if [ -n "${candidate}" ]; then
		MCPBASH_JSON_TOOL="jq"
		MCPBASH_JSON_TOOL_BIN="${candidate}"
		MCPBASH_MODE="full"
		if mcp_runtime_log_allowed && { [ "${MCPBASH_LOG_JSON_TOOL}" = "log" ] || mcp_logging_verbose_enabled; }; then
			if mcp_logging_verbose_enabled; then
				printf '%s\n' "JSON tooling: jq at ${candidate}; full protocol surface enabled." >&2
			else
				printf '%s\n' "JSON tooling: jq; full protocol surface enabled." >&2
			fi
		fi
		return 0
	fi

	# shellcheck disable=SC2034
	MCPBASH_JSON_TOOL="none"
	# shellcheck disable=SC2034
	MCPBASH_JSON_TOOL_BIN=""
	MCPBASH_MODE="minimal"
	if mcp_runtime_log_allowed; then
		printf '%s\n' 'No gojq/jq found; entering minimal mode with reduced capabilities.' >&2
	fi
	return 0
}

mcp_runtime_log_startup_summary() {
	if ! mcp_runtime_is_stdio_transport; then
		return 0
	fi
	if ! mcp_runtime_log_allowed; then
		return 0
	fi

	local command_path cwd project_root json_tool json_tool_detail

	if ! command_path="$(command -v -- "$0" 2>/dev/null || true)"; then
		command_path="$0"
	elif [ -z "${command_path}" ]; then
		command_path="$0"
	fi
	cwd="$(pwd -P 2>/dev/null || pwd)"
	project_root="${MCPBASH_PROJECT_ROOT:-<unset>}"
	json_tool="${MCPBASH_JSON_TOOL:-none}"
	if [ -n "${MCPBASH_JSON_TOOL_BIN:-}" ]; then
		json_tool_detail="${json_tool}:${MCPBASH_JSON_TOOL_BIN}"
	else
		json_tool_detail="${json_tool}"
	fi

	printf 'mcp-bash startup: transport=%s command=%q cwd=%q project_root=%q json_tool=%q\n' \
		"${MCPBASH_TRANSPORT:-stdio}" \
		"${command_path}" \
		"${cwd}" \
		"${project_root}" \
		"${json_tool_detail}" >&2
}

mcp_runtime_force_minimal_mode_requested() {
	[ "${MCPBASH_FORCE_MINIMAL:-false}" = "true" ]
}

mcp_runtime_batches_enabled() {
	# Legacy batch compatibility toggle.
	[ "${MCPBASH_COMPAT_BATCHES:-false}" = "true" ]
}

mcp_runtime_log_batch_mode() {
	if mcp_runtime_batches_enabled; then
		printf '%s\n' 'Legacy batch compatibility enabled (MCPBASH_COMPAT_BATCHES=true); requests framed as arrays will be processed as independent items.' >&2
	fi
}

mcp_runtime_is_minimal_mode() {
	[ "${MCPBASH_MODE}" = "minimal" ]
}

mcp_runtime_enable_job_control() {
	# Enable job-control fallback so background workers receive dedicated process groups.
	if [ "${MCPBASH_JOB_CONTROL_ENABLED}" = "true" ]; then
		return 0
	fi
	if set -m 2>/dev/null; then
		MCPBASH_JOB_CONTROL_ENABLED="true"
	fi
}

mcp_runtime_set_process_group() {
	# Isolate worker processes so cancellation and timeouts can target entire trees.
	# NOTE: This is a no-op legacy function. Process group isolation is now handled
	# by spawning processes with job control enabled (set -m), which automatically
	# places background processes in their own process group.
	local pid="$1"
	[ -n "${pid}" ] || return 1

	# Check if the process is already its own group leader (job control worked)
	local pgid
	pgid="$(ps -o pgid= -p "${pid}" 2>/dev/null | tr -d ' ')"
	if [ -n "${pgid}" ] && [ "${pgid}" = "${pid}" ]; then
		return 0
	fi

	# Process not isolated - this is expected if job control wasn't enabled
	# The caller should handle this gracefully (e.g., only signal specific PIDs)
	return 1
}

mcp_runtime_lookup_pgid() {
	local pid="$1"
	local pgid=""
	[ -n "${pid}" ] || return 1

	# Use ps to look up the process group ID (POSIX-compliant)
	pgid="$(ps -o pgid= -p "${pid}" 2>/dev/null | tr -d ' ')"

	# Fallback to assuming pid == pgid if ps fails
	if [ -z "${pgid}" ]; then
		pgid="${pid}"
	fi

	printf '%s' "${pgid}"
}

mcp_runtime_signal_group() {
	# Send signals to a process group when available.
	local pgid="$1"
	local signal="$2"
	local fallback_pid="$3"
	local main_pgid="$4"

	# Allow opting out of group signaling entirely (e.g., CI without job control).
	if [ "${MCPBASH_SKIP_PROCESS_GROUP_LOOKUP:-0}" = "1" ]; then
		pgid=""
	fi

	# Guard against empty inputs; cancellation/timeout callers are best-effort.
	if [ -z "${signal}" ] || [ -z "${fallback_pid}" ]; then
		return 0
	fi

	# If we have no pgid or it matches the main group, target only the worker pid.
	if [ -z "${pgid}" ] || { [ -n "${main_pgid}" ] && [ "${pgid}" = "${main_pgid}" ]; }; then
		kill -"${signal}" "${fallback_pid}" 2>/dev/null || true
		return 0
	fi

	# Try the process group first; if that fails, target the pid directly.
	if kill -"${signal}" "-${pgid}" 2>/dev/null; then
		return 0
	fi

	kill -"${signal}" "${fallback_pid}" 2>/dev/null || true
	return 0
}

# Server metadata variables (populated by mcp_runtime_load_server_meta)
: "${MCPBASH_SERVER_NAME:=}"
: "${MCPBASH_SERVER_VERSION:=}"
: "${MCPBASH_SERVER_TITLE:=}"
: "${MCPBASH_SERVER_DESCRIPTION:=}"
: "${MCPBASH_SERVER_WEBSITE_URL:=}"
: "${MCPBASH_SERVER_ICONS:=}"

mcp_runtime_load_server_meta() {
	# Load server metadata from server.d/server.meta.json with smart defaults.
	# Called after mcp_runtime_init_paths() to ensure MCPBASH_SERVER_DIR is set.
	local meta_file="${MCPBASH_SERVER_DIR}/server.meta.json"

	# Smart defaults
	local default_name default_title default_version

	# name: basename of project root
	default_name="$(basename "${MCPBASH_PROJECT_ROOT}")"

	# title: titlecase of name (replace hyphens/underscores with spaces, capitalize words)
	default_title="$(mcp_runtime_titlecase "${default_name}")"

	# version: check VERSION file, then package.json, else 0.0.0
	default_version="$(mcp_runtime_detect_version)"

	# Load from server.meta.json if it exists and we have JSON tooling
	if [ -f "${meta_file}" ] && [ "${MCPBASH_JSON_TOOL:-none}" != "none" ]; then
		local json_content
		json_content="$(cat "${meta_file}" 2>/dev/null || true)"

		if [ -n "${json_content}" ]; then
			# Extract each field, falling back to defaults
			MCPBASH_SERVER_NAME="$("${MCPBASH_JSON_TOOL_BIN}" -r '.name // empty' <<<"${json_content}" 2>/dev/null || true)"
			MCPBASH_SERVER_VERSION="$("${MCPBASH_JSON_TOOL_BIN}" -r '.version // empty' <<<"${json_content}" 2>/dev/null || true)"
			MCPBASH_SERVER_TITLE="$("${MCPBASH_JSON_TOOL_BIN}" -r '.title // empty' <<<"${json_content}" 2>/dev/null || true)"
			MCPBASH_SERVER_DESCRIPTION="$("${MCPBASH_JSON_TOOL_BIN}" -r '.description // empty' <<<"${json_content}" 2>/dev/null || true)"
			MCPBASH_SERVER_WEBSITE_URL="$("${MCPBASH_JSON_TOOL_BIN}" -r '.websiteUrl // empty' <<<"${json_content}" 2>/dev/null || true)"
			# icons is an array, keep as JSON
			local icons_json
			icons_json="$("${MCPBASH_JSON_TOOL_BIN}" -c '.icons // empty' <<<"${json_content}" 2>/dev/null || true)"
			if [ -n "${icons_json}" ] && [ "${icons_json}" != "null" ]; then
				MCPBASH_SERVER_ICONS="${icons_json}"
			fi
		fi
	fi

	# Apply defaults for required fields if not set
	[ -z "${MCPBASH_SERVER_NAME}" ] && MCPBASH_SERVER_NAME="${default_name}"
	[ -z "${MCPBASH_SERVER_VERSION}" ] && MCPBASH_SERVER_VERSION="${default_version}"
	[ -z "${MCPBASH_SERVER_TITLE}" ] && MCPBASH_SERVER_TITLE="${default_title}"

	export MCPBASH_SERVER_NAME MCPBASH_SERVER_VERSION MCPBASH_SERVER_TITLE
	export MCPBASH_SERVER_DESCRIPTION MCPBASH_SERVER_WEBSITE_URL MCPBASH_SERVER_ICONS
}

mcp_runtime_titlecase() {
	# Convert "my-cool-server" or "my_cool_server" to "My Cool Server"
	local input="$1"
	local result=""
	local word

	# Replace hyphens and underscores with spaces, then capitalize each word
	input="${input//-/ }"
	input="${input//_/ }"

	for word in ${input}; do
		# Capitalize first letter
		local first="${word:0:1}"
		local rest="${word:1}"
		first="$(printf '%s' "${first}" | tr '[:lower:]' '[:upper:]')"
		result="${result}${result:+ }${first}${rest}"
	done

	printf '%s' "${result}"
}

mcp_runtime_detect_version() {
	# Try to detect version from common sources
	local version=""

	# 1. Check VERSION file in project root
	if [ -f "${MCPBASH_PROJECT_ROOT}/VERSION" ]; then
		version="$(tr -d '[:space:]' <"${MCPBASH_PROJECT_ROOT}/VERSION" 2>/dev/null || true)"
		if [ -n "${version}" ]; then
			printf '%s' "${version}"
			return 0
		fi
	fi

	# 2. Check package.json if we have JSON tooling
	if [ -f "${MCPBASH_PROJECT_ROOT}/package.json" ] && [ "${MCPBASH_JSON_TOOL:-none}" != "none" ]; then
		version="$("${MCPBASH_JSON_TOOL_BIN}" -r '.version // empty' <"${MCPBASH_PROJECT_ROOT}/package.json" 2>/dev/null || true)"
		if [ -n "${version}" ]; then
			printf '%s' "${version}"
			return 0
		fi
	fi

	# 3. Default
	printf '0.0.0'
}
