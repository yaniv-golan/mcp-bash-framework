#!/usr/bin/env bash
# shellcheck disable=SC2034  # Used by test runner for reporting.
TEST_DESC="Registry refresh builds cache and respects state."
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"
BIN="${ROOT_DIR}/bin/mcp-bash"

TMP="$(mktemp -d)"
cleanup() {
	rm -rf "${TMP}"
}
trap cleanup EXIT INT TERM

unset MCPBASH_STATE_DIR MCPBASH_LOCK_ROOT MCPBASH_TMP_ROOT
export TMPDIR="${TMP}"
export MCPBASH_PROJECT_ROOT="${TMP}"
mkdir -p "${TMP}/tools" "${TMP}/resources" "${TMP}/prompts"

# Seed a simple tool
mkdir -p "${TMP}/tools/hello"
cat <<'SH' >"${TMP}/tools/hello/tool.sh"
#!/usr/bin/env bash
echo "hello"
SH
chmod +x "${TMP}/tools/hello/tool.sh"

assert_json_value() {
	local json="$1"
	local jq_expr="$2"
	local expected="$3"
	local actual
	actual="$(printf '%s' "${json}" | jq -r "${jq_expr}")"
	if [ "${actual}" != "${expected}" ]; then
		echo "Assertion failed: ${jq_expr} expected ${expected} got ${actual}" >&2
		exit 1
	fi
}

# First refresh should build registries
output="$("${BIN}" registry refresh --project-root "${TMP}" --no-notify)"
assert_json_value "${output}" '.tools.status' 'ok'
assert_json_value "${output}" '.resources.status' 'ok'
assert_json_value "${output}" '.prompts.status' 'ok'

# Second refresh with no changes should skip rebuild (counts stay the same)
output2="$("${BIN}" registry refresh --project-root "${TMP}" --no-notify)"
assert_json_value "${output2}" '.tools.count' '1'

# Add a new tool to force change
mkdir -p "${TMP}/tools/hi"
cat <<'SH' >"${TMP}/tools/hi/tool.sh"
#!/usr/bin/env bash
echo "hi"
SH
chmod +x "${TMP}/tools/hi/tool.sh"

output3="$("${BIN}" registry refresh --project-root "${TMP}" --no-notify)"
assert_json_value "${output3}" '.tools.count' '2'

# Filtered refresh should scope to subpath and still succeed
output4="$("${BIN}" registry refresh --project-root "${TMP}" --no-notify --filter tools)"
assert_json_value "${output4}" '.tools.status' 'ok'
