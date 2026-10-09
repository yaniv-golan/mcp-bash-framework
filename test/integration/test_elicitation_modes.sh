#!/usr/bin/env bash
# shellcheck disable=SC2034  # Used by test runner for reporting.
TEST_DESC="Elicitation mode detection (SEP-1036) for form vs URL modes."
set -euo pipefail

# Named FIFOs and timing assumptions are flaky on Windows Git Bash
case "$(uname -s 2>/dev/null)" in
MINGW* | MSYS* | CYGWIN*)
	printf 'Skipping elicitation modes test on Windows environment\n'
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

# Wait for the server to exit, but never forever: a server that keeps running
# must fail the test, not stall the whole integration run.
wait_bounded() {
	local pid="$1" limit="${2:-60}" waited=0
	while kill -0 "${pid}" 2>/dev/null; do
		if [ "${waited}" -ge "${limit}" ]; then
			kill "${pid}" 2>/dev/null || true
			wait "${pid}" 2>/dev/null || true
			test_fail "server did not exit within ${limit}s after exit request"
		fi
		sleep 1
		waited=$((waited + 1))
	done
	wait "${pid}" 2>/dev/null || true
}

# --- Test 1: Legacy capability format (should imply form mode) ---
test_legacy_format() {
	local workroot="${TEST_TMPDIR}/legacy"
	test_stage_workspace "${workroot}"

	mkdir -p "${workroot}/tools/test"
	cat <<'META' >"${workroot}/tools/test/tool.meta.json"
{"name": "test.elicit", "description": "Test", "arguments": {"type": "object", "properties": {}}}
META
	cat <<'SH' >"${workroot}/tools/test/tool.sh"
#!/usr/bin/env bash
source "${MCP_SDK}/tool-sdk.sh"
mcp_elicit_confirm "Proceed?"
SH
	chmod +x "${workroot}/tools/test/tool.sh"

	local in_fifo="${TEST_TMPDIR}/legacy.in"
	local out_fifo="${TEST_TMPDIR}/legacy.out"
	mkfifo "${in_fifo}" "${out_fifo}"

	(
		cd "${workroot}" || exit 1
		MCPBASH_PROJECT_ROOT="${workroot}" exec ./bin/mcp-bash <"${in_fifo}" >"${out_fifo}"
	) &
	local pid=$!

	exec 3>"${in_fifo}"
	exec 4<"${out_fifo}"

	# Legacy format: {"elicitation": {}} - should work
	printf '%s\n' '{"jsonrpc":"2.0","id":"init","method":"initialize","params":{"capabilities":{"elicitation":{}}}}' >&3
	printf '%s\n' '{"jsonrpc":"2.0","method":"notifications/initialized"}' >&3
	printf '%s\n' '{"jsonrpc":"2.0","id":"call","method":"tools/call","params":{"name":"test.elicit","arguments":{}}}' >&3

	local elicit_seen=0
	local mode_found=""
	local start_ts
	start_ts=$(date +%s)

	while :; do
		local now
		now=$(date +%s)
		if [ $((now - start_ts)) -gt 15 ]; then
			break
		fi

		if ! IFS= read -r -t 1 line <&4; then
			continue
		fi

		if printf '%s' "${line}" | jq -e '.method == "elicitation/create"' >/dev/null 2>&1; then
			elicit_seen=1
			mode_found="$(printf '%s' "${line}" | jq -r '.params.mode // "missing"')"
			local elicit_id
			elicit_id="$(printf '%s' "${line}" | jq -r '.id')"
			printf '{"jsonrpc":"2.0","id":%s,"result":{"action":"accept","content":{"confirmed":true}}}\n' "${elicit_id}" >&3
			break
		fi
	done

	printf '%s\n' '{"jsonrpc":"2.0","id":"exit","method":"exit"}' >&3
	exec 3>&-
	wait_bounded "${pid}"

	if [ "${elicit_seen}" -ne 1 ]; then
		test_fail "legacy format: elicitation/create not seen"
	fi
	if [ "${mode_found}" != "form" ]; then
		test_fail "legacy format: expected mode=form, got ${mode_found}"
	fi

	printf 'Legacy format test passed\n'
}

# --- Test 2: New format with explicit form mode ---
test_new_form_format() {
	local workroot="${TEST_TMPDIR}/newform"
	test_stage_workspace "${workroot}"

	mkdir -p "${workroot}/tools/test"
	cat <<'META' >"${workroot}/tools/test/tool.meta.json"
{"name": "test.elicit", "description": "Test", "arguments": {"type": "object", "properties": {}}}
META
	cat <<'SH' >"${workroot}/tools/test/tool.sh"
#!/usr/bin/env bash
source "${MCP_SDK}/tool-sdk.sh"
mcp_elicit_confirm "Proceed?"
SH
	chmod +x "${workroot}/tools/test/tool.sh"

	local in_fifo="${TEST_TMPDIR}/newform.in"
	local out_fifo="${TEST_TMPDIR}/newform.out"
	mkfifo "${in_fifo}" "${out_fifo}"

	(
		cd "${workroot}" || exit 1
		MCPBASH_PROJECT_ROOT="${workroot}" exec ./bin/mcp-bash <"${in_fifo}" >"${out_fifo}"
	) &
	local pid=$!

	exec 5>"${in_fifo}"
	exec 6<"${out_fifo}"

	# New format with form mode
	printf '%s\n' '{"jsonrpc":"2.0","id":"init","method":"initialize","params":{"capabilities":{"elicitation":{"form":{}}}}}' >&5
	printf '%s\n' '{"jsonrpc":"2.0","method":"notifications/initialized"}' >&5
	printf '%s\n' '{"jsonrpc":"2.0","id":"call","method":"tools/call","params":{"name":"test.elicit","arguments":{}}}' >&5

	local elicit_seen=0
	local mode_found=""
	local start_ts
	start_ts=$(date +%s)

	while :; do
		local now
		now=$(date +%s)
		if [ $((now - start_ts)) -gt 15 ]; then
			break
		fi

		if ! IFS= read -r -t 1 line <&6; then
			continue
		fi

		if printf '%s' "${line}" | jq -e '.method == "elicitation/create"' >/dev/null 2>&1; then
			elicit_seen=1
			mode_found="$(printf '%s' "${line}" | jq -r '.params.mode // "missing"')"
			local elicit_id
			elicit_id="$(printf '%s' "${line}" | jq -r '.id')"
			printf '{"jsonrpc":"2.0","id":%s,"result":{"action":"accept","content":{"confirmed":true}}}\n' "${elicit_id}" >&5
			break
		fi
	done

	printf '%s\n' '{"jsonrpc":"2.0","id":"exit","method":"exit"}' >&5
	exec 5>&-
	wait_bounded "${pid}"

	if [ "${elicit_seen}" -ne 1 ]; then
		test_fail "new form format: elicitation/create not seen"
	fi
	if [ "${mode_found}" != "form" ]; then
		test_fail "new form format: expected mode=form, got ${mode_found}"
	fi

	printf 'New form format test passed\n'
}

# Run tests
test_legacy_format
test_new_form_format

printf 'Elicitation modes (SEP-1036) test passed\n'
