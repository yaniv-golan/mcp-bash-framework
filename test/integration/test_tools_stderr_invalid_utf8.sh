#!/usr/bin/env bash
# shellcheck disable=SC2034  # Used by test runner for reporting.
TEST_DESC="A tool's stderr with bytes that aren't valid UTF-8 reaches the client whole."
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

# In a UTF-8 locale, BSD tr (macOS) stops at the first byte that isn't valid
# UTF-8, so the stderr tail and the error message were cut there and the
# server logged "tr: Illegal byte sequence". GNU tr works on bytes, so on Linux
# this test passes either way; the macOS jobs are the ones that catch it.
utf8_locale=""
# Read the list first: `locale -a | grep -q` gets SIGPIPE under pipefail.
locales="$(locale -a 2>/dev/null || true)"
for candidate in en_US.UTF-8 C.UTF-8 C.utf8 en_US.utf8; do
	if printf '%s\n' "${locales}" | grep -x "${candidate}" >/dev/null; then
		utf8_locale="${candidate}"
		break
	fi
done
if [ -z "${utf8_locale}" ]; then
	printf 'SKIP: no UTF-8 locale available\n'
	exit 0
fi

WS="${TEST_TMPDIR}/ws"
test_stage_workspace "${WS}"
mkdir -p "${WS}/server.d" "${WS}/tools/noisy" "${WS}/tools/broken"
printf '%s\n' '{"name": "stderr-utf8"}' >"${WS}/server.d/server.meta.json"

cat >"${WS}/tools/noisy/tool.meta.json" <<'EOF'
{"name":"noisy","description":"succeeds, with bad bytes on stderr","inputSchema":{"type":"object","properties":{}}}
EOF
cat >"${WS}/tools/noisy/tool.sh" <<'EOF'
#!/usr/bin/env bash
printf 'before \377\376 after\n' >&2
printf 'done\n'
EOF
cat >"${WS}/tools/broken/tool.meta.json" <<'EOF'
{"name":"broken","description":"fails, with bad bytes on stderr","inputSchema":{"type":"object","properties":{}}}
EOF
cat >"${WS}/tools/broken/tool.sh" <<'EOF'
#!/usr/bin/env bash
printf 'failed \377\376 because\n' >&2
exit 3
EOF
chmod +x "${WS}/tools/noisy/tool.sh" "${WS}/tools/broken/tool.sh"

cat >"${TEST_TMPDIR}/requests.ndjson" <<'JSON'
{"jsonrpc":"2.0","id":"init","method":"initialize","params":{}}
{"jsonrpc":"2.0","method":"notifications/initialized"}
{"jsonrpc":"2.0","id":"noisy","method":"tools/call","params":{"name":"noisy","arguments":{}}}
{"jsonrpc":"2.0","id":"broken","method":"tools/call","params":{"name":"broken","arguments":{}}}
JSON

out="${TEST_TMPDIR}/responses.ndjson"
LC_ALL="${utf8_locale}" MCPBASH_TOOL_ALLOWLIST='noisy broken' test_run_mcp "${WS}" "${TEST_TMPDIR}/requests.ndjson" "${out}"
assert_json_lines "${out}"

noisy_stderr="$(jq -r 'select(.id=="noisy") | .result._meta.stderr // empty' "${out}")"
case "${noisy_stderr}" in
*after*) ;;
*) test_fail "successful tool: _meta.stderr cut at the bad bytes: $(jq -c 'select(.id=="noisy")' "${out}")" ;;
esac

broken="$(jq -c 'select(.id=="broken")' "${out}")"
case "${broken}" in
*because*) ;;
*) test_fail "failing tool: error text cut at the bad bytes: ${broken}" ;;
esac

if grep -q 'Illegal byte sequence' "${out}.stderr"; then
	test_fail "server stderr reports a tr failure: $(grep 'Illegal byte sequence' "${out}.stderr" | head -1)"
fi

printf 'Invalid UTF-8 stderr test passed (%s).\n' "${utf8_locale}"
