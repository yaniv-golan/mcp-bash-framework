#!/usr/bin/env bash
# Stress layer: execute stress scripts sequentially.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

VERBOSE="${VERBOSE:-0}"
UNICODE="${UNICODE:-0}"

if [ -z "${MCPBASH_LOG_JSON_TOOL:-}" ] && [ "${VERBOSE}" != "1" ]; then
	MCPBASH_LOG_JSON_TOOL="quiet"
	export MCPBASH_LOG_JSON_TOOL
fi

PASS_ICON="[PASS]"
FAIL_ICON="[FAIL]"
if [ "${UNICODE}" = "1" ]; then
	PASS_ICON="✅"
	FAIL_ICON="❌"
fi

TESTS=(
	"test_concurrency.sh"
	"test_long_running.sh"
	"test_output_guard.sh"
	"test_symlink_race.sh"
)

passed=0
failed=0
total="${#TESTS[@]}"
index=1

for script in "${TESTS[@]}"; do
	printf '[%02d/%02d] %s ... ' "${index}" "${total}" "${script}"
	if "${SCRIPT_DIR}/${script}"; then
		printf '%s\n' "${PASS_ICON}"
		passed=$((passed + 1))
	else
		printf '%s\n' "${FAIL_ICON}" >&2
		failed=$((failed + 1))
	fi
	index=$((index + 1))
done

printf '\nStress summary: %d passed, %d failed\n' "${passed}" "${failed}"

if [ "${failed}" -ne 0 ]; then
	exit 1
fi
