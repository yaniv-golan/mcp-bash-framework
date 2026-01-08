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
TIMEOUT_ICON="[TIMEOUT]"
if [ "${UNICODE}" = "1" ]; then
	PASS_ICON="✅"
	FAIL_ICON="❌"
fi

TESTS=(
	"test_bootstrap.sh"
	"test_capabilities.sh"
	"test_core_errors.sh"
	"test_completion.sh"
	"test_conformance_strict_shapes.sh"
	"test_installer.sh"
	"test_tools.sh"
	"test_tools_meta.sh"
	"test_windows_env_size_tools_call.sh"
	"test_windows_env_size_providers.sh"
	"test_windows_registry_large_icons.sh"
	"test_tools_policy.sh"
	"test_tools_errors.sh"
	"test_tools_schema.sh"
	"test_prompts.sh"
	"test_project_hooks_disabled.sh"
	"test_register_json.sh"
	"test_resources.sh"
	"test_resource_templates.sh"
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
	"test_cli_init_new.sh"
	"test_cli_init_config_doctor.sh"
	"test_cli_config_variants.sh"
	"test_cli_run_tool_allow_self.sh"
	"test_cli_validate.sh"
	"test_project_root_detection.sh"
	"test_elicitation.sh"
	"test_elicitation_modes.sh"
	"test_icons.sh"
	"test_cli_scaffold_test.sh"
	"test_remote_token.sh"
	"test_health_probe.sh"
	"test_scaffold_smoke.sh"
)

passed=0
failed=0

MCPBASH_INTEGRATION_TEST_TIMEOUT_SECONDS="${MCPBASH_INTEGRATION_TEST_TIMEOUT_SECONDS:-0}"
export MCPBASH_INTEGRATION_TEST_TIMEOUT_SECONDS

test_exists_in_suite() {
	local want="$1"
	local t
	for t in "${TESTS[@]}"; do
		if [ "${t}" = "${want}" ]; then
			return 0
		fi
	done
	return 1
}

apply_only_and_skip_filters() {
	local only_raw="${MCPBASH_INTEGRATION_ONLY:-}"
	local skip_raw="${MCPBASH_INTEGRATION_SKIP:-}"

	local -a selected=()
	local token

	if [ -n "${only_raw}" ]; then
		for token in ${only_raw}; do
			if ! test_exists_in_suite "${token}"; then
				printf 'Unknown test in MCPBASH_INTEGRATION_ONLY: %s\n' "${token}" >&2
				exit 1
			fi
			local already=false
			local s
			for s in "${selected[@]}"; do
				if [ "${s}" = "${token}" ]; then
					already=true
					break
				fi
			done
			if [ "${already}" != true ]; then
				selected+=("${token}")
			fi
		done
	else
		selected=("${TESTS[@]}")
	fi

	if [ -n "${skip_raw}" ]; then
		for token in ${skip_raw}; do
			if ! test_exists_in_suite "${token}"; then
				printf 'Unknown test in MCPBASH_INTEGRATION_SKIP: %s\n' "${token}" >&2
				exit 1
			fi
			local -a filtered=()
			local s
			for s in "${selected[@]}"; do
				if [ "${s}" != "${token}" ]; then
					filtered+=("${s}")
				fi
			done
			selected=("${filtered[@]}")
		done
	fi

	TESTS=("${selected[@]}")
}

apply_only_and_skip_filters
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

run_with_timeout() {
	local timeout_seconds="$1"
	shift

	"$@" &
	local pid=$!

	if [ "${timeout_seconds}" -le 0 ]; then
		wait "${pid}"
		return $?
	fi

	local deadline=$((SECONDS + timeout_seconds))
	while kill -0 "${pid}" 2>/dev/null; do
		if [ "${SECONDS}" -ge "${deadline}" ]; then
			kill -TERM "${pid}" 2>/dev/null || true
			sleep 2 2>/dev/null || sleep 2
			kill -KILL "${pid}" 2>/dev/null || true
			wait "${pid}" 2>/dev/null || true
			return 124
		fi
		sleep 1 2>/dev/null || sleep 1
	done

	wait "${pid}"
	return $?
}

