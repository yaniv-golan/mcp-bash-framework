#!/usr/bin/env bash
# Shared test environment helpers.

set -euo pipefail

# Root of the repository. Every test relies on this to locate fixtures.
MCPBASH_TEST_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

# Export canonical environment variables consumed by the server and helpers.
# MCPBASH_HOME is the framework location (read-only).
# MCPBASH_PROJECT_ROOT is the project location (writable, where tools/prompts/resources live).
export MCPBASH_HOME="${MCPBASH_TEST_ROOT}"
export PATH="${MCPBASH_HOME}/bin:${PATH}"

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

# Tar staging is enabled by default; set MCPBASH_STAGING_TAR=0 to opt out.
MCPBASH_STAGING_TAR="${MCPBASH_STAGING_TAR:-1}"
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
	if [ -n "${TEST_TMPDIR:-}" ] && [ -d "${TEST_TMPDIR}" ]; then
		rm -rf "${TEST_TMPDIR}" 2>/dev/null || true
	fi
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

	if [ -z "${digests}" ]; then
		printf '' | "${TEST_SHA256_CMD[@]}" | awk '{print $1}'
	else
		printf '%s\n' "${digests}" | "${TEST_SHA256_CMD[@]}" | awk '{print $1}'
	fi
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
		tar_args=("${TEST_TAR_BIN}" "${tar_flags[@]}" -cf "${tmp_tar}" -C "${MCPBASH_HOME}")
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
	if "${TEST_TAR_BIN}" "${tar_flags[@]}" -xf "${MCPBASH_BASE_TAR}" -C "${dest}"; then
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

# Run mcp-bash with newline-delimited JSON requests and capture the raw output.
# Tests should call assert helpers afterwards to validate responses.
# The workspace serves as both MCPBASH_HOME (framework) and MCPBASH_PROJECT_ROOT (project).
test_run_mcp() {
	local workspace="$1"
	local requests_file="$2"
	local responses_file="$3"

	if [ ! -f "${workspace}/bin/mcp-bash" ]; then
		printf 'Workspace %s missing bin/mcp-bash\n' "${workspace}" >&2
		return 1
	fi

	(
		cd "${workspace}" || exit 1
		MCPBASH_PROJECT_ROOT="${workspace}" \
			MCPBASH_LOG_LEVEL="${MCPBASH_LOG_LEVEL:-info}" \
			MCPBASH_DEBUG_PAYLOADS="${MCPBASH_DEBUG_PAYLOADS:-}" \
			./bin/mcp-bash <"${requests_file}" >"${responses_file}"
	)
}
