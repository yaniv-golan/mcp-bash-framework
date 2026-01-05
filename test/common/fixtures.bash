#!/usr/bin/env bash
# Bats-compatible test fixtures and helpers.
# Load this file in bats tests via: load '../common/fixtures'

# Root of the repository
MCPBASH_TEST_ROOT="${MCPBASH_TEST_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"

# Export canonical environment variables consumed by the server and helpers.
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

# Prefer gojq for cross-platform determinism, falling back to jq.
TEST_JSON_TOOL_BIN=""
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

# Ensure TMPDIR exists
if [ -z "${TMPDIR:-}" ] || [ ! -d "${TMPDIR}" ]; then
	TMPDIR="/tmp"
	export TMPDIR
fi

# Tar staging configuration
if [ -z "${MCPBASH_STAGING_TAR:-}" ]; then
	if [[ "${MCPBASH_CI_MODE:-0}" =~ ^(1|true|yes)$ ]]; then
		MCPBASH_STAGING_TAR=1
	else
		MCPBASH_STAGING_TAR=0
	fi
fi
MCPBASH_TAR_DIR="${MCPBASH_TAR_DIR:-${TMPDIR%/}/mcpbash.staging}"
MCPBASH_BASE_TAR="${MCPBASH_BASE_TAR:-${MCPBASH_TAR_DIR}/base.tar}"
MCPBASH_BASE_TAR_META="${MCPBASH_BASE_TAR_META:-${MCPBASH_TAR_DIR}/base.tar.sha256}"

TEST_SHA256_CMD=()
TEST_TAR_BIN=""

# Capture a minimal, high-signal failure bundle into MCPBASH_LOG_DIR (CI uploads it).
test_capture_failure_bundle() {
	local label="${1:-test}"
	local workspace="${2:-}"
	local state_dir="${3:-}"
	shift 3 || true

	local log_root="${MCPBASH_LOG_DIR:-}"
	if [ -z "${log_root}" ]; then
		return 0
	fi
	if command -v cygpath >/dev/null 2>&1; then
		log_root="$(cygpath -u "${log_root}" 2>/dev/null || printf '%s' "${log_root}")"
	fi
	log_root="${log_root//\\//}"

	local ts
	ts="$(date +%Y%m%d-%H%M%S 2>/dev/null || date +%s)"
	local dest="${log_root%/}/failure-bundles/${label}.${ts}.$$"
	mkdir -p "${dest}" 2>/dev/null || return 0

	local f
	for f in "$@"; do
		[ -n "${f}" ] || continue
		if [ -f "${f}" ]; then
			cp -f "${f}" "${dest}/" 2>/dev/null || true
		fi
	done

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

# Stage a throw-away workspace mirroring the project layout.
test_stage_workspace() {
	local dest="$1"
	mkdir -p "${dest}"
	if test_prepare_base_tar && test_extract_base_tar "${dest}"; then
		return 0
	fi
	if [ "${VERBOSE:-0}" = "1" ]; then
		printf ' -> base tar unavailable; falling back to copy\n' >&2
	fi
	cp -a "${MCPBASH_HOME}/bin" "${dest}/"
	cp -a "${MCPBASH_HOME}/lib" "${dest}/"
	cp -a "${MCPBASH_HOME}/handlers" "${dest}/"
	cp -a "${MCPBASH_HOME}/providers" "${dest}/"
	cp -a "${MCPBASH_HOME}/sdk" "${dest}/"
	cp -a "${MCPBASH_HOME}/bootstrap" "${dest}/" 2>/dev/null || true
	cp -a "${MCPBASH_HOME}/scaffold" "${dest}/" 2>/dev/null || true
	mkdir -p "${dest}/tools"
	mkdir -p "${dest}/resources"
	mkdir -p "${dest}/prompts"
	mkdir -p "${dest}/server.d"
}

# Run mcp-bash with newline-delimited JSON requests and capture the raw output.
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
		MCPBASH_PROJECT_ROOT="${workspace}" \
			MCPBASH_ALLOW_PROJECT_HOOKS="${MCPBASH_ALLOW_PROJECT_HOOKS:-}" \
			MCPBASH_LOG_LEVEL="${MCPBASH_LOG_LEVEL:-info}" \
			MCPBASH_DEBUG_PAYLOADS="${MCPBASH_DEBUG_PAYLOADS:-}" \
			MCPBASH_REMOTE_TOKEN="${MCPBASH_REMOTE_TOKEN:-}" \
			MCPBASH_REMOTE_TOKEN_KEY="${MCPBASH_REMOTE_TOKEN_KEY:-}" \
			MCPBASH_REMOTE_TOKEN_FALLBACK_KEY="${MCPBASH_REMOTE_TOKEN_FALLBACK_KEY:-}" \
			./bin/mcp-bash <"${requests_file}" >"${responses_file}" 2>"${stderr_file}"
	)
}

# Stage an example project for testing.
test_stage_example() {
	local example_id="$1"
	if [ -z "${example_id}" ]; then
		fail "example id required"
	fi
	EXAMPLE_DIR="${MCPBASH_HOME}/examples/${example_id}"
	if [ ! -d "${EXAMPLE_DIR}" ]; then
		fail "example ${example_id} not found"
	fi
	TMP_WORKDIR="$(mktemp -d "${BATS_TEST_TMPDIR}/example.XXXXXX")"
	test_stage_workspace "${TMP_WORKDIR}"
	cp -a "${EXAMPLE_DIR}/"* "${TMP_WORKDIR}/" 2>/dev/null || true
	MCP_TEST_WORKDIR="${TMP_WORKDIR}"
	export MCPBASH_PROJECT_ROOT="${TMP_WORKDIR}"
}
