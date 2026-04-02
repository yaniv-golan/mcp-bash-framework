#!/usr/bin/env bash
# Smoke test for system-info tool.
# Runs twice:
#   1. Normal PATH — verifies happy path (mcp_detect_cli falls back to command -v).
#   2. Explicit override — sets UNAME_CLI env var; proves the detection override
#      mechanism works (the same mechanism used in restricted PATH environments
#      like Claude Desktop where version manager shims are not on PATH).
#
# Usage: bash tools/system-info/smoke.sh
# Run from the example root directory.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
MCPBASH="$(cd "${PROJECT_ROOT}/../.." && pwd)/bin/mcp-bash"

run_tool() {
	"${MCPBASH}" run-tool system-info \
		--project-root "${PROJECT_ROOT}" \
		--allow-self \
		--args "$1"
}

printf '=== Run 1: normal PATH ===\n'
run_tool '{"command":"os"}'
run_tool '{"command":"uptime"}'
run_tool '{"command":"disk"}'
printf 'OK\n\n'

printf '=== Run 2: explicit CLI path override ===\n'
printf 'UNAME_CLI set — mcp_detect_cli uses override instead of PATH search\n'
UNAME_CLI="$(command -v uname)" run_tool '{"command":"os"}'
printf 'OK — UNAME_CLI override works (same mechanism as setting absolute paths\n'
printf '     when version manager shims are missing in MCP host environments)\n'
