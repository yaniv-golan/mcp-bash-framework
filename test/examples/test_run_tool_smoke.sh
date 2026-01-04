#!/usr/bin/env bash
# Smoke test: exercise one example tool via run-tool (dry-run + real execution).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../common/env.sh
# shellcheck disable=SC1091
. "${SCRIPT_DIR}/../common/env.sh"
# shellcheck source=../common/assert.sh
# shellcheck disable=SC1091
. "${SCRIPT_DIR}/../common/assert.sh"
# shellcheck source=../common/fixtures.sh
# shellcheck disable=SC1091
. "${SCRIPT_DIR}/../common/fixtures.sh"

test_require_command jq

# Stage the simplest example
test_stage_example "00-hello-tool"
WORKDIR="${MCP_TEST_WORKDIR}"

printf ' -> dry-run on example-hello\n'
(cd "${WORKDIR}" && ./bin/mcp-bash run-tool example-hello --dry-run >/dev/null)

printf ' -> execute example-hello with roots\n'
root_path="${WORKDIR}/roots-one"
mkdir -p "${root_path}"
output="$(cd "${WORKDIR}" && ./bin/mcp-bash run-tool example-hello --args '{"name":"World"}' --roots "${root_path}")"
result_line="$(printf '%s\n' "${output}" | tail -n1)"
message="$(printf '%s\n' "${result_line}" | jq -r '.structuredContent.result.message // .structuredContent.message // empty')"
assert_eq "Hello from example tool" "${message}" "run-tool example-hello message mismatch"

printf 'Example run-tool smoke passed.\n'
