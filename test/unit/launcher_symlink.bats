#!/usr/bin/env bats
# Ensure the launcher resolves symlinks so ~/.local/bin/mcp-bash works.

load '../../node_modules/bats-support/load'
load '../../node_modules/bats-assert/load'
load '../common/fixtures'

setup() {
	PROJECT_ROOT="${BATS_TEST_TMPDIR}/proj"
	mkdir -p "${PROJECT_ROOT}/server.d" "${PROJECT_ROOT}/tools/hello"
	ln -sf "${MCPBASH_HOME}/bin/mcp-bash" "${BATS_TEST_TMPDIR}/mcp-bash"

	cat >"${PROJECT_ROOT}/server.d/server.meta.json" <<'EOF'
{"name":"symlink-launcher-test"}
EOF

	cat >"${PROJECT_ROOT}/tools/hello/tool.meta.json" <<'EOF'
{
  "name": "hello",
  "description": "Hello tool",
  "inputSchema": {"type": "object", "properties": {}}
}
EOF

	cat >"${PROJECT_ROOT}/tools/hello/tool.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
source "${MCP_SDK}/tool-sdk.sh"
mcp_emit_json "$(mcp_json_obj ok true)"
EOF
	chmod +x "${PROJECT_ROOT}/tools/hello/tool.sh"
}

@test "launcher: resolves symlink and finds libs" {
	run "${BATS_TEST_TMPDIR}/mcp-bash" validate --project-root "${PROJECT_ROOT}" --json
	assert_success
}
