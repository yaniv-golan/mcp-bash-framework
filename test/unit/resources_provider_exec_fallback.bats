#!/usr/bin/env bats
# Unit: resources provider dispatch should not depend on executable bit.
#
# Git Bash/MSYS can ignore execute bits; resource providers should still run
# when the script exists and looks runnable (shebang / .sh extension).

load '../../node_modules/bats-support/load'
load '../../node_modules/bats-assert/load'
load '../common/fixtures'

setup() {
	# shellcheck source=lib/resources.sh
	# shellcheck disable=SC1091
	. "${MCPBASH_HOME}/lib/resources.sh"

	export MCPBASH_TMP_ROOT="${BATS_TEST_TMPDIR}"
	export MCPBASH_HOME="${BATS_TEST_TMPDIR}/home"
	export MCPBASH_PROJECT_ROOT="${BATS_TEST_TMPDIR}/project"
	export MCPBASH_PROVIDERS_DIR="${MCPBASH_PROJECT_ROOT}/providers"
	export MCPBASH_RESOURCES_DIR="${BATS_TEST_TMPDIR}/resources"
	mkdir -p "${MCPBASH_HOME}/providers" "${MCPBASH_PROVIDERS_DIR}" "${MCPBASH_RESOURCES_DIR}"
}

@test "resources_provider_exec_fallback: runs non-executable framework provider via bash fallback" {
	cat >"${MCPBASH_HOME}/providers/git.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s' "ok:provider-ran:${1}"
EOF

	# Intentionally do NOT chmod +x to simulate Git Bash/MSYS execute-bit issues.
	chmod -x "${MCPBASH_HOME}/providers/git.sh" 2>/dev/null || true

	out="$(mcp_resources_read_via_provider "git" "git+https://example/repo#main:README.md")"
	assert_equal "ok:provider-ran:git+https://example/repo#main:README.md" "${out}"
}

@test "resources_provider_exec_fallback: runs non-executable project provider via bash fallback" {
	cat >"${MCPBASH_HOME}/providers/git.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s' "ok:provider-ran:${1}"
EOF
	chmod -x "${MCPBASH_HOME}/providers/git.sh" 2>/dev/null || true

	cat >"${MCPBASH_PROVIDERS_DIR}/project.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s' "ok:project-provider-ran:${1}"
EOF
	chmod -x "${MCPBASH_PROVIDERS_DIR}/project.sh" 2>/dev/null || true

	out="$(mcp_resources_read_via_provider "project" "project://test")"
	assert_equal "ok:project-provider-ran:project://test" "${out}"
}
