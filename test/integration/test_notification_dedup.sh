#!/usr/bin/env bash
set -euo pipefail

# Source common assertion helpers and env
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../common/env.sh
# shellcheck disable=SC1091
. "${SCRIPT_DIR}/../common/env.sh"
# shellcheck source=../common/assert.sh
# shellcheck disable=SC1091
. "${SCRIPT_DIR}/../common/assert.sh"

test_fast_sequence_notification_count() {
    # The exact repro from the bug report
    # Set up a workspace with at least one tool to ensure registries exist
    local test_dir
    test_dir="$(mktemp -d)"
    mkdir -p "${test_dir}/tools"
    cat > "${test_dir}/tools/test_tool.sh" << 'TOOL'
#!/usr/bin/env bash
# @describe A test tool
echo "ok"
TOOL
    chmod +x "${test_dir}/tools/test_tool.sh"
    
    local output_file="${test_dir}/output.json"
    
    # We use 2>/dev/null to ignore stderr logs
    # Set short/disabled intervals to ensure background workers don't hold stdout open for long
    # Redirect to file instead of pipe to separate process lifecycles
    MCPBASH_RESOURCES_POLL_INTERVAL_SECS=0 \
    MCPBASH_PROGRESS_FLUSH_INTERVAL=0.1 \
    MCPBASH_PROJECT_ROOT="${test_dir}" \
    "${MCPBASH_TEST_ROOT}/bin/mcp-bash" << 'EOF' > "${output_file}" 2>/dev/null
{"jsonrpc":"2.0","id":"init","method":"initialize","params":{}}
{"jsonrpc":"2.0","method":"notifications/initialized"}
{"jsonrpc":"2.0","id":"l1","method":"tools/list"}
{"jsonrpc":"2.0","id":"l2","method":"tools/list"}
EOF
    
    local count
    count=$(grep -c "list_changed" "${output_file}")
    
    rm -rf "${test_dir}"
    
    # With registries present, expect exactly 3 notifications (one triplet)
    # NOT 0 (that would mean notifications are broken)
    # NOT >3 (that would mean spurious notifications)
    assert_eq 3 "${count}" "Fast sequence should produce exactly one triplet of notifications"
}

# Run the test
test_fast_sequence_notification_count
