#!/usr/bin/env bash
# shellcheck disable=SC2034  # Used by test runner for reporting.
TEST_DESC="Elicitation confirm flow for tools/call."
set -euo pipefail

# Named FIFOs and timing assumptions are flaky on Windows Git Bash;
# skip this test there and rely on Unix CI for coverage.
case "$(uname -s 2>/dev/null)" in
MINGW* | MSYS* | CYGWIN*)
	printf 'Skipping elicitation test on Windows environment\n'
	exit 0
	;;
esac

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../common/env.sh
# shellcheck disable=SC1091
. "${SCRIPT_DIR}/../common/env.sh"
# shellcheck source=../common/assert.sh
# shellcheck disable=SC1091
. "${SCRIPT_DIR}/../common/assert.sh"

test_create_tmpdir

WORKROOT="${TEST_TMPDIR}/elicitation"
test_stage_workspace "${WORKROOT}"

# Create elicitation test tool
mkdir -p "${WORKROOT}/tools/elicitation"
cat <<'META' >"${WORKROOT}/tools/elicitation/tool.meta.json"
{
  "name": "elicitation.test",
  "description": "Asks for confirmation via elicitation",
  "arguments": {"type": "object", "properties": {}}
}
META

cat <<'SH' >"${WORKROOT}/tools/elicitation/tool.sh"
#!/usr/bin/env bash
set -euo pipefail
source "${MCP_SDK}/tool-sdk.sh"

resp="$(mcp_elicit_confirm "Proceed?")"
action="$(printf '%s' "${resp}" | jq -r '.action')"

if [ "${action}" = "accept" ]; then
	confirmed="$(printf '%s' "${resp}" | jq -r '.content.confirmed')"
	if [ "${confirmed}" = "true" ]; then
		mcp_emit_text "confirmed"
		exit 0
	fi
fi

mcp_emit_text "not-confirmed:${action}"
exit 0
SH
chmod +x "${WORKROOT}/tools/elicitation/tool.sh"

IN_FIFO="${TEST_TMPDIR}/elicitation.in"
OUT_FIFO="${TEST_TMPDIR}/elicitation.out"
mkfifo "${IN_FIFO}" "${OUT_FIFO}"

(
	cd "${WORKROOT}" || exit 1
	# Use the SDK default elicitation timeout (30s). Some environments
	# (notably Windows CI) can take longer to spin up background workers,
	# so forcing a very short MCPBASH_ELICITATION_TIMEOUT risks the tool
	# timing out before the server has a chance to emit elicitation/create.
	MCPBASH_PROJECT_ROOT="${WORKROOT}" ./bin/mcp-bash <"${IN_FIFO}" >"${OUT_FIFO}"
) &
SERVER_PID=$!

# Open the FIFOs after server starts listening
exec 3>"${IN_FIFO}"
exec 4<"${OUT_FIFO}"

# Send initialize + tool call
printf '%s\n' '{"jsonrpc":"2.0","id":"init","method":"initialize","params":{"capabilities":{"elicitation":{}}}}' >&3
printf '%s\n' '{"jsonrpc":"2.0","method":"notifications/initialized"}' >&3
printf '%s\n' '{"jsonrpc":"2.0","id":"call","method":"tools/call","params":{"name":"elicitation.test","arguments":{}}}' >&3

call_response=""
elicitation_seen=0
start_ts=$(date +%s)

while :; do
	now=$(date +%s)
	if [ $((now - start_ts)) -gt 30 ]; then
		test_fail "timed out waiting for elicitation flow"
		break
	fi

	if ! IFS= read -r -t 1 line <&4; then
		continue
	fi

	if printf '%s' "${line}" | jq -e '.method == "elicitation/create"' >/dev/null 2>&1; then
		elicitation_seen=1
		elicit_id="$(printf '%s' "${line}" | jq -r '.id')"
		printf '{"jsonrpc":"2.0","id":%s,"result":{"action":"accept","content":{"confirmed":true}}}\n' "${elicit_id}" >&3
		continue
	fi

	if printf '%s' "${line}" | jq -e '.id == "call"' >/dev/null 2>&1; then
		call_response="${line}"
		break
	fi
done

# Request clean shutdown
printf '%s\n' '{"jsonrpc":"2.0","id":"shutdown","method":"shutdown"}' >&3
printf '%s\n' '{"jsonrpc":"2.0","id":"exit","method":"exit"}' >&3
exec 3>&-
wait "${SERVER_PID}" || true

if [ "${elicitation_seen}" -ne 1 ]; then
	test_fail "elicitation/create request not observed"
fi

if [ -z "${call_response}" ]; then
	test_fail "no tools/call response received"
fi

text="$(printf '%s' "${call_response}" | jq -r '.result.content[] | select(.type=="text") | .text' | head -n1)"
if [[ "${text}" != *"confirmed"* ]]; then
	test_fail "tool output missing confirmation text (got: ${text})"
fi

printf 'elicitation happy-path passed\n'
