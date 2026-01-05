#!/usr/bin/env bats
# Unit tests for new CLI flags: validate/config/registry/doctor.

load '../../node_modules/bats-support/load'
load '../../node_modules/bats-assert/load'
load '../common/fixtures'
load '../common/ndjson'

setup() {
	unset -f jq 2>/dev/null || true
	command -v jq >/dev/null 2>&1 || skip "jq required"

	PROJECT_ROOT="${BATS_TEST_TMPDIR}/proj"
	mkdir -p "${PROJECT_ROOT}/server.d" "${PROJECT_ROOT}/tools/hello"
	export MCPBASH_PROJECT_ROOT="${PROJECT_ROOT}"

	cat >"${PROJECT_ROOT}/server.d/server.meta.json" <<'EOF'
{"name":"cli-flags-test"}
EOF

	cat >"${PROJECT_ROOT}/tools/hello/tool.meta.json" <<'EOF'
{
  "name": "hello",
  "description": "Hello tool",
  "inputSchema": {"type": "object", "properties": {}}
}
EOF

	cat >"${PROJECT_ROOT}/tools/hello/tool.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' '{"ok":true}'
EOF
	chmod +x "${PROJECT_ROOT}/tools/hello/tool.sh"
}

@test "cli_flags: validate --json produces machine output and strict fails on warnings" {
	run "${MCPBASH_HOME}/bin/mcp-bash" validate --project-root "${PROJECT_ROOT}" --json --strict
	assert_failure
	printf '%s\n' "${output}" >"${BATS_TEST_TMPDIR}/validate.json"
	validate_warnings="$(jq -r '.warnings' "${BATS_TEST_TMPDIR}/validate.json")"
	assert_equal "1" "${validate_warnings}"
	validate_strict="$(jq -r '.strict' "${BATS_TEST_TMPDIR}/validate.json")"
	assert_equal "true" "${validate_strict}"
}

@test "cli_flags: validate --explain-defaults emits defaults in text mode" {
	defaults_output="$("${MCPBASH_HOME}/bin/mcp-bash" validate --project-root "${PROJECT_ROOT}" --explain-defaults 2>/dev/null)"
	assert_contains "Defaults used: name=cli-flags-test" "${defaults_output}"
}

@test "cli_flags: config --wrapper outputs to stdout when non-TTY" {
	rm -f "${PROJECT_ROOT}/cli-flags-test.sh"
	wrapper_output="$("${MCPBASH_HOME}/bin/mcp-bash" config --project-root "${PROJECT_ROOT}" --wrapper)"
	assert_contains "#!/usr/bin/env bash" "${wrapper_output}"
	assert_contains "MCPBASH_PROJECT_ROOT" "${wrapper_output}"
	assert_contains "mcp-bash not found" "${wrapper_output}"
	assert_contains "see README for download" "${wrapper_output}"
	[ ! -f "${PROJECT_ROOT}/cli-flags-test.sh" ]
}

@test "cli_flags: config --wrapper-env emits profile-aware wrapper" {
	wrapper_env_output="$("${MCPBASH_HOME}/bin/mcp-bash" config --project-root "${PROJECT_ROOT}" --wrapper-env)"
	assert_contains "_source_profile" "${wrapper_env_output}"
	assert_contains '_source_profile "${HOME}/.zshrc"' "${wrapper_env_output}"
	assert_contains "see README for download" "${wrapper_env_output}"
}

@test "cli_flags: config --wrapper rejects invalid server names but still emits script to stdout" {
	bad_project="${BATS_TEST_TMPDIR}/badproj"
	mkdir -p "${bad_project}/server.d"
	printf '{"name":"has spaces"}' >"${bad_project}/server.d/server.meta.json"
	bad_output="$("${MCPBASH_HOME}/bin/mcp-bash" config --project-root "${bad_project}" --wrapper 2>&1)"
	assert_contains "#!/usr/bin/env bash" "${bad_output}"
	assert_contains "invalid characters" "${bad_output}"
	[ ! -e "${bad_project}/has spaces.sh" ]
}

@test "cli_flags: config --wrapper creates file when stdout is a TTY (script)" {
	command -v script >/dev/null 2>&1 || skip "script command not available"

	# Some platforms ship a script(1) variant with differing arg order; probe before asserting.
	if ! script -q /dev/null /bin/sh -c "echo probe" </dev/null >/dev/null 2>&1; then
		skip "script command incompatible on this platform"
	fi

	rm -f "${PROJECT_ROOT}/cli-flags-test.sh"
	cmd_str="\"${MCPBASH_HOME}/bin/mcp-bash\" config --project-root \"${PROJECT_ROOT}\" --wrapper"
	run script -q /dev/null /bin/sh -c "${cmd_str}"
	assert_success
	[ -f "${PROJECT_ROOT}/cli-flags-test.sh" ]
	[ -x "${PROJECT_ROOT}/cli-flags-test.sh" ]
	rm -f "${PROJECT_ROOT}/cli-flags-test.sh"
}

@test "cli_flags: config --client outputs pasteable JSON" {
	"${MCPBASH_HOME}/bin/mcp-bash" config --project-root "${PROJECT_ROOT}" --client claude-desktop >"${BATS_TEST_TMPDIR}/client.json"
	jq -e '.mcpServers["cli-flags-test"].command' "${BATS_TEST_TMPDIR}/client.json" >/dev/null
}

@test "cli_flags: registry status outputs JSON even without cache" {
	"${MCPBASH_HOME}/bin/mcp-bash" registry status --project-root "${PROJECT_ROOT}" >"${BATS_TEST_TMPDIR}/reg.json"
	jq -e '.tools.status' "${BATS_TEST_TMPDIR}/reg.json" >/dev/null
}

@test "cli_flags: doctor --json outputs structured data" {
	(cd "${PROJECT_ROOT}" && "${MCPBASH_HOME}/bin/mcp-bash" doctor --json >"${BATS_TEST_TMPDIR}/doctor.json")
	jq -e '.schemaVersion == 1' "${BATS_TEST_TMPDIR}/doctor.json" >/dev/null
	jq -e '.exitCode == 0' "${BATS_TEST_TMPDIR}/doctor.json" >/dev/null
	jq -e '.findings | type == "array"' "${BATS_TEST_TMPDIR}/doctor.json" >/dev/null
	jq -e '.framework.version' "${BATS_TEST_TMPDIR}/doctor.json" >/dev/null
}
