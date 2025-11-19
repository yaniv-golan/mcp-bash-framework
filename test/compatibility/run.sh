#!/usr/bin/env bash
# Compatibility layer: orchestrate compatibility suites.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

TESTS=(
	"inspector.sh"
	"sdk_typescript.sh"
	"http_proxy.sh"
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

printf '\nCompatibility summary: %d passed, %d failed\n' "${passed}" "${failed}"

if [ "${failed}" -ne 0 ]; then
	exit 1
fi
