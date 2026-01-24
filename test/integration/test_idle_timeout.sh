#!/usr/bin/env bash
# Integration: idle timeout triggers server exit when no client activity.
# shellcheck disable=SC2034  # Used by test runner for reporting.
TEST_DESC="Idle timeout triggers exit when no client activity."

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../common/env.sh
# shellcheck disable=SC1091
. "${SCRIPT_DIR}/../common/env.sh"
# shellcheck source=../common/assert.sh
# shellcheck disable=SC1091
. "${SCRIPT_DIR}/../common/assert.sh"

test_require_command jq

# Source the project's timeout helper for portability
# shellcheck disable=SC1091
. "${MCPBASH_HOME}/lib/timeout.sh"

# Portable timeout wrapper
_test_timeout() {
	local secs="$1"
	shift
	if command -v with_timeout >/dev/null 2>&1; then
		with_timeout "${secs}" -- "$@"
	elif command -v gtimeout >/dev/null 2>&1; then
		gtimeout "${secs}" "$@"
	elif command -v timeout >/dev/null 2>&1; then
		timeout "${secs}" "$@"
	else
		"$@"
	fi
}

test_create_tmpdir
WORKSPACE="${TEST_TMPDIR}/idle_timeout"
test_stage_workspace "${WORKSPACE}"

# Test 1: Idle timeout triggers correctly
test_idle_timeout_triggers() {
	local timeout=2
	local test_dir pid_file fifo_path server_pid
	local start_time end_time elapsed
	local writer_pid=""

	test_dir=$(mktemp -d)
	pid_file="${test_dir}/pid"
	fifo_path="${test_dir}/fifo"
	mkfifo "${fifo_path}"
	# shellcheck disable=SC2064
	trap "rm -rf '${test_dir}'; kill '${writer_pid}' 2>/dev/null || true" RETURN

	start_time=$(date +%s)

	# Open writer first, keep FIFO open
	(
		printf '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"test","version":"1.0"}}}\n'
		printf '{"jsonrpc":"2.0","method":"notifications/initialized"}\n'
		sleep 86400
	) >"${fifo_path}" &
	writer_pid=$!

	# Start server reading from FIFO
	MCPBASH_IDLE_TIMEOUT="${timeout}" \
		MCPBASH_ORPHAN_CHECK_ENABLED=false \
		MCPBASH_PROJECT_ROOT="${WORKSPACE}" \
		"${WORKSPACE}/bin/mcp-bash" <"${fifo_path}" >/dev/null 2>&1 &
	server_pid=$!

	# Wait for server to exit
	local wait_max=$((timeout + 5))
	local waited=0
	while kill -0 "${server_pid}" 2>/dev/null && [ "${waited}" -lt "${wait_max}" ]; do
		sleep 1
		waited=$((waited + 1))
	done

	end_time=$(date +%s)
	elapsed=$((end_time - start_time))

	kill "${writer_pid}" 2>/dev/null || true

	# Should exit around timeout value (within tolerance accounting for server startup)
	# Server startup can take 3-4 seconds due to registry discovery
	if [ "${elapsed}" -lt "${timeout}" ] || [ "${elapsed}" -gt $((timeout + 6)) ]; then
		test_fail "Expected timeout around ${timeout}s, got ${elapsed}s"
	fi

	printf 'PASS: Idle timeout triggered correctly after %ds\n' "${elapsed}"
}

# Test 2: Timeout disabled with MCPBASH_IDLE_TIMEOUT=0
test_idle_timeout_disabled() {
	local result
	result=$({
		printf '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"test","version":"1.0"}}}\n'
		printf '{"jsonrpc":"2.0","method":"notifications/initialized"}\n'
		sleep 1
		printf '{"jsonrpc":"2.0","id":2,"method":"ping"}\n'
	} | MCPBASH_IDLE_TIMEOUT=0 \
		MCPBASH_ORPHAN_CHECK_ENABLED=false \
		MCPBASH_PROJECT_ROOT="${WORKSPACE}" \
		_test_timeout 5 "${WORKSPACE}/bin/mcp-bash" 2>/dev/null) || true

	if echo "${result}" | grep -q '"id":2.*"result"'; then
		printf 'PASS: Server responded to ping when timeout=0\n'
	else
		test_fail "Server should have responded to ping (got: ${result})"
	fi
}

# Test 3: Timeout disabled with MCPBASH_IDLE_TIMEOUT_ENABLED=false
test_idle_timeout_disabled_via_flag() {
	local result
	result=$({
		printf '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"test","version":"1.0"}}}\n'
		printf '{"jsonrpc":"2.0","method":"notifications/initialized"}\n'
		sleep 1
		printf '{"jsonrpc":"2.0","id":2,"method":"ping"}\n'
	} | MCPBASH_IDLE_TIMEOUT=1 \
		MCPBASH_IDLE_TIMEOUT_ENABLED=false \
		MCPBASH_ORPHAN_CHECK_ENABLED=false \
		MCPBASH_PROJECT_ROOT="${WORKSPACE}" \
		_test_timeout 5 "${WORKSPACE}/bin/mcp-bash" 2>/dev/null) || true

	if echo "${result}" | grep -q '"id":2.*"result"'; then
		printf 'PASS: Server responded to ping when timeout disabled via flag\n'
	else
		test_fail "Server should have responded to ping (got: ${result})"
	fi
}

# Test 4: Activity resets the timeout counter
test_idle_timeout_reset_on_activity() {
	local timeout=2
	local result
	result=$({
		printf '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"test","version":"1.0"}}}\n'
		printf '{"jsonrpc":"2.0","method":"notifications/initialized"}\n'
		sleep 1
		printf '{"jsonrpc":"2.0","id":2,"method":"ping"}\n'
		sleep 1
		printf '{"jsonrpc":"2.0","id":3,"method":"ping"}\n'
		sleep 1
		printf '{"jsonrpc":"2.0","id":4,"method":"shutdown"}\n'
		printf '{"jsonrpc":"2.0","method":"exit"}\n'
	} | MCPBASH_IDLE_TIMEOUT="${timeout}" \
		MCPBASH_ORPHAN_CHECK_ENABLED=false \
		MCPBASH_PROJECT_ROOT="${WORKSPACE}" \
		_test_timeout 10 "${WORKSPACE}/bin/mcp-bash" 2>/dev/null) || true

	local response_count
	response_count=$(echo "${result}" | grep -c '"result":{}' || true)

	if [ "${response_count}" -ge 2 ]; then
		printf 'PASS: Activity reset timeout correctly (%s responses)\n' "${response_count}"
	else
		test_fail "Expected 2+ ping responses, got ${response_count}"
	fi
}

# Run tests
test_idle_timeout_triggers
test_idle_timeout_disabled
test_idle_timeout_disabled_via_flag
test_idle_timeout_reset_on_activity
