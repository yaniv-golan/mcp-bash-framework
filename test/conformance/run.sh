#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

test_script="${ROOT}/test/integration/test_conformance_strict_shapes.sh"
if [ ! -f "${test_script}" ]; then
	printf 'Missing conformance test: %s\n' "${test_script}" >&2
	exit 1
fi

run_one() {
	local tool="$1"
	if ! command -v "${tool}" >/dev/null 2>&1; then
		printf '[SKIP] %s not found\n' "${tool}" >&2
		return 0
	fi
	printf '[RUN] conformance with server JSON tool=%s\n' "${tool}" >&2
	MCPBASH_CONFORMANCE_SERVER_JSON_TOOL="${tool}" bash "${test_script}"
}

run_one jq
run_one gojq
