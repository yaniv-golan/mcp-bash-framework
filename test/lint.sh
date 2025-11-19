#!/usr/bin/env bash
# Lint layer: run shellcheck and shfmt with Bash 3.2 settings.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common/env.sh
# shellcheck disable=SC1091
. "${SCRIPT_DIR}/common/env.sh"
# shellcheck source=common/assert.sh
# shellcheck disable=SC1091
. "${SCRIPT_DIR}/common/assert.sh"

test_require_command shellcheck
test_require_command shfmt

existing_files=()
while IFS= read -r -d '' path; do
	if [ -f "${path}" ]; then
		existing_files+=("${path}")
	fi
done < <(git ls-files -z -- '*.sh')

if [ ${#existing_files[@]} -eq 0 ]; then
	printf 'No tracked shell scripts found.\n'
	exit 0
fi

printf 'Running shellcheck...\n'
if ! shellcheck -x "${existing_files[@]}"; then
	test_fail "shellcheck detected issues"
fi

printf 'Running shfmt...\n'
SHFMT_FLAGS=(-bn -kp)
if ! shfmt -d "${SHFMT_FLAGS[@]}" "${existing_files[@]}"; then
	test_fail "shfmt formatting drift detected"
fi

printf 'Lint completed successfully.\n'
