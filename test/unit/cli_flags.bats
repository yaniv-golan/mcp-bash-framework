#!/usr/bin/env bash
# Unit tests for new CLI flags: validate/config/registry/doctor.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

# shellcheck source=test/common/env.sh
# shellcheck disable=SC1091
. "${REPO_ROOT}/test/common/env.sh"
# shellcheck source=test/common/assert.sh
# shellcheck disable=SC1091
. "${REPO_ROOT}/test/common/assert.sh"

test_require_command jq

test_create_tmpdir
PROJECT_ROOT="${TEST_TMPDIR}/proj"
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
source "${MCP_SDK}/tool-sdk.sh"
mcp_emit_json "$(mcp_json_obj ok true)"
EOF
chmod +x "${PROJECT_ROOT}/tools/hello/tool.sh"

printf ' -> validate --json produces machine output and strict fails on warnings\n'
if "${REPO_ROOT}/bin/mcp-bash" validate --project-root "${PROJECT_ROOT}" --json --strict >"${TEST_TMPDIR}/validate.json" 2>/dev/null; then
	test_fail "validate --strict should fail with warnings"
fi
validate_warnings="$(jq -r '.warnings' "${TEST_TMPDIR}/validate.json")"
assert_eq "1" "${validate_warnings}" "expected one warning for missing namespace"
validate_strict="$(jq -r '.strict' "${TEST_TMPDIR}/validate.json")"
assert_eq "true" "${validate_strict}" "strict flag should reflect true"

printf ' -> validate --explain-defaults emits defaults in text mode\n'
defaults_output="$("${REPO_ROOT}/bin/mcp-bash" validate --project-root "${PROJECT_ROOT}" --explain-defaults 2>/dev/null)"
assert_contains "Defaults used: name=cli-flags-test" "${defaults_output}"

printf ' -> config --wrapper outputs to stdout when non-TTY\n'
rm -f "${PROJECT_ROOT}/cli-flags-test.sh"
wrapper_output="$("${REPO_ROOT}/bin/mcp-bash" config --project-root "${PROJECT_ROOT}" --wrapper)"
assert_contains "#!/usr/bin/env bash" "${wrapper_output}"
assert_contains "MCPBASH_PROJECT_ROOT" "${wrapper_output}"
assert_contains "framework not found" "${wrapper_output}"
assert_contains "git clone https://github.com/yaniv-golan/mcp-bash-framework.git" "${wrapper_output}"
if [[ -f "${PROJECT_ROOT}/cli-flags-test.sh" ]]; then
	test_fail "Wrapper file should not be created in non-TTY context"
fi

printf ' -> config --wrapper rejects invalid server names but still emits script to stdout\n'
bad_project="${TEST_TMPDIR}/badproj"
mkdir -p "${bad_project}/server.d"
printf '{"name":"has spaces"}' >"${bad_project}/server.d/server.meta.json"
bad_output="$("${REPO_ROOT}/bin/mcp-bash" config --project-root "${bad_project}" --wrapper 2>&1)"
assert_contains "#!/usr/bin/env bash" "${bad_output}"
assert_contains "invalid characters" "${bad_output}"
if [[ -e "${bad_project}/has spaces.sh" ]]; then
	test_fail "Wrapper file should not be created for invalid server name"
fi

printf ' -> config --wrapper creates file when stdout is a TTY (script)\n'
	if ! command -v script >/dev/null 2>&1; then
		printf '    SKIP (script command not available)\n'
	else
		# Some platforms ship a script(1) variant with differing arg order; probe before asserting.
		if ! script -q /dev/null /bin/sh -c "echo probe" </dev/null >/dev/null 2>&1; then
			printf '    SKIP (script command incompatible on this platform)\n'
		else
			rm -f "${PROJECT_ROOT}/cli-flags-test.sh"
			script_exit=0
			cmd_str="\"${REPO_ROOT}/bin/mcp-bash\" config --project-root \"${PROJECT_ROOT}\" --wrapper"
			script -q /dev/null /bin/sh -c "${cmd_str}" </dev/null || script_exit=$?
			if [ "${script_exit}" -ne 0 ]; then
				test_fail "config --wrapper exited with code ${script_exit}"
			fi
			if [[ ! -f "${PROJECT_ROOT}/cli-flags-test.sh" ]]; then
				test_fail "Wrapper file not created in TTY mode"
			fi
			if [[ ! -x "${PROJECT_ROOT}/cli-flags-test.sh" ]]; then
				test_fail "Wrapper file not executable"
			fi
			rm -f "${PROJECT_ROOT}/cli-flags-test.sh"
		fi
	fi

	printf ' -> config --client outputs pasteable JSON\n'
"${REPO_ROOT}/bin/mcp-bash" config --project-root "${PROJECT_ROOT}" --client claude-desktop >"${TEST_TMPDIR}/client.json"
jq -e '.mcpServers["cli-flags-test"].command' "${TEST_TMPDIR}/client.json" >/dev/null

printf ' -> registry status outputs JSON even without cache\n'
"${REPO_ROOT}/bin/mcp-bash" registry status --project-root "${PROJECT_ROOT}" >"${TEST_TMPDIR}/reg.json"
jq -e '.tools.status' "${TEST_TMPDIR}/reg.json" >/dev/null

printf ' -> doctor --json outputs structured data\n'
(cd "${PROJECT_ROOT}" && "${REPO_ROOT}/bin/mcp-bash" doctor --json >"${TEST_TMPDIR}/doctor.json")
jq -e '.framework.version' "${TEST_TMPDIR}/doctor.json" >/dev/null

printf 'CLI flags tests passed.\n'
