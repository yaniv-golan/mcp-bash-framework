#!/usr/bin/env bash
set -euo pipefail

# Skip MSYS path mangling for Windows shells.
export MSYS2_ARG_CONV_EXCL="*"

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
project_root="$(cd "${script_dir}/../.." && pwd)"
export MCPBASH_PROJECT_ROOT="${MCPBASH_PROJECT_ROOT:-${project_root}}"

# Locate mcp-bash (prefer local project/bin, then PATH, then MCPBASH_HOME).
MCPBASH_BIN="${MCPBASH_BIN:-}"
if [[ -z "${MCPBASH_BIN}" ]] && [[ -x "${project_root}/bin/mcp-bash" ]]; then
	MCPBASH_BIN="${project_root}/bin/mcp-bash"
fi
if [[ -z "${MCPBASH_BIN}" ]] && command -v mcp-bash >/dev/null 2>&1; then
	MCPBASH_BIN="$(command -v mcp-bash)"
fi
if [[ -z "${MCPBASH_BIN}" ]] && [[ -n "${MCPBASH_HOME:-}" ]] && [[ -x "${MCPBASH_HOME}/bin/mcp-bash" ]]; then
	MCPBASH_BIN="${MCPBASH_HOME}/bin/mcp-bash"
fi
if [[ -z "${MCPBASH_BIN}" ]]; then
	printf 'mcp-bash not found; add to PATH or set MCPBASH_HOME.\n' >&2
	exit 1
fi

sample_args='{"name":"World"}'

tmp_err="$(mktemp "${TMPDIR:-/tmp}/mcpbash.smoke.err.XXXXXX")"
trap 'rm -f "${tmp_err}"' EXIT

output=""
if ! output="$("${MCPBASH_BIN}" run-tool "__NAME__" --args "${sample_args}" 2>"${tmp_err}")"; then
	printf 'Smoke test FAILED: tool execution error\n' >&2
	cat "${tmp_err}" >&2 || true
	exit 1
fi

if [ -s "${tmp_err}" ]; then
	printf 'Smoke test stderr:\n' >&2
	cat "${tmp_err}" >&2 || true
fi

# JSON tool detection for validation (best effort).
json_tool=""
if command -v gojq >/dev/null 2>&1; then
	json_tool="gojq"
elif command -v jq >/dev/null 2>&1; then
	json_tool="jq"
fi

if [[ -z "${json_tool}" ]]; then
	printf 'Skipping JSON validation: jq/gojq not found. Tool output:\n%s\n' "${output}" >&2
	exit 0
fi

validate_filter='(.structuredContent.message // empty | tostring | length > 0) or (.content[]? | select(.type=="text") | (.text // "") | length > 0)'
if ! printf '%s' "${output}" | "${json_tool}" -e "${validate_filter}" >/dev/null 2>&1; then
	printf 'Smoke test FAILED: output is not valid JSON or missing expected content.\n' >&2
	printf '%s\n' "${output}" >&2
	exit 2
fi

printf 'Smoke test passed for __NAME__.\n'
