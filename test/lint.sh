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

# Verify core libs can be sourced with /bin/bash (macOS 3.2 compatibility)
# This is the definitive test - actually try to source the libs with bash 3.2
if [ -x /bin/bash ]; then
	printf 'Checking Bash 3.2 compatibility (/bin/bash)...\n'
	bash32_source_test='
		set -euo pipefail
		MCPBASH_HOME="'"${MCPBASH_HOME}"'"
		MCPBASH_STATE_DIR="/tmp/mcpbash-lint-test.$$"
		MCPBASH_JSON_TOOL="none"
		MCPBASH_JSON_TOOL_BIN=""
		export MCPBASH_HOME MCPBASH_STATE_DIR MCPBASH_JSON_TOOL MCPBASH_JSON_TOOL_BIN
		mkdir -p "${MCPBASH_STATE_DIR}"
		trap "rm -rf \"${MCPBASH_STATE_DIR}\"" EXIT
		# Source core libs that must work with bash 3.2
		for lib in require runtime json capabilities ui ui-templates; do
			if [ -f "${MCPBASH_HOME}/lib/${lib}.sh" ]; then
				source "${MCPBASH_HOME}/lib/${lib}.sh" || {
					printf "FAIL: lib/%s.sh cannot be sourced with /bin/bash\n" "${lib}" >&2
					exit 1
				}
			fi
		done
		printf "OK: Core libs source cleanly with /bin/bash %s\n" "${BASH_VERSION}"
	'
	if ! /bin/bash -c "${bash32_source_test}" 2>&1; then
		test_fail "/bin/bash compatibility check failed - libs cannot be sourced with system bash"
	fi
else
	printf 'Skipping /bin/bash compatibility check (not available)\n'
fi

printf 'Lint completed successfully.\n'
