#!/usr/bin/env bash
# Compatibility: placeholder for proxy bridge smoke test.

set -euo pipefail

if [ -z "${MCP_COMPAT_PROXY_BIN:-}" ]; then
	printf 'SKIP: Set MCP_COMPAT_PROXY_BIN to run proxy compatibility tests.\n'
	exit 0
fi

printf 'SKIP: HTTP proxy compatibility harness not yet implemented (MCP_COMPAT_PROXY_BIN=%s).\n' "${MCP_COMPAT_PROXY_BIN}"
exit 0
