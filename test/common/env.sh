#!/usr/bin/env bash
# Shared test environment helpers.

set -euo pipefail

# Root of the repository. Every test relies on this to locate fixtures.
# Use ${BASH_SOURCE[0]:-$0} to tolerate shells/contexts where BASH_SOURCE is unset under set -u.
MCPBASH_TEST_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/../.." && pwd)"

# Export canonical environment variables consumed by the server and helpers.
# MCPBASH_HOME is the framework location (read-only).
# MCPBASH_PROJECT_ROOT is the project location (writable, where tools/prompts/resources live).
export MCPBASH_HOME="${MCPBASH_TEST_ROOT}"
export PATH="${MCPBASH_HOME}/bin:${PATH}"

if [ -z "${MCPBASH_TOOL_ALLOWLIST:-}" ]; then
	export MCPBASH_TOOL_ALLOWLIST="*"
fi

if [ -z "${MCPBASH_ALLOW_PROJECT_HOOKS:-}" ]; then
	export MCPBASH_ALLOW_PROJECT_HOOKS="true"
fi

# Silence JSON tooling detection logs in tests unless explicitly opted in.
if [ -z "${MCPBASH_LOG_JSON_TOOL:-}" ] && [ "${VERBOSE:-0}" != "1" ]; then
	MCPBASH_LOG_JSON_TOOL="quiet"
	export MCPBASH_LOG_JSON_TOOL
fi

# Prefer gojq for cross-platform determinism, falling back to jq. Use type -P
# to ignore any shell functions so sourcing this file multiple times stays safe.
TEST_JSON_TOOL_BIN=""
# gojq has shown memory spikes on Windows runners; prefer jq there if available.
case "$(uname -s 2>/dev/null)" in
MINGW* | MSYS*)
	if TEST_JSON_TOOL_BIN="$(type -P jq 2>/dev/null)" && [ -n "${TEST_JSON_TOOL_BIN}" ]; then
		:
	elif TEST_JSON_TOOL_BIN="$(type -P gojq 2>/dev/null)" && [ -n "${TEST_JSON_TOOL_BIN}" ]; then
		:
	fi
	;;
*)
	if TEST_JSON_TOOL_BIN="$(type -P gojq 2>/dev/null)" && [ -n "${TEST_JSON_TOOL_BIN}" ]; then
		:
	elif TEST_JSON_TOOL_BIN="$(type -P jq 2>/dev/null)" && [ -n "${TEST_JSON_TOOL_BIN}" ]; then
		:
	fi
	;;
esac
if [ -z "${TEST_JSON_TOOL_BIN}" ]; then
	printf 'Required command "jq" (or gojq) not found in PATH\n' >&2
	exit 1
fi

# Shell function shim so every test invocation of jq uses the preferred binary.
jq() {
	command "${TEST_JSON_TOOL_BIN}" "$@"
}

# Ensure TMPDIR exists (macOS sets it, but GitHub runners may not).
if [ -z "${TMPDIR:-}" ] || [ ! -d "${TMPDIR}" ]; then
	TMPDIR="/tmp"
	export TMPDIR
fi

# Tar staging: on in CI (MCPBASH_CI_MODE=1), off by default locally. Override with MCPBASH_STAGING_TAR=1/0.
if [ -z "${MCPBASH_STAGING_TAR:-}" ]; then
	if [[ "${MCPBASH_CI_MODE:-0}" =~ ^(1|true|yes)$ ]]; then
		MCPBASH_STAGING_TAR=1
	else
		MCPBASH_STAGING_TAR=0
	fi
fi
# Shared cache location for the base tarball; reused across test scripts in a run.
MCPBASH_TAR_DIR="${MCPBASH_TAR_DIR:-${TMPDIR%/}/mcpbash.staging}"
MCPBASH_BASE_TAR="${MCPBASH_BASE_TAR:-${MCPBASH_TAR_DIR}/base.tar}"
MCPBASH_BASE_TAR_META="${MCPBASH_BASE_TAR_META:-${MCPBASH_TAR_DIR}/base.tar.sha256}"

TEST_SHA256_CMD=()
TEST_TAR_BIN=""

test_create_tmpdir() {
	local dir
	dir="$(mktemp -d "${TMPDIR%/}/mcpbash.test.XXXXXX")"
	TEST_TMPDIR="${dir}"
	trap 'test_cleanup_tmpdir' EXIT INT TERM
}

