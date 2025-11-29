#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../common/env.sh
# shellcheck disable=SC1091
. "${SCRIPT_DIR}/../common/env.sh"
# shellcheck source=../common/assert.sh
# shellcheck disable=SC1091
. "${SCRIPT_DIR}/../common/assert.sh"

TESTS=(
	"test_capabilities.sh"
	"test_core_errors.sh"
	"test_completion.sh"
	"test_tools.sh"
	"test_tools_errors.sh"
	"test_tools_schema.sh"
	"test_prompts.sh"
	"test_resources.sh"
	"test_lifecycle_gating.sh"
	"test_resources_providers.sh"
	"test_minimal_mode.sh"
	"test_minimal_forced.sh"
	"test_protocol_reject_unknown.sh"
	"test_registry_refresh.sh"
	"test_registry_limits.sh"
	"test_progress_logs.sh"
	"test_notification_dedup.sh"
	"test_cancellation.sh"
	"test_cli_guards.sh"
)

passed=0
failed=0

for test_script in "${TESTS[@]}"; do
	printf '== %s ==\n' "${test_script}"
	if "${SCRIPT_DIR}/${test_script}"; then
		printf '✅ %s\n' "${test_script}"
		passed=$((passed + 1))
	else
		printf '❌ %s\n' "${test_script}" >&2
		failed=$((failed + 1))
	fi
done

printf '\nIntegration summary: %d passed, %d failed\n' "${passed}" "${failed}"

if [ "${failed}" -ne 0 ]; then
	exit 1
fi
