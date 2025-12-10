#!/usr/bin/env bash
# Unified test runner to sequence common suites.

set -euo pipefail

SKIP_INTEGRATION=false
SKIP_EXAMPLES=false
SKIP_STRESS=false
SKIP_SMOKE=false

usage() {
	printf 'Usage: %s [--skip-integration] [--skip-examples] [--skip-stress] [--skip-smoke]\n' "$0"
}

while [ $# -gt 0 ]; do
	case "$1" in
	--skip-integration) SKIP_INTEGRATION=true ;;
	--skip-examples) SKIP_EXAMPLES=true ;;
	--skip-stress) SKIP_STRESS=true ;;
	--skip-smoke) SKIP_SMOKE=true ;;
	-h | --help)
		usage
		exit 0
		;;
	*)
		printf 'Unknown option: %s\n' "$1" >&2
		usage
		exit 1
		;;
	esac
	shift
done

run_step() {
	local label="$1"
	local cmd="$2"
	printf '==> %s\n' "${label}"
	eval "${cmd}"
}

run_step "Lint" "./test/lint.sh"
run_step "Unit tests" "./test/unit/run.sh"

if [ "${SKIP_INTEGRATION}" != "true" ]; then
	run_step "Integration tests" "./test/integration/run.sh"
fi

if [ "${SKIP_EXAMPLES}" != "true" ]; then
	run_step "Examples suite" "./test/examples/run.sh"
fi

if [ "${SKIP_STRESS}" != "true" ]; then
	run_step "Stress suite" "./test/stress/run.sh"
fi

if [ "${SKIP_SMOKE}" != "true" ]; then
	run_step "Smoke tests" "./test/smoke.sh"
fi

printf '\nAll selected suites completed.\n'
