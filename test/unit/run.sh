#!/usr/bin/env bash
# Orchestrate unit-layer scripts with TAP-style status output.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

UNIT_TESTS=()
while IFS= read -r path; do
	UNIT_TESTS+=("${path}")
done < <(find "${SCRIPT_DIR}" -maxdepth 1 -type f -name '*.bats' -print | sort)

if [ "${#UNIT_TESTS[@]}" -eq 0 ]; then
	printf '%s\n' "No unit tests discovered under ${SCRIPT_DIR}" >&2
	exit 1
fi

passed=0
failed=0

for test_script in "${UNIT_TESTS[@]}"; do
	name="$(basename "${test_script}")"
	printf '== %s ==\n' "${name}"
	if bash "${test_script}"; then
		printf '✅ %s\n' "${name}"
		passed=$((passed + 1))
	else
		printf '❌ %s\n' "${name}" >&2
		failed=$((failed + 1))
	fi
done

printf '\nUnit summary: %d passed, %d failed\n' "${passed}" "${failed}"

if [ "${failed}" -ne 0 ]; then
	exit 1
fi
