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
