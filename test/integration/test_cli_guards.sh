#!/usr/bin/env bash
# Integration: CLI guard for missing MCPBASH_PROJECT_ROOT.

set -euo pipefail

output="$(MCPBASH_PROJECT_ROOT='' ./bin/mcp-bash scaffold tool foo 2>&1 >/dev/null || true)"

if ! printf '%s' "${output}" | grep -qi 'MCPBASH_PROJECT_ROOT is not set'; then
	printf 'Expected scaffold guard error when MCPBASH_PROJECT_ROOT missing.\n' >&2
	exit 1
fi

printf 'CLI guard test passed.\n'
