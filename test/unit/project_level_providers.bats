#!/usr/bin/env bats
# Unit: project-level provider discovery and precedence

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
	export MCPBASH_RESOURCES_DIR="${MCPBASH_PROJECT_ROOT}/resources"

	mkdir -p "${MCPBASH_HOME}/providers"
	mkdir -p "${MCPBASH_PROVIDERS_DIR}"
	mkdir -p "${MCPBASH_RESOURCES_DIR}"
}

@test "project_level_providers: project provider takes precedence over framework provider" {
	cat >"${MCPBASH_HOME}/providers/test.sh" <<'EOF'
#!/usr/bin/env bash
printf 'framework-provider'
EOF
	chmod +x "${MCPBASH_HOME}/providers/test.sh"

	cat >"${MCPBASH_PROVIDERS_DIR}/test.sh" <<'EOF'
#!/usr/bin/env bash
printf 'project-provider'
EOF
	chmod +x "${MCPBASH_PROVIDERS_DIR}/test.sh"

	out="$(mcp_resources_read_via_provider "test" "test://anything")"
	assert_equal "project-provider" "${out}"
}

@test "project_level_providers: falls back to framework provider when project provider absent" {
	cat >"${MCPBASH_HOME}/providers/test.sh" <<'EOF'
#!/usr/bin/env bash
printf 'framework-provider'
EOF
	chmod +x "${MCPBASH_HOME}/providers/test.sh"

	out="$(mcp_resources_read_via_provider "test" "test://anything")"
	assert_equal "framework-provider" "${out}"
}

@test "project_level_providers: works when providers/ directory does not exist" {
	cat >"${MCPBASH_HOME}/providers/test.sh" <<'EOF'
#!/usr/bin/env bash
printf 'framework-provider'
EOF
	chmod +x "${MCPBASH_HOME}/providers/test.sh"

	rmdir "${MCPBASH_PROVIDERS_DIR}" 2>/dev/null || rm -rf "${MCPBASH_PROVIDERS_DIR}"

	out="$(mcp_resources_read_via_provider "test" "test://anything")"
	assert_equal "framework-provider" "${out}"
}

@test "project_level_providers: custom URI scheme works with project provider" {
	mkdir -p "${MCPBASH_PROVIDERS_DIR}"
	cat >"${MCPBASH_PROVIDERS_DIR}/custom.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
uri="${1:-}"
case "${uri}" in
custom://hello)
    printf '{"message":"hello from custom provider"}'
    ;;
*)
    printf 'Unknown URI: %s\n' "${uri}" >&2
    exit 3
    ;;
esac
EOF
	chmod +x "${MCPBASH_PROVIDERS_DIR}/custom.sh"

	out="$(mcp_resources_read_via_provider "custom" "custom://hello")"
	assert_equal '{"message":"hello from custom provider"}' "${out}"
}

@test "project_level_providers: returns error when provider not found anywhere" {
	rm -f "${MCPBASH_PROVIDERS_DIR}/custom.sh" 2>/dev/null || true
	rm -f "${MCPBASH_HOME}/providers/nonexistent.sh" 2>/dev/null || true

	run mcp_resources_read_via_provider "nonexistent" "nonexistent://test"
	assert_failure
}