test_cleanup_tmpdir() {
	if [ "${MCPBASH_KEEP_LOGS:-false}" = "true" ]; then
		return 0
	fi
	if [ -n "${TEST_TMPDIR:-}" ] && [ -d "${TEST_TMPDIR}" ]; then
		rm -rf "${TEST_TMPDIR}" 2>/dev/null || true
	fi
}

# Capture a minimal, high-signal failure bundle into MCPBASH_LOG_DIR (CI uploads it).
# Intended for integration/conformance tests where preserved state/log dirs may not
# be uploaded reliably on Windows runners.
#
# Args:
# - $1: label (string; e.g. test script name)
# - $2: workspace dir (optional; copy requests/responses from here)
# - $3: state dir (optional; copy progress/log streams from here)
# - $@: extra files to copy verbatim (optional)
test_capture_failure_bundle() {
	local label="${1:-test}"
	local workspace="${2:-}"
	local state_dir="${3:-}"
	shift 3 || true

	local log_root="${MCPBASH_LOG_DIR:-}"
	if [ -z "${log_root}" ]; then
		return 0
	fi
	# On Windows runners, MCPBASH_LOG_DIR may be a native path (e.g. D:\a\_temp\...).
	# Normalize to a MSYS path so mkdir/cp work reliably.
	if command -v cygpath >/dev/null 2>&1; then
		log_root="$(cygpath -u "${log_root}" 2>/dev/null || printf '%s' "${log_root}")"
	fi
	log_root="${log_root//\\//}"

	local ts
	ts="$(date +%Y%m%d-%H%M%S 2>/dev/null || date +%s)"
	local dest="${log_root%/}/failure-bundles/${label}.${ts}.$$"
	mkdir -p "${dest}" 2>/dev/null || return 0

	# Copy explicitly provided files first.
	local f
	for f in "$@"; do
		[ -n "${f}" ] || continue
		if [ -f "${f}" ]; then
			cp -f "${f}" "${dest}/" 2>/dev/null || true
		fi
	done

	# Copy common request/response artifacts from the workspace.
	if [ -n "${workspace}" ] && [ -d "${workspace}" ]; then
		if command -v cygpath >/dev/null 2>&1; then
			workspace="$(cygpath -u "${workspace}" 2>/dev/null || printf '%s' "${workspace}")"
		fi
		workspace="${workspace//\\//}"
		for f in \
			"${workspace}"/requests*.ndjson \
			"${workspace}"/responses*.ndjson \
			"${workspace}"/responses*.ndjson.stderr \
			"${workspace}"/requests*.ndjson.stderr; do
			[ -f "${f}" ] || continue
			cp -f "${f}" "${dest}/" 2>/dev/null || true
		done
	fi

	# Copy high-signal state/stream artifacts from the server state dir.
	if [ -n "${state_dir}" ] && [ -d "${state_dir}" ]; then
		if command -v cygpath >/dev/null 2>&1; then
			state_dir="$(cygpath -u "${state_dir}" 2>/dev/null || printf '%s' "${state_dir}")"
		fi
		state_dir="${state_dir//\\//}"
		for f in \
			"${state_dir}"/progress.*.ndjson \
			"${state_dir}"/logs.*.ndjson \
			"${state_dir}"/progress.ndjson \
			"${state_dir}"/logs.ndjson \
			"${state_dir}"/payload.debug.log \
			"${state_dir}"/stdout_corruption.log \
			"${state_dir}"/watchdog.*.log \
			"${state_dir}"/stderr.*.log \
			"${state_dir}"/pid.* \
			"${state_dir}"/cancelled.*; do
			[ -f "${f}" ] || continue
			cp -f "${f}" "${dest}/" 2>/dev/null || true
		done
	fi

	# Record bundle provenance for quick inspection.
	{
		printf 'label=%s\n' "${label}"
		printf 'workspace=%s\n' "${workspace}"
		printf 'state_dir=%s\n' "${state_dir}"
		printf 'cwd=%s\n' "$(pwd 2>/dev/null || printf '%s' "${PWD}")"
	} >"${dest}/bundle.meta" 2>/dev/null || true
}

