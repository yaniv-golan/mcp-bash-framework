#!/usr/bin/env bash
# Integration: registry size cap enforcement.
# shellcheck disable=SC2034  # Used by test runner for reporting.
TEST_DESC="Registry refresh enforces max bytes thresholds."

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../common/env.sh
# shellcheck disable=SC1091
. "${SCRIPT_DIR}/../common/env.sh"
# shellcheck source=../common/assert.sh
# shellcheck disable=SC1091
. "${SCRIPT_DIR}/../common/assert.sh"

test_create_tmpdir
WORKSPACE="${TEST_TMPDIR}/registry-limits"
test_stage_workspace "${WORKSPACE}"

mkdir -p "${WORKSPACE}/tools"
for i in $(seq 1 5); do
	mkdir -p "${WORKSPACE}/tools/tool${i}"
	cat <<META >"${WORKSPACE}/tools/tool${i}/tool.meta.json"
{"name":"tool${i}","description":"x","arguments":{"type":"object","properties":{}}}
META
	cat <<'SH' >"${WORKSPACE}/tools/tool${i}/tool.sh"
#!/usr/bin/env bash
echo ok
SH
	chmod +x "${WORKSPACE}/tools/tool${i}/tool.sh"
done

output="$(
	MCPBASH_PROJECT_ROOT="${WORKSPACE}" MCPBASH_REGISTRY_MAX_BYTES=200 \
		"${MCPBASH_TEST_ROOT}/bin/mcp-bash" registry refresh --project-root "${WORKSPACE}" --no-notify 2>/dev/null || true
)"

status_tools="$(printf '%s' "${output}" | jq -r '.tools.status // empty' 2>/dev/null || printf '')"
if [ "${status_tools}" != "failed" ] && [ "${status_tools}" != "skipped" ]; then
	printf 'Registry limits test: expected tools.status failed/skipped, got %s\n' "${status_tools}" >&2
	exit 1
fi

printf 'Registry limits test passed.\n'
