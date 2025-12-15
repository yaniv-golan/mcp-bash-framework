#!/usr/bin/env bash
# Orchestrate unit-layer scripts with TAP-style status output.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

VERBOSE="${VERBOSE:-0}"
UNICODE="${UNICODE:-0}"
UNIT_TIMEOUT_SECONDS="${MCPBASH_UNIT_TEST_TIMEOUT_SECONDS:-120}"

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

UNIT_TESTS=()
while IFS= read -r path; do
	UNIT_TESTS+=("${path}")
done < <(find "${SCRIPT_DIR}" -maxdepth 1 -type f -name '*.bats' -print | sort)

if [ "${#UNIT_TESTS[@]}" -eq 0 ]; then
	printf '%s\n' "No unit tests discovered under ${SCRIPT_DIR}" >&2
	exit 1
fi

if [ "$#" -gt 0 ]; then
	SELECTED_TESTS=()
	for arg in "$@"; do
		if [ -f "${SCRIPT_DIR}/${arg}" ]; then
			SELECTED_TESTS+=("${SCRIPT_DIR}/${arg}")
			continue
		fi

		match=""
		for path in "${UNIT_TESTS[@]}"; do
			if [ "$(basename "${path}")" = "${arg}" ]; then
				match="${path}"
				break
			fi
		done

		if [ -n "${match}" ]; then
			SELECTED_TESTS+=("${match}")
			continue
		fi

		for path in "${UNIT_TESTS[@]}"; do
			case "${path}" in
			*"${arg}"*)
				SELECTED_TESTS+=("${path}")
				;;
			esac
		done
	done

	if [ "${#SELECTED_TESTS[@]}" -eq 0 ]; then
		printf '%s\n' "No unit tests matched: $*" >&2
		exit 1
	fi

	UNIT_TESTS=("${SELECTED_TESTS[@]}")
fi

current_pgid=""

cleanup_current_test() {
	set +e
	if [ -n "${current_pgid}" ]; then
		kill -TERM -- "-${current_pgid}" 2>/dev/null || true
		sleep 1
		kill -KILL -- "-${current_pgid}" 2>/dev/null || true
		current_pgid=""
	fi
}

trap 'cleanup_current_test; exit 130' INT
trap 'cleanup_current_test; exit 143' TERM

run_test_script() {
	local test_script="$1"
	local pid=""
	local pgid=""
	local timer_pid=""

	if command -v setsid >/dev/null 2>&1; then
		setsid bash "${test_script}" &
		pid="$!"
		pgid="${pid}"
	else
		bash "${test_script}" &
		pid="$!"
		pgid="$(ps -o pgid= "${pid}" 2>/dev/null | tr -d ' ' || true)"
		if [ -z "${pgid}" ]; then
			pgid="${pid}"
		fi
	fi

	current_pgid="${pgid}"

	if [ "${UNIT_TIMEOUT_SECONDS}" -gt 0 ] 2>/dev/null; then
		(
			sleep "${UNIT_TIMEOUT_SECONDS}"
			kill -TERM -- "-${pgid}" 2>/dev/null || true
			sleep 1
			kill -KILL -- "-${pgid}" 2>/dev/null || true
		) &
		timer_pid="$!"
	fi

	set +e
	wait "${pid}"
	local status="$?"
	set -e

	if [ -n "${timer_pid}" ]; then
		kill "${timer_pid}" 2>/dev/null || true
		wait "${timer_pid}" 2>/dev/null || true
	fi

	current_pgid=""

	return "${status}"
}

passed=0
failed=0
total="${#UNIT_TESTS[@]}"
index=1

for test_script in "${UNIT_TESTS[@]}"; do
	name="$(basename "${test_script}")"
	printf '[%02d/%02d] %s ... ' "${index}" "${total}" "${name}"
	if run_test_script "${test_script}"; then
		printf '%s\n' "${PASS_ICON}"
		passed=$((passed + 1))
	else
		printf '%s\n' "${FAIL_ICON}" >&2
		failed=$((failed + 1))
	fi
	index=$((index + 1))
done

printf '\nUnit summary: %d passed, %d failed\n' "${passed}" "${failed}"

if [ "${failed}" -ne 0 ]; then
	exit 1
fi
