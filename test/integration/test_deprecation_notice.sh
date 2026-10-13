#!/usr/bin/env bash
# Integration: once-a-day stderr notice when a project uses APIs that change in 2.0,
# and the instructions note about SDK helpers removed in 2.0.
# shellcheck disable=SC2034  # Used by test runner for reporting.
TEST_DESC="Startup notice for deprecated APIs (stderr, once a day) and the removed-API instructions note."

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
				# WAIT_FILE: also stop once the scan has written this file.
				if [ -n "${WAIT_FILE:-}" ] && [ -f "${WAIT_FILE}" ]; then
					break
				fi
				# WAIT_GONE=FILE:TEXT: also stop once FILE no longer contains TEXT.
				if [ -n "${WAIT_GONE:-}" ] && ! grep -qF "${WAIT_GONE#*:}" "${WAIT_GONE%%:*}" 2>/dev/null; then
					break
				fi
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

# instructions LABEL: the instructions initialize returned in that run.
instructions() {
	jq -r 'select(.id=="init") | .result.instructions // ""' "${TEST_TMPDIR}/$1.out"
}

NOTE_RE='helpers removed in 2\.0'

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

printf ' -> first start: no instructions note yet, findings written\n'
if instructions first | grep -q "${NOTE_RE}"; then
	test_fail "first start: note sent before any scan finished"
fi
test_assert_eq "$(cat "${TEST_TMPDIR}/old/proj/.registry/scan/removed-api.findings")" "tools/hello/tool.sh"
# The scan's files ignore themselves, so projects that commit .registry
# don't see them as untracked.
test_assert_eq "$(cat "${TEST_TMPDIR}/old/proj/.registry/scan/.gitignore")" "*"
for f in removed-api.findings removed-api.scan removed-api.attempt deprecation-notice.stamp; do
	[ ! -e "${TEST_TMPDIR}/old/proj/.registry/${f}" ] || test_fail "scan file outside .registry/scan: ${f}"
done

printf ' -> same day: no second notice, instructions name the file\n'
run old second
test_assert_eq "$(notice_count second)" "0"
if ! instructions second | grep -q "${NOTE_RE}.*tools/hello/tool.sh.*mcp-bash migrate"; then
	test_fail "second start: instructions lack the note: $(instructions second)"
fi

printf ' -> nothing changed: the scan is skipped\n'
F="${TEST_TMPDIR}/old/proj/.registry/scan/removed-api.findings"
[ -f "${TEST_TMPDIR}/old/proj/.registry/scan/removed-api.scan" ] || test_fail "no scan record after a scan"
# A line no scan would write survives a start that skips the scan.
printf '%s\n' tools/fake/tool.sh >>"${F}"
run old skipped
grep -q '^tools/fake/tool.sh$' "${F}" || test_fail "an unchanged project was scanned again: $(cat "${F}")"

printf ' -> a changed file within the hour of the last scan: not scanned yet\n'
sleep 1 # find -newer compares whole seconds on some systems
printf '%s\n' '# edited' >>"${TEST_TMPDIR}/old/proj/tools/hello/tool.sh"
run old too-soon
grep -q '^tools/fake/tool.sh$' "${F}" || test_fail "a scan started again within the hour"

printf ' -> a changed file, an hour later: scanned again\n'
touch -t 202001010000 "${TEST_TMPDIR}/old/proj/.registry/scan/removed-api.attempt"
WAIT_GONE="${F}:tools/fake/tool.sh" run old rescanned
if grep -q '^tools/fake/tool.sh$' "${F}"; then
	test_fail "a changed project was not scanned again"
fi
test_assert_eq "$(cat "${F}")" "tools/hello/tool.sh"

printf ' -> server.instructions.md comes first, then the note\n'
printf '%s\n' 'Project instructions.' >"${TEST_TMPDIR}/old/proj/server.d/server.instructions.md"
run old third
if ! instructions third | head -n 1 | grep -q '^Project instructions\.$'; then
	test_fail "third start: project instructions not first: $(instructions third)"
fi
instructions third | grep -q "${NOTE_RE}" || test_fail "third start: note missing"

printf ' -> after migrate: the next scan clears the note\n'
(cd "${TEST_TMPDIR}/old/proj" && MCPBASH_HOME="${TEST_TMPDIR}/old/fw" bash "${TEST_TMPDIR}/old/fw/bin/mcp-bash" migrate --write >/dev/null 2>&1) || test_fail "migrate --write failed"
rm -f "${TEST_TMPDIR}/old/proj/.registry/scan/removed-api.findings"
WAIT_FILE="${TEST_TMPDIR}/old/proj/.registry/scan/removed-api.findings" run old fourth
test_assert_eq "$(wc -c <"${TEST_TMPDIR}/old/proj/.registry/scan/removed-api.findings" | tr -d ' ')" "0"
run old fifth
if instructions fifth | grep -q "${NOTE_RE}"; then
	test_fail "fifth start: note still sent after migrate"
fi

printf ' -> clean project: no notice\n'
stage clean
run clean clean
test_assert_eq "$(notice_count clean)" "0"

printf ' -> opt-out: no notice, no scan, no note\n'
stage optout deprecated
run optout optout MCPBASH_DEPRECATION_NOTICE=false
test_assert_eq "$(notice_count optout)" "0"
for f in scan/removed-api.findings scan/removed-api.attempt scan/deprecation-notice.stamp; do
	[ ! -e "${TEST_TMPDIR}/optout/proj/.registry/${f}" ] || test_fail "opt-out: the scan ran (${f} written)"
done
# A findings file left from before the opt-out isn't trusted either.
mkdir -p "${TEST_TMPDIR}/optout/proj/.registry/scan"
printf '%s\n' tools/hello/tool.sh >"${TEST_TMPDIR}/optout/proj/.registry/scan/removed-api.findings"
run optout optout2 MCPBASH_DEPRECATION_NOTICE=false
if instructions optout2 | grep -q "${NOTE_RE}"; then
	test_fail "opt-out: note sent"
fi

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
