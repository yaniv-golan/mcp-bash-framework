#!/usr/bin/env bash
# Stress layer: execute stress scripts sequentially.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

TESTS=(
	"test_concurrency.sh"
	"test_long_running.sh"
	"test_output_guard.sh"
)

passed=0
failed=0

for script in "${TESTS[@]}"; do
	printf '== %s ==\n' "${script}"
	if "${SCRIPT_DIR}/${script}"; then
		printf '✅ %s\n' "${script}"
		passed=$((passed + 1))
	else
		printf '❌ %s\n' "${script}" >&2
		failed=$((failed + 1))
	fi
done

printf '\nStress summary: %d passed, %d failed\n' "${passed}" "${failed}"

if [ "${failed}" -ne 0 ]; then
	exit 1
fi
