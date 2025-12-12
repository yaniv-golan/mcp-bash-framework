#!/usr/bin/env bash
# Unit: refuse symlinked server.d/register.sh even when hooks enabled.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

# shellcheck source=test/common/env.sh
# shellcheck disable=SC1091
. "${REPO_ROOT}/test/common/env.sh"
# shellcheck source=test/common/assert.sh
# shellcheck disable=SC1091
. "${REPO_ROOT}/test/common/assert.sh"

# shellcheck source=lib/registry.sh
# shellcheck disable=SC1091
. "${REPO_ROOT}/lib/registry.sh"

test_create_tmpdir

project="${TEST_TMPDIR}/proj"
mkdir -p "${project}/server.d"
chmod 700 "${project}" "${project}/server.d" 2>/dev/null || true

export MCPBASH_PROJECT_ROOT="${project}"
export MCPBASH_SERVER_DIR="${project}/server.d"

printf '%s\n' '#!/usr/bin/env bash' >"${project}/evil.sh"
printf '%s\n' 'echo "pwned"' >>"${project}/evil.sh"

ln -s "../evil.sh" "${project}/server.d/register.sh"

printf ' -> rejects symlinked register.sh
'
set +e
mcp_registry_register_check_permissions "${project}/server.d/register.sh"
rc=$?
set -e
if [ "${rc}" -eq 0 ]; then
	test_fail "expected symlinked register.sh to be rejected"
fi

rm -f "${project}/server.d/register.sh"
printf '%s\n' '#!/usr/bin/env bash' >"${project}/server.d/register.sh"
chmod 700 "${project}/server.d/register.sh" 2>/dev/null || true

printf ' -> accepts regular, owned, non-writable register.sh
'
mcp_registry_register_check_permissions "${project}/server.d/register.sh"

