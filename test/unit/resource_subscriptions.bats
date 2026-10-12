#!/usr/bin/env bats
# Unit layer: resource subscription records and the poller.
#
# mcp_resources_read and rpc_send_line_direct are stubbed, so each test controls
# what a poll reads and records every notification it would send.

load '../../node_modules/bats-support/load'
load '../../node_modules/bats-assert/load'
load '../common/fixtures'

setup() {
	# shellcheck source=lib/hash.sh
	# shellcheck disable=SC1091
	. "${MCPBASH_HOME}/lib/hash.sh"
	# shellcheck source=lib/lock.sh
	# shellcheck disable=SC1091
	. "${MCPBASH_HOME}/lib/lock.sh"
	# shellcheck source=lib/registry.sh
	# shellcheck disable=SC1091
	. "${MCPBASH_HOME}/lib/registry.sh"
	# shellcheck source=lib/resources.sh
	# shellcheck disable=SC1091
	. "${MCPBASH_HOME}/lib/resources.sh"

	MCPBASH_JSON_TOOL_BIN="${TEST_JSON_TOOL_BIN:-$(command -v jq)}"
	MCPBASH_JSON_TOOL="jq"
	MCPBASH_STATE_DIR="${BATS_TEST_TMPDIR}/state"
	MCPBASH_LOCK_ROOT="${BATS_TEST_TMPDIR}/locks"
	mkdir -p "${MCPBASH_STATE_DIR}" "${MCPBASH_LOCK_ROOT}"
	SENT="${BATS_TEST_TMPDIR}/sent.ndjson"
	READS="${BATS_TEST_TMPDIR}/reads"
	: >"${SENT}"
	: >"${READS}"

	mcp_runtime_is_minimal_mode() { return 1; }
	mcp_logging_is_enabled() { return 1; }
	mcp_logging_debug() { return 0; }
	mcp_logging_warning() { return 0; }
	mcp_logging_info() { return 0; }
	mcp_logging_error() { return 0; }
	rpc_send_line_direct() { printf '%s\n' "$1" >>"${SENT}"; }
}

record_path() {
	printf '%s/resource_subscription.%s' "${MCPBASH_STATE_DIR}" "$1"
}

# Stub read: log the arguments (NUL-free, newline-escaped) and return new content.
stub_read_ok() {
	mcp_resources_read() {
		local n="${1//$'\n'/\\n}" u="${2//$'\n'/\\n}"
		printf '%s|%s\n' "${n}" "${u}" >>"${READS}"
		_MCP_RESOURCES_RESULT="{\"contents\":[{\"uri\":\"${2}\",\"text\":\"new\"}]}"
		return 0
	}
}

@test "subscriptions: newline in name or uri does not shift record fields" {
	stub_read_ok
	mcp_resources_subscription_store "sub-nl" $'bogus\nfile:///other.txt' "file:///live.txt" "fp-old"

	run mcp_resources_poll_subscriptions
	assert_success

	run cat "${READS}"
	assert_output 'bogus\nfile:///other.txt|file:///live.txt'
	run jq -r '.params.uri' "${SENT}"
	assert_output "file:///live.txt"
}

@test "subscriptions: a record removed during a successful read is not recreated" {
	mcp_resources_subscription_store "sub-a" "" "file:///a.txt" "fp-old"
	mcp_resources_read() {
		# The client unsubscribes while the provider is still reading.
		rm -f "$(record_path sub-a)"
		_MCP_RESOURCES_RESULT='{"contents":[{"uri":"file:///a.txt","text":"new"}]}'
		return 0
	}

	run mcp_resources_poll_subscriptions
	assert_success

	assert [ ! -e "$(record_path sub-a)" ]
	run cat "${SENT}"
	assert_output ""
}

@test "subscriptions: a record removed during a failing read is not recreated" {
	mcp_resources_subscription_store "sub-a" "" "file:///a.txt" "fp-old"
	mcp_resources_read() {
		rm -f "$(record_path sub-a)"
		_MCP_RESOURCES_ERROR_CODE=-32002
		_MCP_RESOURCES_ERROR_MESSAGE="gone"
		return 1
	}

	run mcp_resources_poll_subscriptions
	assert_success

	assert [ ! -e "$(record_path sub-a)" ]
	run cat "${SENT}"
	assert_output ""
}

