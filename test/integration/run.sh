#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../common/env.sh
# shellcheck disable=SC1091
. "${SCRIPT_DIR}/../common/env.sh"
# shellcheck source=../common/assert.sh
# shellcheck disable=SC1091
. "${SCRIPT_DIR}/../common/assert.sh"

VERBOSE="${VERBOSE:-0}"
UNICODE="${UNICODE:-0}"
KEEP_INTEGRATION_LOGS="${KEEP_INTEGRATION_LOGS:-0}"

if [ -z "${MCPBASH_LOG_JSON_TOOL:-}" ] && [ "${VERBOSE}" != "1" ]; then
	MCPBASH_LOG_JSON_TOOL="quiet"
	export MCPBASH_LOG_JSON_TOOL
fi

SUITE_TMP="${MCPBASH_INTEGRATION_TMP:-$(mktemp -d "${TMPDIR:-/tmp}/mcpbash.integration.XXXXXX")}"
LOG_DIR="${SUITE_TMP}/logs"
mkdir -p "${LOG_DIR}"

# Track if any test failed - used to preserve logs on failure
SUITE_FAILED=0

cleanup_suite_tmp() {
	# Always preserve logs on failure or if explicitly requested
	if [ "${KEEP_INTEGRATION_LOGS}" = "1" ] || [ "${SUITE_FAILED}" -ne 0 ]; then
		return
	fi
	if [ -n "${SUITE_TMP}" ] && [ -d "${SUITE_TMP}" ]; then
		rm -rf "${SUITE_TMP}" 2>/dev/null || true
	fi
}
trap cleanup_suite_tmp EXIT INT TERM

PASS_ICON="[PASS]"
FAIL_ICON="[FAIL]"
if [ "${UNICODE}" = "1" ]; then
	PASS_ICON="✅"
	FAIL_ICON="❌"
fi

TESTS=(
	"test_bootstrap.sh"
	"test_capabilities.sh"
	"test_core_errors.sh"
	"test_completion.sh"
	"test_installer.sh"
	"test_tools.sh"
	"test_tools_errors.sh"
	"test_tools_schema.sh"
	"test_prompts.sh"
	"test_resources.sh"
	"test_lifecycle_gating.sh"
	"test_resources_providers.sh"
	"test_minimal_mode.sh"
	"test_protocol_reject_unknown.sh"
	"test_registry_refresh.sh"
	"test_registry_limits.sh"
	"test_progress_logs.sh"
	"test_notification_dedup.sh"
	"test_cancellation.sh"
	"test_cli_guards.sh"
	"test_cli_init_scaffold_server.sh"
	"test_cli_init_config_doctor.sh"
	"test_cli_config_variants.sh"
	"test_cli_validate_fix.sh"
	"test_cli_validate_errors.sh"
	"test_project_root_detection.sh"
	"test_elicitation.sh"
	"test_cli_scaffold_test.sh"
)

passed=0
failed=0
total="${#TESTS[@]}"

get_test_desc() {
	local script="$1"
	local line
	line="$(grep -m1 '^TEST_DESC=' "${SCRIPT_DIR}/${script}" || true)"
	if [ -z "${line}" ]; then
		printf '%s' "${script}"
		return
	fi
	line="${line#TEST_DESC=}"
	line="${line%\"}"
	line="${line#\"}"
	if [ -z "${line}" ]; then
		printf '%s' "${script}"
	else
		printf '%s' "${line}"
	fi
}

run_test() {
	local test_script="$1"
	local index="$2"
	local desc log_file start end elapsed status
	desc="$(get_test_desc "${test_script}")"
	log_file="${LOG_DIR}/${test_script}.log"
	start="$(date +%s)"

	if [ "${VERBOSE}" = "1" ]; then
		(
			set -o pipefail
			"${SCRIPT_DIR}/${test_script}" 2>&1 | while IFS= read -r line || [ -n "${line}" ]; do
				printf '[%s] %s\n' "${test_script}" "${line}"
			done
			exit "${PIPESTATUS[0]}"
		) | tee "${log_file}"
		status="${PIPESTATUS[0]}"
	else
		if "${SCRIPT_DIR}/${test_script}" >"${log_file}" 2>&1; then
			status=0
		else
			status=$?
		fi
	fi

	end="$(date +%s)"
	elapsed=$((end - start))

	if [ "${status}" -eq 0 ]; then
		printf '[%02d/%02d] %s — %s ... %s (%ss)\n' "${index}" "${total}" "${test_script}" "${desc}" "${PASS_ICON}" "${elapsed}"
		passed=$((passed + 1))
	else
		printf '[%02d/%02d] %s — %s ... %s (%ss)\n' "${index}" "${total}" "${test_script}" "${desc}" "${FAIL_ICON}" "${elapsed}" >&2
		printf '  log: %s\n' "${log_file}" >&2
		printf '  --- last 80 lines of log ---\n' >&2
		tail -n 80 "${log_file}" >&2 || true
		printf '  --- end of log snippet ---\n' >&2
		failed=$((failed + 1))
	fi
}

index=1
suite_start="$(date +%s)"

# Log platform info for debugging
if [ "${VERBOSE}" = "1" ]; then
	printf 'Platform: %s\n' "$(uname -a)"
	printf 'Bash: %s\n' "${BASH_VERSION}"
	printf 'Log dir: %s\n\n' "${LOG_DIR}"
fi

for test_script in "${TESTS[@]}"; do
	run_test "${test_script}" "${index}"
	index=$((index + 1))
done

suite_end="$(date +%s)"
suite_elapsed=$((suite_end - suite_start))

log_note="${LOG_DIR}"
if [ "${KEEP_INTEGRATION_LOGS}" != "1" ] && [ "${failed}" -eq 0 ]; then
	log_note="${LOG_DIR} (will be removed on success; preserved on failure)"
fi

printf '\nIntegration summary: %d passed, %d failed (logs: %s, elapsed: %ss)\n' "${passed}" "${failed}" "${log_note}" "${suite_elapsed}"

if [ "${failed}" -ne 0 ]; then
	SUITE_FAILED=1
	exit 1
fi
