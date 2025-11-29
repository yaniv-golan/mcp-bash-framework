#!/usr/bin/env bash
# Minimal mode coverage: ensure the fallback JSON parser and reduced capability surface behave.
TEST_DESC="Minimal mode capabilities and logging validation."

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../common/env.sh
# shellcheck disable=SC1091
. "${SCRIPT_DIR}/../common/env.sh"
# shellcheck source=../common/assert.sh
# shellcheck disable=SC1091
. "${SCRIPT_DIR}/../common/assert.sh"

test_create_tmpdir
WORKSPACE="${TEST_TMPDIR}/workspace"
test_stage_workspace "${WORKSPACE}"

cat <<'JSON' >"${WORKSPACE}/requests.ndjson"
{"jsonrpc":"2.0","id":"init","method":"initialize","params":{"protocolVersion":"2025-03-26"}}
{"jsonrpc":"2.0","method":"notifications/initialized"}
{"jsonrpc":"2.0","id":"lvl-invalid","method":"logging/setLevel","params":{"level":"VERBOSE\\u0041","details":{"nested":[1,{"x":"y"}]}}}
{"jsonrpc":"2.0","id":"lvl-valid","method":"logging/setLevel","params":{"level":"DEBUG","meta":{"nested":[{"key":"value"},"x\\\"y"],"depth":{"inner":{"flag":true}}}}}
JSON

(
	cd "${WORKSPACE}" || exit 1
	MCPBASH_PROJECT_ROOT="${WORKSPACE}" \
		MCPBASH_FORCE_MINIMAL=true \
		./bin/mcp-bash <"${WORKSPACE}/requests.ndjson" >"${WORKSPACE}/responses.ndjson"
)

assert_file_exists "${WORKSPACE}/responses.ndjson"
assert_json_lines "${WORKSPACE}/responses.ndjson"

init_protocol="$(
	jq -r 'select(.id=="init") | .result.protocolVersion // empty' "${WORKSPACE}/responses.ndjson"
)"
assert_eq "2025-03-26" "${init_protocol}" "minimal mode should honor requested protocol negotiation"

init_caps="$(
	jq -c 'select(.id=="init") | .result.capabilities // empty' "${WORKSPACE}/responses.ndjson"
)"
assert_eq '{"logging":{}}' "${init_caps}" "minimal mode capabilities should be logging-only"

invalid_code="$(
	jq -r 'select(.id=="lvl-invalid") | .error.code // empty' "${WORKSPACE}/responses.ndjson"
)"
assert_eq "-32602" "${invalid_code}" "invalid log level should be rejected in minimal mode"

invalid_message="$(
	jq -r 'select(.id=="lvl-invalid") | .error.message // empty' "${WORKSPACE}/responses.ndjson"
)"
assert_eq "Invalid log level" "${invalid_message}" "invalid log level response message mismatch"

valid_response="$(
	jq -c 'select(.id=="lvl-valid") | .result // empty' "${WORKSPACE}/responses.ndjson"
)"
assert_eq '{}' "${valid_response}" "valid logging/setLevel should succeed in minimal mode"

test_old_protocol_suppresses_list_changed() {
	# Set up workspace with tools to ensure notifications WOULD fire on newer protocol
	local test_dir
	test_dir="$(mktemp -d)"
	mkdir -p "${test_dir}/tools"
	cat >"${test_dir}/tools/test_tool.sh" <<'TOOL'
#!/usr/bin/env bash
# @describe A test tool
echo "ok"
TOOL
	chmod +x "${test_dir}/tools/test_tool.sh"

	local output_file="${test_dir}/output.json"

	# Run mcp-bash, redirecting stdout to file to avoid pipe hangs
	# We use 2>/dev/null to ignore stderr logs
	# Set short intervals to ensure quick shutdown
	MCPBASH_RESOURCES_POLL_INTERVAL_SECS=0 \
		MCPBASH_PROGRESS_FLUSH_INTERVAL=0.1 \
		MCPBASH_PROJECT_ROOT="${test_dir}" \
		./bin/mcp-bash <<'EOF' >"${output_file}" 2>/dev/null
{"jsonrpc":"2.0","id":"init","method":"initialize","params":{"protocolVersion":"2025-03-26"}}
{"jsonrpc":"2.0","method":"notifications/initialized"}
{"jsonrpc":"2.0","id":"l1","method":"tools/list"}
EOF

	local count
	count=$(grep -c "list_changed" "${output_file}" || true)

	rm -rf "${test_dir}"

	assert_eq 0 "${count}" "Protocol 2025-03-26 should suppress list_changed notifications"
}

test_old_protocol_suppresses_list_changed