run_verbose_test_to_log() {
	local test_script="$1"
	local log_file="$2"

	(
		set -o pipefail
		bash "${SCRIPT_DIR}/${test_script}" 2>&1 | while IFS= read -r line || [ -n "${line}" ]; do
			printf '[%s] %s\n' "${test_script}" "${line}"
		done
		exit "${PIPESTATUS[0]}"
	) | tee "${log_file}"
	return "${PIPESTATUS[0]}"
}

run_quiet_test_to_log() {
	local test_script="$1"
	local log_file="$2"
	bash "${SCRIPT_DIR}/${test_script}" >"${log_file}" 2>&1
}

# Re-run a failed test with bash -x tracing for debugging
# Enabled by MCPBASH_INTEGRATION_DEBUG_FAILED=true
run_debug_trace() {
	local test_script="$1"
	local trace_file="${LOG_DIR}/${test_script}.trace.log"

	printf '  --- re-running with bash -x trace ---\n' >&2
	# Run with xtrace, capture to separate file
	# Use MCPBASH_DEBUG=true to enable debug EXIT trap as well
	MCPBASH_DEBUG=true bash -x "${SCRIPT_DIR}/${test_script}" >"${trace_file}" 2>&1 || true
	printf '  trace log: %s\n' "${trace_file}" >&2

	# Show last 50 lines of trace (most relevant for debugging)
	if [ -f "${trace_file}" ]; then
		printf '  --- last 50 lines of trace ---\n' >&2
		tail -50 "${trace_file}" >&2 || true
		printf '  --- end of trace ---\n' >&2
	fi
}

run_test() {
	local test_script="$1"
	local index="$2"
	local desc log_file start end elapsed status timed_out status_icon
	desc="$(get_test_desc "${test_script}")"
	log_file="${LOG_DIR}/${test_script}.log"
	start="$(date +%s)"
	timed_out=false

	if [ "${VERBOSE}" = "1" ]; then
		if run_with_timeout "${MCPBASH_INTEGRATION_TEST_TIMEOUT_SECONDS}" run_verbose_test_to_log "${test_script}" "${log_file}"; then
			status=0
		else
			status=$?
		fi
	else
		if run_with_timeout "${MCPBASH_INTEGRATION_TEST_TIMEOUT_SECONDS}" run_quiet_test_to_log "${test_script}" "${log_file}"; then
			status=0
		else
			status=$?
		fi
	fi

	if [ "${status}" -eq 124 ]; then
		timed_out=true
	fi

	end="$(date +%s)"
	elapsed=$((end - start))

	if [ "${status}" -eq 0 ]; then
		printf '[%02d/%02d] %s — %s ... %s (%ss)\n' "${index}" "${total}" "${test_script}" "${desc}" "${PASS_ICON}" "${elapsed}"
		passed=$((passed + 1))
	else
		status_icon="${FAIL_ICON}"
		if [ "${timed_out}" = true ]; then
			status_icon="${TIMEOUT_ICON}"
		fi
		printf '[%02d/%02d] %s — %s ... %s (%ss)\n' "${index}" "${total}" "${test_script}" "${desc}" "${status_icon}" "${elapsed}" >&2
		printf '  log: %s\n' "${log_file}" >&2
		# Copy the failing test log into MCPBASH_LOG_DIR (CI uploads it reliably).
		if command -v test_capture_failure_bundle >/dev/null 2>&1; then
			test_capture_failure_bundle "integration.${test_script}" "" "" "${log_file}"
		fi
		printf '  --- full log output ---\n' >&2
		cat "${log_file}" >&2 || true
		printf '  --- end of log ---\n' >&2

		# Re-run with bash -x trace if debug mode is enabled
		if [ "${MCPBASH_INTEGRATION_DEBUG_FAILED:-false}" = "true" ] && [ "${timed_out}" != true ]; then
			run_debug_trace "${test_script}"
		fi

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
