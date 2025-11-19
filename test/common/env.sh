#!/usr/bin/env bash
# Shared test environment helpers.

set -euo pipefail

# Root of the repository. Every test relies on this to locate fixtures.
MCPBASH_TEST_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

# Export canonical environment variables consumed by the server and helpers.
export MCPBASH_ROOT="${MCPBASH_TEST_ROOT}"
export PATH="${MCPBASH_ROOT}/bin:${PATH}"

# Ensure TMPDIR exists (macOS sets it, but GitHub runners may not).
if [ -z "${TMPDIR:-}" ] || [ ! -d "${TMPDIR}" ]; then
	TMPDIR="/tmp"
	export TMPDIR
fi

test_create_tmpdir() {
	local dir
	dir="$(mktemp -d "${TMPDIR%/}/mcpbash.test.XXXXXX")"
	TEST_TMPDIR="${dir}"
	trap 'rm -rf "${TEST_TMPDIR:-}"' EXIT INT TERM
}

test_cleanup_tmpdir() {
	if [ -n "${TEST_TMPDIR:-}" ] && [ -d "${TEST_TMPDIR}" ]; then
		rm -rf "${TEST_TMPDIR}"
	fi
}

test_require_command() {
	local cmd="$1"
	if ! command -v "${cmd}" >/dev/null 2>&1; then
		printf 'Required command "%s" not found in PATH\n' "${cmd}" >&2
		return 1
	fi
}

# Stage a throw-away workspace mirroring the project layout so tests never
# mutate the developer's tree. Fixtures are required to operate in
# isolated directories.
test_stage_workspace() {
	local dest="$1"
	mkdir -p "${dest}"
	cp -a "${MCPBASH_ROOT}/bin" "${dest}/"
	cp -a "${MCPBASH_ROOT}/lib" "${dest}/"
	cp -a "${MCPBASH_ROOT}/handlers" "${dest}/"
	cp -a "${MCPBASH_ROOT}/providers" "${dest}/"
	cp -a "${MCPBASH_ROOT}/sdk" "${dest}/"
	cp -a "${MCPBASH_ROOT}/resources" "${dest}/" 2>/dev/null || true
	cp -a "${MCPBASH_ROOT}/tools" "${dest}/" 2>/dev/null || true
	cp -a "${MCPBASH_ROOT}/prompts" "${dest}/" 2>/dev/null || true
	cp -a "${MCPBASH_ROOT}/server.d" "${dest}/" 2>/dev/null || true
}

# Run mcp-bash with newline-delimited JSON requests and capture the raw output.
# Tests should call assert helpers afterwards to validate responses.
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
		MCPBASH_LOG_LEVEL="${MCPBASH_LOG_LEVEL:-info}" \
			MCPBASH_DEBUG_PAYLOADS="${MCPBASH_DEBUG_PAYLOADS:-}" \
			./bin/mcp-bash <"${requests_file}" >"${responses_file}"
	)
}
