#!/usr/bin/env bash
# Spec §18 compatibility: placeholder to run Python SDK compatibility smoke tests.

set -euo pipefail

if [ -z "${MCP_COMPAT_PYTHON_CLIENT:-}" ]; then
	printf 'SKIP: Set MCP_COMPAT_PYTHON_CLIENT to run Python SDK compatibility tests.\n'
	exit 0
fi

printf 'Python SDK compatibility harness not yet implemented.\n' >&2
exit 1
