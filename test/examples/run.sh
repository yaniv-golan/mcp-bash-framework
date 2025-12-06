#!/usr/bin/env bash
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
	"test_examples.sh"
	"test_run_tool_smoke.sh"
)

passed=0
failed=0
total="${#TESTS[@]}"
index=1

for test_script in "${TESTS[@]}"; do
	printf '[%02d/%02d] %s ... ' "${index}" "${total}" "${test_script}"
	if "${SCRIPT_DIR}/${test_script}"; then
		printf '%s\n' "${PASS_ICON}"
		passed=$((passed + 1))
	else
		printf '%s\n' "${FAIL_ICON}" >&2
		failed=$((failed + 1))
	fi
	index=$((index + 1))
done

printf '\nExamples summary: %d passed, %d failed\n' "${passed}" "${failed}"

if [ "${failed}" -ne 0 ]; then
	exit 1
fi
