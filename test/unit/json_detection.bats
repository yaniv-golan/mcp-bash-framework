#!/usr/bin/env bats
# Unit tests for JSON tool detection ordering, overrides, and exec checks.

load '../../node_modules/bats-support/load'
load '../../node_modules/bats-assert/load'
load '../common/fixtures'

setup() {
	# shellcheck source=lib/runtime.sh
	# shellcheck disable=SC1091
	. "${MCPBASH_HOME}/lib/runtime.sh"

	unset -f jq 2>/dev/null || true

	ORIG_PATH="${PATH}"

	# Create stub binaries
	BIN_JQ_GOJQ="${BATS_TEST_TMPDIR}/bin-jq-gojq"
	mkdir -p "${BIN_JQ_GOJQ}"
	stub_bin "${BIN_JQ_GOJQ}" jq
	stub_bin "${BIN_JQ_GOJQ}" gojq

	BIN_GOJQ_ONLY="${BATS_TEST_TMPDIR}/bin-gojq"
	mkdir -p "${BIN_GOJQ_ONLY}"
	stub_bin "${BIN_GOJQ_ONLY}" jq fail
	stub_bin "${BIN_GOJQ_ONLY}" gojq

	BIN_JQ_ONLY="${BATS_TEST_TMPDIR}/bin-jq"
	mkdir -p "${BIN_JQ_ONLY}"
	stub_bin "${BIN_JQ_ONLY}" jq

	BIN_CUSTOM="${BATS_TEST_TMPDIR}/bin-custom"
	mkdir -p "${BIN_CUSTOM}"
	stub_bin "${BIN_CUSTOM}" myjson
}

teardown() {
	PATH="${ORIG_PATH}"
}

stub_bin() {
	local dir="$1"
	local name="$2"
	local behavior="${3:-ok}"
	cat >"${dir}/${name}" <<'EOF'
#!/usr/bin/env bash
case "$1" in
--version)
EOF
	if [ "${behavior}" = "hang" ]; then
		cat >>"${dir}/${name}" <<'EOF'
	sleep 2
	exit 1
EOF
	elif [ "${behavior}" = "fail" ]; then
		cat >>"${dir}/${name}" <<'EOF'
	exit 1
EOF
	else
		cat >>"${dir}/${name}" <<'EOF'
	exit 0
EOF
	fi
	cat >>"${dir}/${name}" <<'EOF'
		;;
*)
	exit 0
		;;
esac
EOF
	chmod +x "${dir}/${name}"
}

reset_detection_state() {
	MCPBASH_MODE=""
	MCPBASH_JSON_TOOL=""
	MCPBASH_JSON_TOOL_BIN=""
	MCPBASH_FORCE_MINIMAL=false
	MCPBASH_LOG_JSON_TOOL="quiet"
}

@test "json_detection: jq preferred over gojq when both present" {
	reset_detection_state
	PATH="${BIN_JQ_GOJQ}:/usr/bin:/bin"
	hash -r
	mcp_runtime_detect_json_tool
	assert_equal "jq" "${MCPBASH_JSON_TOOL}"
	assert_equal "${BIN_JQ_GOJQ}/jq" "${MCPBASH_JSON_TOOL_BIN}"
}

@test "json_detection: gojq used when jq absent" {
	reset_detection_state
	PATH="${BIN_GOJQ_ONLY}:/usr/bin:/bin"
	hash -r
	mcp_runtime_detect_json_tool
	assert_equal "gojq" "${MCPBASH_JSON_TOOL}"
	assert_equal "${BIN_GOJQ_ONLY}/gojq" "${MCPBASH_JSON_TOOL_BIN}"
}

@test "json_detection: explicit override succeeds when binary is valid" {
	reset_detection_state
	PATH="${BIN_JQ_GOJQ}:/usr/bin:/bin"
	hash -r
	MCPBASH_JSON_TOOL="gojq"
	MCPBASH_JSON_TOOL_BIN="${BIN_JQ_GOJQ}/gojq"
	mcp_runtime_detect_json_tool
	assert_equal "gojq" "${MCPBASH_JSON_TOOL}"
	assert_equal "${BIN_JQ_GOJQ}/gojq" "${MCPBASH_JSON_TOOL_BIN}"
}

@test "json_detection: override missing binary falls back to jq" {
	reset_detection_state
	PATH="${BIN_JQ_ONLY}:/usr/bin:/bin"
	hash -r
	MCPBASH_JSON_TOOL="gojq"
	MCPBASH_JSON_TOOL_BIN=""
	mcp_runtime_detect_json_tool
	assert_equal "jq" "${MCPBASH_JSON_TOOL}"
	assert_equal "${BIN_JQ_ONLY}/jq" "${MCPBASH_JSON_TOOL_BIN}"
}

@test "json_detection: override none enters minimal mode" {
	reset_detection_state
	PATH="${BIN_JQ_GOJQ}:/usr/bin:/bin"
	hash -r
	MCPBASH_JSON_TOOL="none"
	mcp_runtime_detect_json_tool
	assert_equal "minimal" "${MCPBASH_MODE}"
	assert_equal "none" "${MCPBASH_JSON_TOOL}"
}

@test "json_detection: directory override falls back to jq" {
	reset_detection_state
	PATH="${BIN_JQ_ONLY}:/usr/bin:/bin"
	hash -r
	MCPBASH_JSON_TOOL="gojq"
	MCPBASH_JSON_TOOL_BIN="${BATS_TEST_TMPDIR}"
	mcp_runtime_detect_json_tool
	assert_equal "jq" "${MCPBASH_JSON_TOOL}"
	assert_equal "${BIN_JQ_ONLY}/jq" "${MCPBASH_JSON_TOOL_BIN}"
}

@test "json_detection: custom binary basename treated as jq-compatible" {
	reset_detection_state
	PATH="${BIN_JQ_ONLY}:/usr/bin:/bin"
	hash -r
	unset MCPBASH_JSON_TOOL
	MCPBASH_JSON_TOOL_BIN="${BIN_CUSTOM}/myjson"
	mcp_runtime_detect_json_tool
	assert_equal "jq" "${MCPBASH_JSON_TOOL}"
	assert_equal "${BIN_CUSTOM}/myjson" "${MCPBASH_JSON_TOOL_BIN}"
}
