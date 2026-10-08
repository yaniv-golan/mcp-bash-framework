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

@test "project_level_providers: provider_from_uri keeps built-in schemes" {
	assert_equal "$(mcp_resources_provider_from_uri "file:///tmp/x")" "file"
	assert_equal "$(mcp_resources_provider_from_uri "git+https://example.com/r.git#main:a")" "git"
	assert_equal "$(mcp_resources_provider_from_uri "https://example.com/x")" "https"
	assert_equal "$(mcp_resources_provider_from_uri "ui://tool/view")" "ui"
}

@test "project_level_providers: provider_from_uri maps custom scheme to matching project provider" {
	printf '#!/usr/bin/env bash\n' >"${MCPBASH_PROVIDERS_DIR}/custom.sh"
	assert_equal "$(mcp_resources_provider_from_uri "custom://items/123")" "custom"
}

@test "project_level_providers: provider_from_uri returns empty for custom scheme without provider" {
	assert_equal "$(mcp_resources_provider_from_uri "custom://items/123")" ""
}

@test "project_level_providers: provider_from_uri ignores framework-only providers for custom schemes" {
	printf '#!/usr/bin/env bash\n' >"${MCPBASH_HOME}/providers/custom.sh"
	assert_equal "$(mcp_resources_provider_from_uri "custom://items/123")" ""
}

@test "project_level_providers: provider_from_uri rejects schemes with path characters" {
	mkdir -p "${MCPBASH_PROJECT_ROOT}/evil"
	printf '#!/usr/bin/env bash\n' >"${MCPBASH_PROJECT_ROOT}/evil/x.sh"
	assert_equal "$(mcp_resources_provider_from_uri "../evil/x://foo")" ""
	assert_equal "$(mcp_resources_provider_from_uri "no-scheme-here")" ""
	assert_equal "$(mcp_resources_provider_from_uri "1bad://foo")" ""
}

@test "project_level_providers: builtin_provider_for_uri matches only the literal built-in patterns" {
	assert_equal "$(mcp_resources_builtin_provider_for_uri "git+https://example.com/r.git")" "git"
	assert_equal "$(mcp_resources_builtin_provider_for_uri "git://example.com/r.git")" ""
	assert_equal "$(mcp_resources_builtin_provider_for_uri "ui:view")" ""
	assert_equal "$(mcp_resources_builtin_provider_for_uri "https:x")" ""
}

_scheme_gate_stubs() {
	MCPBASH_JSON_TOOL_BIN="$(command -v jq)"
	MCP_RESOURCES_REGISTRY_JSON='{"items":[{"name":"s","uri":"svc://status","provider":"svc"},{"name":"b","uri":"bar://x","provider":"svc"}]}'
	mcp_resources_templates_refresh_registry() {
		MCP_RESOURCES_TEMPLATES_REGISTRY_JSON='{"items":[{"name":"t","uriTemplate":"custom://items/{id}"},{"name":"e","uriTemplate":"{scheme}://x"}]}'
	}
}

@test "project_level_providers: scheme_declared accepts template and self-bound static schemes" {
	_scheme_gate_stubs
	run mcp_resources_scheme_declared "custom"
	assert_success
	run mcp_resources_scheme_declared "svc"
	assert_success
}

@test "project_level_providers: scheme_declared rejects undeclared, other-bound and case-variant schemes" {
	_scheme_gate_stubs
	run mcp_resources_scheme_declared "stray"
	assert_failure
	run mcp_resources_scheme_declared "bar"
	assert_failure
	run mcp_resources_scheme_declared "CUSTOM"
	assert_failure
	run mcp_resources_scheme_declared "{scheme}"
	assert_failure
}

@test "project_level_providers: scheme_declared fails closed when templates registry cannot load" {
	_scheme_gate_stubs
	mcp_resources_templates_refresh_registry() {
		MCP_RESOURCES_TEMPLATES_REGISTRY_JSON='{"items":[{"name":"t","uriTemplate":"custom://items/{id}"}]}'
		return 1
	}
	run mcp_resources_scheme_declared "custom"
	assert_failure
}