test_extract_state_dir_from_stderr() {
	local stderr_file="$1"
	[ -n "${stderr_file}" ] || return 1
	[ -f "${stderr_file}" ] || return 1
	local line=""
	line="$(grep -m1 -- 'mcp-bash: state preserved at ' "${stderr_file}" 2>/dev/null || true)"
	[ -n "${line}" ] || return 1
	line="${line#*mcp-bash: state preserved at }"
	line="${line%$'\r'}"
	[ -n "${line}" ] || return 1
	printf '%s' "${line}"
	return 0
}

test_require_command() {
	local cmd="$1"
	if ! command -v "${cmd}" >/dev/null 2>&1; then
		printf 'Required command "%s" not found in PATH\n' "${cmd}" >&2
		return 1
	fi
}

test_init_sha256_cmd() {
	if [ "${#TEST_SHA256_CMD[@]}" -gt 0 ]; then
		return 0
	fi
	if command -v sha256sum >/dev/null 2>&1; then
		TEST_SHA256_CMD=(sha256sum)
	elif command -v shasum >/dev/null 2>&1; then
		TEST_SHA256_CMD=(shasum -a 256)
	else
		printf 'Checksum command (sha256sum or shasum) not found in PATH\n' >&2
		return 1
	fi
}

test_pick_tar_bin() {
	if [ -n "${TEST_TAR_BIN}" ]; then
		return 0
	fi
	if command -v bsdtar >/dev/null 2>&1; then
		TEST_TAR_BIN="bsdtar"
	elif command -v tar >/dev/null 2>&1; then
		TEST_TAR_BIN="tar"
	else
		printf 'Required command "tar" (or bsdtar) not found in PATH\n' >&2
		return 1
	fi
}

test_tar_supports_flag() {
	local flag="$1"
	if [ -z "${TEST_TAR_BIN}" ]; then
		return 1
	fi
	if "${TEST_TAR_BIN}" --help 2>/dev/null | grep -q -- "${flag}"; then
		return 0
	fi
	return 1
}

test_compute_base_tar_key() {
	if [ -n "${MCPBASH_BASE_TAR_KEY:-}" ] && [ -f "${MCPBASH_BASE_TAR:-}" ] && [ -f "${MCPBASH_BASE_TAR_META:-}" ]; then
		printf '%s' "${MCPBASH_BASE_TAR_KEY}"
		return 0
	fi
	if [ -z "${MCPBASH_BASE_TAR_KEY:-}" ] && [ -f "${MCPBASH_BASE_TAR_META:-}" ] && [ -f "${MCPBASH_BASE_TAR:-}" ]; then
		MCPBASH_BASE_TAR_KEY="$(cat "${MCPBASH_BASE_TAR_META}")"
		export MCPBASH_BASE_TAR_KEY
		printf '%s' "${MCPBASH_BASE_TAR_KEY}"
		return 0
	fi
	test_init_sha256_cmd || return 1

	local -a include_dirs
	include_dirs=(bin lib handlers providers sdk bootstrap scaffold)

	local -a find_paths=()
	local dir
	for dir in "${include_dirs[@]}"; do
		if [ -d "${MCPBASH_HOME}/${dir}" ]; then
			find_paths+=("${MCPBASH_HOME}/${dir}")
		fi
	done

	if [ "${#find_paths[@]}" -eq 0 ]; then
		# Empty tree; hash empty string for determinism.
		printf '' | "${TEST_SHA256_CMD[@]}" | awk '{print $1}'
		return 0
	fi

	local digests
	digests="$(
		find "${find_paths[@]}" -type f -print 2>/dev/null \
			| LC_ALL=C sort \
			| while IFS= read -r file; do
				[ -n "${file}" ] || continue
				"${TEST_SHA256_CMD[@]}" "${file}"
			done
	)" || return 1

	local computed_key
	if [ -z "${digests}" ]; then
		computed_key="$(printf '' | "${TEST_SHA256_CMD[@]}" | awk '{print $1}')"
	else
		computed_key="$(printf '%s\n' "${digests}" | "${TEST_SHA256_CMD[@]}" | awk '{print $1}')"
	fi
	MCPBASH_BASE_TAR_KEY="${computed_key}"
	export MCPBASH_BASE_TAR_KEY
	printf '%s' "${computed_key}"
}

