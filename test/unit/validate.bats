#!/usr/bin/env bash
# Unit tests for validation helpers.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

# shellcheck source=test/common/env.sh
# shellcheck disable=SC1091
. "${REPO_ROOT}/test/common/env.sh"
# shellcheck source=test/common/assert.sh
# shellcheck disable=SC1091
. "${REPO_ROOT}/test/common/assert.sh"
# shellcheck source=lib/validate.sh
# shellcheck disable=SC1090
. "${REPO_ROOT}/lib/validate.sh"

MCPBASH_JSON_TOOL_BIN="$(command -v jq)"
MCPBASH_JSON_TOOL="jq"

test_create_tmpdir

printf ' -> server meta missing yields warning only\n'
MCPBASH_SERVER_DIR="${TEST_TMPDIR}/server.d"
mkdir -p "${MCPBASH_SERVER_DIR}"
read -r err warn <<EOF
$(mcp_validate_server_meta "true" 2>/dev/null | tail -n 1)
EOF
assert_eq "0" "${err}" "expected zero errors for missing server.meta"
assert_eq "1" "${warn}" "expected warning for missing server.meta"

printf ' -> tool chmod fix applies and reports fix count\n'
MCPBASH_TOOLS_DIR="${TEST_TMPDIR}/tools"
mkdir -p "${MCPBASH_TOOLS_DIR}/hello"
cat >"${MCPBASH_TOOLS_DIR}/hello/tool.meta.json" <<'EOF'
{
  "name": "hello",
  "description": "hi",
  "inputSchema": {"type": "object", "properties": {}}
}
EOF
cat >"${MCPBASH_TOOLS_DIR}/hello/tool.sh" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod 644 "${MCPBASH_TOOLS_DIR}/hello/tool.sh"

read -r terr twarn tfix <<EOF
$(mcp_validate_tools "${MCPBASH_TOOLS_DIR}" "true" "true" 2>/dev/null | tail -n 1)
EOF
assert_eq "0" "${terr}" "expected zero errors after --fix"
assert_eq "1" "${twarn}" "expected one warning (namespace recommended)"
assert_eq "1" "${tfix}" "expected one chmod fix applied"
if [ ! -x "${MCPBASH_TOOLS_DIR}/hello/tool.sh" ]; then
	test_fail "tool.sh was not made executable"
fi
