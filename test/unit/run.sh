#!/usr/bin/env bash
# Run unit tests using bats-core directly.
#
# Usage:
#   test/unit/run.sh              # Run all unit tests
#   test/unit/run.sh foo.bats     # Run specific test file(s)
#
# Environment:
#   VERBOSE=1                     # Show verbose output
#   MCPBASH_LOG_JSON_TOOL=quiet   # Suppress jq/gojq selection messages
#   CI=true                       # Output JUnit XML to test-results/ (auto-set in GitHub Actions)
#   JUNIT_OUTPUT_DIR=path         # Override JUnit output directory (default: test-results)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

VERBOSE="${VERBOSE:-0}"

# Suppress jq/gojq selection noise in non-verbose mode
if [ -z "${MCPBASH_LOG_JSON_TOOL:-}" ] && [ "${VERBOSE}" != "1" ]; then
	MCPBASH_LOG_JSON_TOOL="quiet"
	export MCPBASH_LOG_JSON_TOOL
fi

# Build list of test files
if [ "$#" -gt 0 ]; then
	# Run specific tests passed as arguments
	BATS_FILES=()
	for arg in "$@"; do
		if [ -f "${arg}" ]; then
			BATS_FILES+=("${arg}")
		elif [ -f "${SCRIPT_DIR}/${arg}" ]; then
			BATS_FILES+=("${SCRIPT_DIR}/${arg}")
		else
			# Try glob matching
			while IFS= read -r match; do
				BATS_FILES+=("${match}")
			done < <(find "${SCRIPT_DIR}" -maxdepth 1 -type f -name "*${arg}*" -name '*.bats' 2>/dev/null || true)
		fi
	done

	if [ "${#BATS_FILES[@]}" -eq 0 ]; then
		printf 'No tests matched: %s\n' "$*" >&2
		exit 1
	fi
else
	# Run all tests
	BATS_FILES=("${SCRIPT_DIR}"/*.bats)
fi

# Determine bats options
BATS_OPTS=()

# In CI, output JUnit XML for test result visualization
if [ -n "${CI:-}" ]; then
	JUNIT_DIR="${JUNIT_OUTPUT_DIR:-${SCRIPT_DIR}/../../test-results}"
	mkdir -p "${JUNIT_DIR}"
	# Use report-formatter for JUnit XML output to file
	BATS_OPTS+=(--report-formatter junit --output "${JUNIT_DIR}")
	# Use TAP for stdout (CI logs)
	BATS_OPTS+=(--formatter tap)
else
	BATS_OPTS+=(--pretty)
fi

# Enable parallel execution on POSIX systems (not Windows/Git Bash)
# bats --jobs requires GNU parallel to be installed
if [[ "${OSTYPE:-}" != msys* && "${OSTYPE:-}" != cygwin* ]] && command -v parallel >/dev/null 2>&1; then
	# Use available cores, default to 4
	jobs="$(nproc 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 4)"
	BATS_OPTS+=(--jobs "${jobs}")
fi

# Run bats
exec bats "${BATS_OPTS[@]}" "${BATS_FILES[@]}"