test_prepare_base_tar() {
	if [ "${MCPBASH_STAGING_TAR}" = "0" ]; then
		return 1
	fi
	test_pick_tar_bin || return 1
	test_init_sha256_cmd || return 1

	mkdir -p "${MCPBASH_TAR_DIR}"
	local desired_key current_key
	if [ -n "${MCPBASH_BASE_TAR_KEY:-}" ] && [ -f "${MCPBASH_BASE_TAR}" ] && [ -f "${MCPBASH_BASE_TAR_META}" ]; then
		desired_key="${MCPBASH_BASE_TAR_KEY}"
	else
		desired_key="$(test_compute_base_tar_key)" || return 1
	fi
	if [ -f "${MCPBASH_BASE_TAR_META}" ]; then
		current_key="$(cat "${MCPBASH_BASE_TAR_META}")"
	else
		current_key=""
	fi

	if [ ! -f "${MCPBASH_BASE_TAR}" ] || [ "${desired_key}" != "${current_key}" ]; then
		local tmp_tar empty_root
		tmp_tar="$(mktemp "${MCPBASH_TAR_DIR}/base.tar.XXXXXX")"
		empty_root="$(mktemp -d "${MCPBASH_TAR_DIR}/empty.XXXXXX")"
		mkdir -p "${empty_root}/tools" "${empty_root}/resources" "${empty_root}/prompts" "${empty_root}/server.d"

		local -a tar_flags
		tar_flags=()
		if test_tar_supports_flag '--no-same-owner'; then
			tar_flags+=('--no-same-owner')
		fi
		if test_tar_supports_flag '--no-acls'; then
			tar_flags+=('--no-acls')
		fi
		if test_tar_supports_flag '--no-xattrs'; then
			tar_flags+=('--no-xattrs')
		fi

		local -a tar_args
		tar_args=("${TEST_TAR_BIN}" "${tar_flags[@]:-}" -cf "${tmp_tar}" -C "${MCPBASH_HOME}")
		local dir
		for dir in bin lib handlers providers sdk bootstrap scaffold; do
			if [ -e "${MCPBASH_HOME}/${dir}" ]; then
				tar_args+=("${dir}")
			fi
		done
		tar_args+=(-C "${empty_root}" tools resources prompts server.d)

		if "${tar_args[@]}"; then
			mv "${tmp_tar}" "${MCPBASH_BASE_TAR}"
			printf '%s' "${desired_key}" >"${MCPBASH_BASE_TAR_META}"
		else
			rm -f "${tmp_tar}" >/dev/null 2>&1 || true
			rm -rf "${empty_root}" >/dev/null 2>&1 || true
			return 1
		fi
		rm -rf "${empty_root}" >/dev/null 2>&1 || true
	fi

	MCPBASH_BASE_TAR_KEY="${desired_key}"
	export MCPBASH_BASE_TAR
	export MCPBASH_BASE_TAR_KEY
	return 0
}

test_extract_base_tar() {
	local dest="$1"
	if [ -z "${MCPBASH_BASE_TAR:-}" ] || [ ! -f "${MCPBASH_BASE_TAR}" ]; then
		return 1
	fi
	test_pick_tar_bin || return 1

	local -a tar_flags
	tar_flags=()
	if test_tar_supports_flag '--no-same-owner'; then
		tar_flags+=('--no-same-owner')
	fi
	if test_tar_supports_flag '--no-acls'; then
		tar_flags+=('--no-acls')
	fi
	if test_tar_supports_flag '--no-xattrs'; then
		tar_flags+=('--no-xattrs')
	fi

	mkdir -p "${dest}"
	if "${TEST_TAR_BIN}" "${tar_flags[@]:-}" -xf "${MCPBASH_BASE_TAR}" -C "${dest}"; then
		return 0
	fi
	return 1
}

