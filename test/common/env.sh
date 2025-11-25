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

# Prefer gojq for cross-platform determinism, falling back to jq. Use type -P
# to ignore any shell functions so sourcing this file multiple times stays safe.
TEST_JSON_TOOL_BIN=""
if TEST_JSON_TOOL_BIN="$(type -P gojq 2>/dev/null)" && [ -n "${TEST_JSON_TOOL_BIN}" ]; then
	:
elif TEST_JSON_TOOL_BIN="$(type -P jq 2>/dev/null)" && [ -n "${TEST_JSON_TOOL_BIN}" ]; then
	:
else
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

# Stage a throw-away workspace mirroring the project layout so tests never
# mutate the developer's tree. Fixtures are required to operate in
# isolated directories.
# Creates both framework files and a project directory structure.
test_stage_workspace() {
	local dest="$1"
	mkdir -p "${dest}"
	# Copy framework files
	cp -a "${MCPBASH_HOME}/bin" "${dest}/"
	cp -a "${MCPBASH_HOME}/lib" "${dest}/"
	cp -a "${MCPBASH_HOME}/handlers" "${dest}/"
	cp -a "${MCPBASH_HOME}/providers" "${dest}/"
	cp -a "${MCPBASH_HOME}/sdk" "${dest}/"
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
