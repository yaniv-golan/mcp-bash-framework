#!/usr/bin/env bash
# Unit: resources provider dispatch should not depend on executable bit.
#
# Git Bash/MSYS can ignore execute bits; resource providers should still run
# when the script exists and looks runnable (shebang / .sh extension).

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

# shellcheck source=test/common/env.sh
# shellcheck disable=SC1091
. "${REPO_ROOT}/test/common/env.sh"
# shellcheck source=test/common/assert.sh
# shellcheck disable=SC1091
. "${REPO_ROOT}/test/common/assert.sh"

# shellcheck source=lib/resources.sh
# shellcheck disable=SC1091
. "${REPO_ROOT}/lib/resources.sh"

test_create_tmpdir

export MCPBASH_TMP_ROOT="${TEST_TMPDIR}"
export MCPBASH_HOME="${TEST_TMPDIR}/home"
export MCPBASH_RESOURCES_DIR="${TEST_TMPDIR}/resources"
mkdir -p "${MCPBASH_HOME}/providers" "${MCPBASH_RESOURCES_DIR}"

cat >"${MCPBASH_HOME}/providers/git.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s' "ok:provider-ran:${1}"
EOF

# Intentionally do NOT chmod +x to simulate Git Bash/MSYS execute-bit issues.
chmod -x "${MCPBASH_HOME}/providers/git.sh" 2>/dev/null || true

printf ' -> runs non-executable provider via bash fallback\n'
out="$(mcp_resources_read_via_provider "git" "git+https://example/repo#main:README.md")"
assert_eq "ok:provider-ran:git+https://example/repo#main:README.md" "${out}" "expected provider to run via bash fallback"

printf 'resources provider exec fallback test passed.\n'