# Stage a throw-away workspace mirroring the project layout so tests never
# mutate the developer's tree. Fixtures are required to operate in
# isolated directories.
# Creates both framework files and a project directory structure.
test_stage_workspace() {
	local dest="$1"
	mkdir -p "${dest}"
	if test_prepare_base_tar && test_extract_base_tar "${dest}"; then
		return 0
	fi
	if [ "${VERBOSE:-0}" = "1" ]; then
		printf ' -> base tar unavailable; falling back to copy\n' >&2
	fi
	# Copy framework files
	cp -a "${MCPBASH_HOME}/bin" "${dest}/"
	cp -a "${MCPBASH_HOME}/lib" "${dest}/"
	cp -a "${MCPBASH_HOME}/handlers" "${dest}/"
	cp -a "${MCPBASH_HOME}/providers" "${dest}/"
	cp -a "${MCPBASH_HOME}/sdk" "${dest}/"
	cp -a "${MCPBASH_HOME}/bootstrap" "${dest}/" 2>/dev/null || true
	cp -a "${MCPBASH_HOME}/scaffold" "${dest}/" 2>/dev/null || true
	# Create project directories (may be populated by tests)
	mkdir -p "${dest}/tools"
	mkdir -p "${dest}/resources"
	mkdir -p "${dest}/prompts"
	mkdir -p "${dest}/server.d"
}

# Clear all registry caches in a workspace to force re-discovery.
# Use this when tests add tools/resources/prompts mid-run, since the server caches
# discovered components for TTL seconds (default 5s). Without invalidation,
# subsequent test_run_mcp calls may not see newly created components.
#
# Example:
#   # Create tool after initial test
#   mkdir -p "${WORKSPACE}/tools/new-tool"
#   # ... create files ...
#   test_invalidate_registry_cache "${WORKSPACE}"
#   # Now test_run_mcp will discover new-tool
#   test_run_mcp "${WORKSPACE}" ...
#
# Symptoms of cache staleness:
# - -32603 "Tool execution failed" when expecting a policy/validation error
# - tools/list returns fewer tools than expected
# - Tool exists on disk but calls fail with "not found"
test_invalidate_registry_cache() {
	local workspace="${1:-${TEST_TMPDIR:-}}"
	if [ -z "${workspace}" ]; then
		printf 'test_invalidate_registry_cache: no workspace specified\n' >&2
		return 1
	fi
	rm -f "${workspace}/.registry/tools.json"
	rm -f "${workspace}/.registry/resources.json"
	rm -f "${workspace}/.registry/prompts.json"
	rm -f "${workspace}/.registry/resource-templates.json"
}

# Run mcp-bash with newline-delimited JSON requests and capture the raw output.
# Tests should call assert helpers afterwards to validate responses.
# The workspace serves as both MCPBASH_HOME (framework) and MCPBASH_PROJECT_ROOT (project).
# Note: All environment variables from the calling context are inherited (e.g., POLICY_*).
#
# IMPORTANT: Registry cache behavior
# The server caches discovered tools/resources/prompts for TTL seconds (default 5s).
# If your test creates components AFTER an earlier test_run_mcp call, you must call
# test_invalidate_registry_cache before the next test_run_mcp to see the new components.
test_run_mcp() {
	local workspace="$1"
	local requests_file="$2"
	local responses_file="$3"
	local stderr_file="${responses_file}.stderr"

	if [ ! -f "${workspace}/bin/mcp-bash" ]; then
		printf 'Workspace %s missing bin/mcp-bash\n' "${workspace}" >&2
		return 1
	fi

	(
		cd "${workspace}" || exit 1
		# Export any POLICY_* vars inherited from calling context (shell vars aren't
		# automatically exported to external commands like mcp-bash).
		# Use indirect expansion ${!_var} to get the value of the variable named in _var.
		for _var in "${!POLICY_@}"; do
			export "${_var}=${!_var}"
		done
		unset _var
		# Use export to ensure vars are available to mcp-bash while preserving inherited env
		export MCPBASH_PROJECT_ROOT="${workspace}"
		export MCPBASH_ALLOW_PROJECT_HOOKS="${MCPBASH_ALLOW_PROJECT_HOOKS:-}"
		export MCPBASH_LOG_LEVEL="${MCPBASH_LOG_LEVEL:-info}"
		export MCPBASH_DEBUG_PAYLOADS="${MCPBASH_DEBUG_PAYLOADS:-}"
		export MCPBASH_REMOTE_TOKEN="${MCPBASH_REMOTE_TOKEN:-}"
		export MCPBASH_REMOTE_TOKEN_KEY="${MCPBASH_REMOTE_TOKEN_KEY:-}"
		export MCPBASH_REMOTE_TOKEN_FALLBACK_KEY="${MCPBASH_REMOTE_TOKEN_FALLBACK_KEY:-}"
		./bin/mcp-bash <"${requests_file}" >"${responses_file}" 2>"${stderr_file}"
	)
}
