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
	case "${path}" in
	*.orig) continue ;;
	esac
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

# Custom lint: detect dangerous "local var; var=$(cmd)" pattern that causes
# set -e to exit on command failure. The safe pattern is "local var=$(cmd)"
# which masks the exit code via the local builtin.
printf 'Checking for dangerous local+assignment pattern...\n'
dangerous_pattern_found=0
for file in "${existing_files[@]}"; do
	# Look for: local var\n followed by var=$(
	# This pattern causes set -e to exit when the command substitution fails
	if grep -Pzo 'local\s+(\w+)\s*\n[^\n]*\1=\$\(' "${file}" >/dev/null 2>&1; then
		# Verify it's not protected with || true
		matches=$(grep -Pzo 'local\s+(\w+)\s*\n[^\n]*\1=\$\([^)]*\)(?!\s*\|\|\s*true)' "${file}" 2>/dev/null || true)
		if [ -n "${matches}" ]; then
			printf 'WARNING: Dangerous local+assignment pattern in %s\n' "${file}" >&2
			printf '  Pattern "local var; var=\$(cmd)" causes set -e exit on cmd failure.\n' >&2
			printf '  Use "local var=\$(cmd)" or "var=\$(cmd) || true" instead.\n' >&2
			dangerous_pattern_found=1
		fi
	fi
done
if [ "${dangerous_pattern_found}" -eq 1 ]; then
	printf 'Consider fixing the above patterns to avoid set -e issues.\n' >&2
	# Warning only - don't fail the build (too noisy for existing code)
fi

printf 'Lint completed successfully.\n'