@test "subscriptions: poller survives unreadable records under set -e" {
	stub_read_ok
	mcp_resources_subscription_store "sub-ok" "" "file:///ok.txt" "fp-old"
	# Not a record this version wrote, and an empty one: both are skipped.
	printf 'name\nfile:///legacy.txt\nfp\n' >"$(record_path sub-legacy)"
	: >"$(record_path sub-empty)"
	# A stray temp file from an interrupted write is not a subscription.
	printf '{"name":"","uri":"file:///tmp.txt","fingerprint":"x"}\n' >"$(record_path sub-ok).tmp"

	poll_strict() (
		set -euo pipefail
		mcp_resources_poll_subscriptions
		echo survived
	)
	run poll_strict
	assert_success
	assert_line "survived"

	run cat "${READS}"
	assert_output '|file:///ok.txt'
	run jq -r '.params.uri' "${SENT}"
	assert_output "file:///ok.txt"
	assert [ ! -e "$(record_path tmp)" ]
}

@test "subscriptions: an update is never sent with an empty uri" {
	mcp_resources_subscription_store "sub-a" "file.live" "" "fp-old"
	mcp_resources_read() {
		_MCP_RESOURCES_RESULT='{"contents":[{"text":"new"}]}'
		return 0
	}

	run mcp_resources_poll_subscriptions
	assert_success

	run cat "${SENT}"
	assert_output ""
}

# Dispatch-order markers: the main shell notes subscribes and unsubscribes in
# request order, before their workers run in parallel.
load_dispatch_helpers() {
	# shellcheck source=lib/ids.sh
	# shellcheck disable=SC1091
	. "${MCPBASH_HOME}/lib/ids.sh"
	# shellcheck source=lib/json.sh
	# shellcheck disable=SC1091
	. "${MCPBASH_HOME}/lib/json.sh"
	mcp_runtime_is_minimal_mode() { return 1; }
}

@test "subscriptions: an unsubscribe dispatched after a pending subscribe removes its later record" {
	load_dispatch_helpers
	mcp_resources_subscription_note_dispatch resources/subscribe \
		'{"jsonrpc":"2.0","id":"s1","method":"resources/subscribe","params":{"uri":"file:///a.txt"}}' '"s1"'
	mcp_resources_subscription_note_dispatch resources/unsubscribe \
		'{"jsonrpc":"2.0","id":"u1","method":"resources/unsubscribe","params":{"uri":"file:///a.txt"}}' '"u1"'
	# The subscribe worker stores its record only now, after the unsubscribe.
	mcp_resources_subscription_store "sub-a" "" "file:///a.txt" "fp" "file:///a.txt"

	run mcp_resources_subscription_settle_pending "$(mcp_ids_key_from_json '"s1"')" "sub-a"
	assert_success
	assert [ ! -e "$(record_path sub-a)" ]
	run ls "${MCPBASH_STATE_DIR}"
	assert_output ""
}

@test "subscriptions: an unsubscribe for another uri or dispatched earlier leaves a subscribe alone" {
	load_dispatch_helpers
	mcp_resources_subscription_note_dispatch resources/unsubscribe \
		'{"jsonrpc":"2.0","id":"u0","method":"resources/unsubscribe","params":{"uri":"file:///a.txt"}}' '"u0"'
	mcp_resources_subscription_note_dispatch resources/subscribe \
		'{"jsonrpc":"2.0","id":"s1","method":"resources/subscribe","params":{"uri":"file:///a.txt"}}' '"s1"'
	mcp_resources_subscription_note_dispatch resources/unsubscribe \
		'{"jsonrpc":"2.0","id":"u1","method":"resources/unsubscribe","params":{"uri":"file:///b.txt"}}' '"u1"'
	mcp_resources_subscription_store "sub-a" "" "file:///a.txt" "fp" "file:///a.txt"

	run mcp_resources_subscription_settle_pending "$(mcp_ids_key_from_json '"s1"')" "sub-a"
	assert_failure
	assert [ -f "$(record_path sub-a)" ]
	run ls "${MCPBASH_STATE_DIR}"
	assert_output "resource_subscription.sub-a"
}

