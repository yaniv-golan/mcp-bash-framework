#!/usr/bin/env bash
# Integration: health/readiness probe behavior.
# shellcheck disable=SC2034  # Used by test runner for reporting.
TEST_DESC="Health probe exits 0 on ready, 2 on missing project, and avoids registry writes."

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../common/env.sh
# shellcheck disable=SC1091
. "${SCRIPT_DIR}/../common/env.sh"
# shellcheck source=../common/assert.sh
# shellcheck disable=SC1091
. "${SCRIPT_DIR}/../common/assert.sh"

test_require_command jq

test_create_tmpdir
WORKSPACE="${TEST_TMPDIR}/health"
test_stage_workspace "${WORKSPACE}"

# Ready probe: should exit 0, emit status ok, and avoid registry cache writes.
OUT="${WORKSPACE}/health.json"
set +e
(cd "${WORKSPACE}" && MCPBASH_PROJECT_ROOT="${WORKSPACE}" ./bin/mcp-bash --health >"${OUT}")
rc=$?
set -e

assert_eq "0" "${rc}" "health probe should exit 0 when ready"
status="$(jq -r '.status // ""' "${OUT}")"
assert_eq "ok" "${status}" "health status should be ok"

if [ -f "${WORKSPACE}/.registry/tools.json" ] || [ -f "${WORKSPACE}/.registry/resources.json" ] || [ -f "${WORKSPACE}/.registry/prompts.json" ]; then
	test_fail "health probe should not write registry cache files"
fi

# Missing project root should return 2.
set +e
(cd "${WORKSPACE}" && ./bin/mcp-bash --health --project-root "${WORKSPACE}/nope" >/dev/null)
rc_missing=$?
set -e
assert_eq "2" "${rc_missing}" "health probe should exit 2 for missing project root"

# Project health checks: passing checks should show projectChecks=ok
HEALTH_CHECKS_DIR="${WORKSPACE}/server.d"
mkdir -p "${HEALTH_CHECKS_DIR}"
cat >"${HEALTH_CHECKS_DIR}/health-checks.sh" <<'EOF'
#!/usr/bin/env bash
mcp_health_check_command "bash" "Bash shell"
EOF
chmod 755 "${HEALTH_CHECKS_DIR}/health-checks.sh"

OUT_CHECKS="${WORKSPACE}/health_checks.json"
set +e
(cd "${WORKSPACE}" && MCPBASH_PROJECT_ROOT="${WORKSPACE}" ./bin/mcp-bash --health >"${OUT_CHECKS}" 2>/dev/null)
rc_checks=$?
set -e

assert_eq "0" "${rc_checks}" "health probe with passing checks should exit 0"
proj_status="$(jq -r '.projectChecks // ""' "${OUT_CHECKS}")"
assert_eq "ok" "${proj_status}" "projectChecks should be ok when checks pass"

# Project health checks: failing checks should show projectChecks=failed
cat >"${HEALTH_CHECKS_DIR}/health-checks.sh" <<'EOF'
#!/usr/bin/env bash
mcp_health_check_command "nonexistent_command_xyz" "Fake command"
EOF

OUT_FAIL="${WORKSPACE}/health_fail.json"
set +e
(cd "${WORKSPACE}" && MCPBASH_PROJECT_ROOT="${WORKSPACE}" ./bin/mcp-bash --health >"${OUT_FAIL}" 2>/dev/null)
rc_fail=$?
set -e

assert_eq "1" "${rc_fail}" "health probe with failing checks should exit 1"
proj_fail_status="$(jq -r '.projectChecks // ""' "${OUT_FAIL}")"
assert_eq "failed" "${proj_fail_status}" "projectChecks should be failed when checks fail"

printf 'Health probe integration passed.\n'
