#!/usr/bin/env bash
# Integration: once-a-day stderr notice when a project uses APIs that change in 2.0.
# shellcheck disable=SC2034  # Used by test runner for reporting.
TEST_DESC="Startup notice for deprecated APIs: stderr only, once a day, with opt-outs."

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
# Stage by copying: the cached staging tarball can predate files this test
# depends on (lib/migrate_rules.sh).
MCPBASH_STAGING_TAR=0

NOTICE_RE='APIs that change in mcp-bash 2\.0'

cat <<'JSON' >"${TEST_TMPDIR}/requests.ndjson"
{"jsonrpc":"2.0","id":"init","method":"initialize","params":{}}
{"jsonrpc":"2.0","method":"notifications/initialized"}
{"jsonrpc":"2.0","id":"ping","method":"ping"}
JSON

# stage NAME [deprecated]: a framework copy (NAME/fw) and a separate project
# (NAME/proj) with one tool, old-style when asked. Keeping them apart matches
# real installs, where the framework's own files aren't part of the project.
stage() {
	local base="${TEST_TMPDIR}/$1"
	test_stage_workspace "${base}/fw"
	local proj="${base}/proj"
	mkdir -p "${proj}/tools/hello" "${proj}/server.d"
	printf '%s\n' '{"name":"notice-test"}' >"${proj}/server.d/server.meta.json"
	printf '%s\n' '{"name":"hello","description":"d","inputSchema":{"type":"object"}}' >"${proj}/tools/hello/tool.meta.json"
	if [ "${2:-}" = "deprecated" ]; then
		# shellcheck disable=SC2016  # Literal tool source.
		printf '%s\n' '#!/usr/bin/env bash' 'source "${MCP_SDK}/tool-sdk.sh"' 'mcp_result_success "$(mcp_json_obj message hi)"' >"${proj}/tools/hello/tool.sh"
	else
		# shellcheck disable=SC2016  # Literal tool source.
		printf '%s\n' '#!/usr/bin/env bash' 'source "${MCP_SDK}/tool-sdk.sh"' 'mcp_result_text "hi"' >"${proj}/tools/hello/tool.sh"
	fi
	chmod +x "${proj}/tools/hello/tool.sh"
}

# run NAME LABEL [VAR=VALUE...]: run the server once. The notice comes from a
# background scan that stops when the server exits, so keep the server's
# input open until the notice appears or 5s pass. The server is started with
# `bash` rather than through its `env bash` shebang.
run() {
	local base="${TEST_TMPDIR}/$1" label="$2"
	shift 2
	local out="${TEST_TMPDIR}/${label}.out" err="${TEST_TMPDIR}/${label}.err"
	: >"${err}"
	(
		cd "${base}/proj" || exit 1
		unset MCPBASH_DEPRECATION_NOTICE MCPBASH_STATIC_REGISTRY
		local assignment
		for assignment in "$@"; do
			export "${assignment?}"
		done
		export MCPBASH_PROJECT_ROOT="${base}/proj"
		export MCPBASH_HOME="${base}/fw"
		# Reading stderr while the server writes it is intended: keep its input
		# open until the notice appears.
		# shellcheck disable=SC2094
		{
			cat "${TEST_TMPDIR}/requests.ndjson"
			local i=0
			while [ "${i}" -lt 50 ] && ! grep -q "${NOTICE_RE}" "${err}" 2>/dev/null; do
				sleep 0.1
				i=$((i + 1))
			done
		} | bash "${base}/fw/bin/mcp-bash" >"${out}" 2>"${err}"
	)
	# stdout must stay valid protocol: every line is JSON, and ping was answered.
	assert_json_lines "${out}"
	jq -e 'select(.id=="ping") | .result == {}' "${out}" >/dev/null || test_fail "${label}: ping not answered"
	if grep -q 'APIs that change' "${out}"; then
		test_fail "${label}: notice written to stdout"
	fi
}

notice_count() {
	grep -c "${NOTICE_RE}" "${TEST_TMPDIR}/$1.err" 2>/dev/null || true
}

printf ' -> deprecated project: notice once on stderr\n'
stage old deprecated
run old first
test_assert_eq "$(notice_count first)" "1"
if ! grep -q '^mcp-bash: 1 use of APIs that change in mcp-bash 2.0' "${TEST_TMPDIR}/first.err"; then
	test_fail "unexpected notice text: $(cat "${TEST_TMPDIR}/first.err")"
fi

printf ' -> same day: no second notice\n'
run old second
test_assert_eq "$(notice_count second)" "0"

printf ' -> clean project: no notice\n'
stage clean
run clean clean
test_assert_eq "$(notice_count clean)" "0"

printf ' -> opt-out: no notice\n'
stage optout deprecated
run optout optout MCPBASH_DEPRECATION_NOTICE=false
test_assert_eq "$(notice_count optout)" "0"

printf ' -> static registry (bundles): no notice\n'
stage static deprecated
run static static MCPBASH_STATIC_REGISTRY=1
test_assert_eq "$(notice_count static)" "0"

printf ' -> rule engine missing (vendored runtime): no notice\n'
stage vendored deprecated
rm -f "${TEST_TMPDIR}/vendored/fw/lib/migrate_rules.sh"
run vendored vendored
test_assert_eq "$(notice_count vendored)" "0"

printf 'Deprecation notice test passed.\n'