@test "subscriptions: an unsubscribe leaves alone a subscribe dispatched after it" {
	load_dispatch_helpers
	# subscribe, unsubscribe, subscribe again, all for one uri. Each worker
	# runs with the dispatch sequence number the main shell had when it forked.
	mcp_resources_subscription_note_dispatch resources/subscribe \
		'{"jsonrpc":"2.0","id":"s1","method":"resources/subscribe","params":{"uri":"file:///a.txt"}}' '"s1"'
	local s1_seq="${MCPBASH_SUBSCRIPTION_DISPATCH_SEQ:-}"
	mcp_resources_subscription_store "sub-a" "" "file:///a.txt" "fp" "file:///a.txt" create "${s1_seq}"
	mcp_resources_subscription_settle_pending "$(mcp_ids_key_from_json '"s1"')" "sub-a" || true
	mcp_resources_subscription_note_dispatch resources/unsubscribe \
		'{"jsonrpc":"2.0","id":"u1","method":"resources/unsubscribe","params":{"uri":"file:///a.txt"}}' '"u1"'
	local u1_seq="${MCPBASH_SUBSCRIPTION_DISPATCH_SEQ:-}"
	mcp_resources_subscription_note_dispatch resources/subscribe \
		'{"jsonrpc":"2.0","id":"s2","method":"resources/subscribe","params":{"uri":"file:///a.txt"}}' '"s2"'
	local s2_seq="${MCPBASH_SUBSCRIPTION_DISPATCH_SEQ:-}"
	# The second subscribe's worker stores its record before the unsubscribe
	# worker gets to run.
	mcp_resources_subscription_store "sub-b" "" "file:///a.txt" "fp" "file:///a.txt" create "${s2_seq}"
	run mcp_resources_subscription_settle_pending "$(mcp_ids_key_from_json '"s2"')" "sub-b"
	assert_failure

	run mcp_resources_subscription_remove_by_uri "file:///a.txt" "${u1_seq}"
	assert_output "1"
	assert [ ! -e "$(record_path sub-a)" ]
	assert [ -f "$(record_path sub-b)" ]
}

@test "subscriptions: the poller keeps a record's dispatch sequence number" {
	stub_read_ok
	mcp_resources_subscription_store "sub-a" "" "file:///a.txt" "old" "file:///a.txt" create 7
	mcp_resources_poll_subscriptions
	run "${MCPBASH_JSON_TOOL_BIN}" -r '.seq' "$(record_path sub-a)"
	assert_output "7"
	# An unsubscribe dispatched before it leaves it; one dispatched after removes it.
	run mcp_resources_subscription_remove_by_uri "file:///a.txt" 6
	assert_output "0"
	run mcp_resources_subscription_remove_by_uri "file:///a.txt" 8
	assert_output "1"
}

# A poll whose read logs from inside a $(...) capture, as the real read does
# when it refreshes a registry. Logging follows mcp_logging_emit: queue when a
# queue is active, otherwise write to the current stdout.
setup_logging_read() {
	# shellcheck source=lib/io.sh
	# shellcheck disable=SC1091
	. "${MCPBASH_HOME}/lib/io.sh"
	MCP_NOTIFICATION_QUEUE_FILE=""
	unset MCPBASH_DIRECT_FD
	CAPTURED="${BATS_TEST_TMPDIR}/captured"
	FLUSHED="${BATS_TEST_TMPDIR}/flushed"
	: >"${CAPTURED}"
	: >"${FLUSHED}"
	mcp_logging_warning() {
		local n='{"jsonrpc":"2.0","method":"notifications/message","params":{"level":"warning","data":"w"}}'
		if mcp_notification_queue_active; then
			mcp_notification_queue_append "${n}"
		else
			printf '%s\n' "${n}"
		fi
	}
	mcp_io_send_line() { printf '%s\n' "$1" >>"${FLUSHED}"; }
	mcp_resources_read() {
		local metadata
		metadata="$(
			mcp_logging_warning "mcp.resources" "w"
			printf 'meta'
		)"
		printf '%s\n' "${metadata}" >>"${CAPTURED}"
		_MCP_RESOURCES_RESULT="{\"contents\":[{\"uri\":\"${2}\",\"text\":\"new\"}]}"
		return 0
	}
}

@test "subscriptions: the poller's poll queues warnings logged inside a read's capture" {
	setup_logging_read
	mcp_resources_subscription_store "sub-q" "live" "file:///live.txt" "fp-old"
	mcp_resources_poll_subscriptions_queued
	assert_equal "$(cat "${CAPTURED}")" "meta"
	run grep -c '"notifications/message"' "${FLUSHED}"
	assert_output "1"
	[ -z "${MCP_NOTIFICATION_QUEUE_FILE}" ] || fail "queue left active"
}

@test "subscriptions: without the queue, a warning lands in the read's capture" {
	setup_logging_read
	mcp_resources_subscription_store "sub-raw" "live" "file:///live.txt" "fp-old"
	mcp_resources_poll_subscriptions
	run grep -c 'notifications/message' "${CAPTURED}"
	assert_output "1"
}
