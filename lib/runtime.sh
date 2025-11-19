#!/usr/bin/env bash
# Target Runtime Environment: JSON tooling detection, minimal-mode controls, and compatibility flags.

# shellcheck disable=SC2034
MCPBASH_JSON_TOOL=""
# shellcheck disable=SC2034
MCPBASH_JSON_TOOL_BIN=""
MCPBASH_MODE=""
MCPBASH_TMP_ROOT=""
MCPBASH_LOCK_ROOT=""
MCPBASH_STATE_DIR=""
MCPBASH_STATE_SEED=""
MCPBASH_CLEANUP_REGISTERED="false"
MCPBASH_JOB_CONTROL_ENABLED="false"
MCPBASH_PROCESS_GROUP_WARNED="false"
MCPBASH_REGISTRY_DIR=""
MCPBASH_TOOLS_DIR=""
MCPBASH_REGISTER_SCRIPT=""

mcp_runtime_init_paths() {
	if [ -z "${MCPBASH_TMP_ROOT}" ]; then
		local tmp="${TMPDIR:-/tmp}"
		tmp="${tmp%/}"
		MCPBASH_TMP_ROOT="${tmp}"
	fi

	if [ -z "${MCPBASH_LOCK_ROOT}" ]; then
		MCPBASH_LOCK_ROOT="${MCPBASH_TMP_ROOT}/mcpbash.locks"
	fi

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

	if [ -z "${MCPBASH_REGISTRY_DIR}" ]; then
		MCPBASH_REGISTRY_DIR="${MCPBASH_ROOT}/registry"
	fi
	mkdir -p "${MCPBASH_REGISTRY_DIR}"

	if [ -z "${MCPBASH_TOOLS_DIR}" ]; then
		MCPBASH_TOOLS_DIR="${MCPBASH_ROOT}/tools"
	fi

	mkdir -p "${MCPBASH_TOOLS_DIR}" >/dev/null 2>&1 || true

	if [ -z "${MCPBASH_REGISTER_SCRIPT}" ]; then
		MCPBASH_REGISTER_SCRIPT="${MCPBASH_ROOT}/server.d/register.sh"
	fi
}

mcp_runtime_cleanup() {
	if [ "${MCPBASH_CLEANUP_REGISTERED}" = "true" ]; then
		return
	fi
	MCPBASH_CLEANUP_REGISTERED="true"

	mcp_io_log_corruption_summary

	if [ -n "${MCPBASH_STATE_DIR}" ] && [ -d "${MCPBASH_STATE_DIR}" ]; then
		mcp_runtime_safe_rmrf "${MCPBASH_STATE_DIR}"
	fi

	if [ -n "${MCPBASH_LOCK_ROOT}" ] && [ -d "${MCPBASH_LOCK_ROOT}" ]; then
		mcp_runtime_safe_rmrf "${MCPBASH_LOCK_ROOT}"
	fi
}

mcp_runtime_safe_rmrf() {
	local target="$1"
	if [ -z "${target}" ] || [ "${target}" = "/" ]; then
		printf '%s\n' "mcp-bash: refusing to remove unsafe path '${target:-/}'" >&2
		return 1
	fi
	case "${target}" in
		"${MCPBASH_TMP_ROOT}"/mcpbash.state.* | "${MCPBASH_TMP_ROOT}"/mcpbash.locks*)
			rm -rf "${target}"
			;;
		*)
			printf '%s\n' "mcp-bash: refusing to remove '${target}' outside TMP root" >&2
			return 1
			;;
	esac
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
		printf '%s\n' "Detected gojq at ${candidate}; full protocol surface enabled." >&2
		return 0
	fi

	candidate="$(command -v jq 2>/dev/null || true)"
	if [ -n "${candidate}" ]; then
		MCPBASH_JSON_TOOL="jq"
		MCPBASH_JSON_TOOL_BIN="${candidate}"
		MCPBASH_MODE="full"
		printf '%s\n' "Detected jq at ${candidate}; full protocol surface enabled." >&2
		return 0
	fi

	# shellcheck disable=SC2034
	MCPBASH_JSON_TOOL="none"
	# shellcheck disable=SC2034
	MCPBASH_JSON_TOOL_BIN=""
	MCPBASH_MODE="minimal"
	printf '%s\n' 'No gojq/jq found; entering minimal mode with reduced capabilities.' >&2
	return 0
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
	local pid="$1"
	[ -n "${pid}" ] || return 1

	if command -v perl >/dev/null 2>&1; then
		perl -MPOSIX -e "POSIX::setpgid($pid,$pid)" >/dev/null 2>&1 && return 0
	fi

	if command -v ruby >/dev/null 2>&1; then
		ruby -e "Process.setpgid(${pid},${pid})" >/dev/null 2>&1 && return 0
	fi

	if [ "${MCPBASH_JOB_CONTROL_ENABLED}" = "true" ]; then
		# Job-control mode already increases the odds workers are isolated; treat as success.
		return 0
	fi

	if [ "${MCPBASH_PROCESS_GROUP_WARNED}" != "true" ]; then
		MCPBASH_PROCESS_GROUP_WARNED="true"
		printf '%s\n' 'mcp-bash: unable to assign dedicated process groups; cancellation may be less effective.' >&2
	fi
	return 1
}

mcp_runtime_lookup_pgid() {
	local pid="$1"
	local pgid=""
	[ -n "${pid}" ] || return 1

	if [ -z "${pgid}" ] && command -v perl >/dev/null 2>&1; then
		pgid="$(perl -MPOSIX -e "print POSIX::getpgid($pid)" 2>/dev/null)"
	fi

	if [ -z "${pgid}" ] && command -v ruby >/dev/null 2>&1; then
		pgid="$(ruby -e "begin; puts Process.getpgid(${pid}); rescue; end" 2>/dev/null)"
	fi

	if [ -z "${pgid}" ]; then
		pgid="$(ps -o pgid= -p "${pid}" 2>/dev/null | tr -d ' ')"
	fi

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

	if [ -n "${pgid}" ] && [ -n "${signal}" ] && [ -n "${fallback_pid}" ]; then
		if [ -n "${main_pgid}" ] && [ "${pgid}" = "${main_pgid}" ]; then
			kill -"${signal}" "${fallback_pid}" 2>/dev/null
			return 0
		fi
		if kill -"${signal}" "-${pgid}" 2>/dev/null; then
			return 0
		fi
		kill -"${signal}" "${fallback_pid}" 2>/dev/null
	fi
}
