#!/usr/bin/env bash
# Integration: scaffolded tool ships a runnable smoke test.
# shellcheck disable=SC2034  # Used by test runner for reporting.
TEST_DESC="Scaffolded tool smoke.sh passes by default and fails on bad output."

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../common/env.sh
# shellcheck disable=SC1091
. "${SCRIPT_DIR}/../common/env.sh"
# shellcheck source=../common/assert.sh
# shellcheck disable=SC1091
. "${SCRIPT_DIR}/../common/assert.sh"

test_create_tmpdir
export MCPBASH_STAGING_TAR=0
WORKSPACE="${TEST_TMPDIR}/workspace"
test_stage_workspace "${WORKSPACE}"
export TMPDIR="${WORKSPACE}/.tmp"

# Minimal server metadata for the scaffolded project.
mkdir -p "${WORKSPACE}/server.d"
cat >"${WORKSPACE}/server.d/server.meta.json" <<'META'
{
  "name": "smoke-demo"
}
META

# Scaffold the tool (uses the staged framework).
(
	cd "${WORKSPACE}" || exit 1
	MCPBASH_HOME="${WORKSPACE}" MCPBASH_PROJECT_ROOT="${WORKSPACE}" PATH="${WORKSPACE}/bin:${PATH}" \
		./bin/mcp-bash scaffold tool demo >/dev/null
)

# Happy path: smoke.sh should pass.
if ! (cd "${WORKSPACE}/tools/demo" && MCPBASH_HOME="${WORKSPACE}" MCPBASH_PROJECT_ROOT="${WORKSPACE}" PATH="${WORKSPACE}/bin:${PATH}" ./smoke.sh >/dev/null); then
	printf 'scaffolded smoke.sh should pass by default\n' >&2
	exit 1
fi

# Corrupt tool output to trigger JSON validation failure.
cat >"${WORKSPACE}/tools/demo/tool.sh" <<'BAD'
#!/usr/bin/env bash
set -euo pipefail
printf 'not-json'
BAD
chmod +x "${WORKSPACE}/tools/demo/tool.sh"

if (cd "${WORKSPACE}/tools/demo" && MCPBASH_HOME="${WORKSPACE}" MCPBASH_PROJECT_ROOT="${WORKSPACE}" PATH="${WORKSPACE}/bin:${PATH}" ./smoke.sh >/dev/null); then
	printf 'scaffolded smoke.sh should fail on invalid JSON output\n' >&2
	exit 1
fi

# Test: scaffold ui standalone
(
	cd "${WORKSPACE}" || exit 1
	MCPBASH_HOME="${WORKSPACE}" MCPBASH_PROJECT_ROOT="${WORKSPACE}" PATH="${WORKSPACE}/bin:${PATH}" \
		./bin/mcp-bash scaffold ui dashboard >/dev/null
)
[ -f "${WORKSPACE}/ui/dashboard/index.html" ] || {
	printf 'scaffold ui: index.html not created\n' >&2
	exit 1
}
grep -q "cdn.jsdelivr.net" "${WORKSPACE}/ui/dashboard/ui.meta.json" || {
	printf 'scaffold ui: CSP missing jsdelivr\n' >&2
	exit 1
}

# Test: scaffold tool --ui
(
	cd "${WORKSPACE}" || exit 1
	MCPBASH_HOME="${WORKSPACE}" MCPBASH_PROJECT_ROOT="${WORKSPACE}" PATH="${WORKSPACE}/bin:${PATH}" \
		./bin/mcp-bash scaffold tool weather --ui >/dev/null
)
[ -f "${WORKSPACE}/tools/weather/ui/index.html" ] || {
	printf 'scaffold tool --ui: UI not created with tool\n' >&2
	exit 1
}
[ -f "${WORKSPACE}/tools/weather/ui/ui.meta.json" ] || {
	printf 'scaffold tool --ui: ui.meta.json not created\n' >&2
	exit 1
}

printf 'Scaffolded smoke test coverage passed.\n'
