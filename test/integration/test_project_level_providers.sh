#!/usr/bin/env bash
# Integration: project-level provider with resources/read
# shellcheck disable=SC2034
TEST_DESC="Project-level providers work with resources/read"

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../common/env.sh
# shellcheck disable=SC1091
. "${SCRIPT_DIR}/../common/env.sh"
# shellcheck source=../common/assert.sh
# shellcheck disable=SC1091
. "${SCRIPT_DIR}/../common/assert.sh"

test_require_command jq

test_create_tmpdir
WORKSPACE="${TEST_TMPDIR}/project-providers"
test_stage_workspace "${WORKSPACE}"

# Create project-level provider
mkdir -p "${WORKSPACE}/providers"
cat >"${WORKSPACE}/providers/myapi.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
uri="${1:-}"
case "${uri}" in
myapi://status)
    printf '{"status":"ok","version":"1.0"}'
    ;;
myapi://*)
    printf 'Unknown resource\n' >&2
    exit 3
    ;;
*)
    printf 'Invalid URI scheme\n' >&2
    exit 4
    ;;
esac
EOF
chmod +x "${WORKSPACE}/providers/myapi.sh"

# Create placeholder resource file (required for auto-discovery)
mkdir -p "${WORKSPACE}/resources"
cat >"${WORKSPACE}/resources/api-status.txt" <<'EOF'
Placeholder for myapi provider
EOF

# Create resource metadata pointing to custom provider
cat >"${WORKSPACE}/resources/api-status.meta.json" <<'EOF'
{
  "name": "api-status",
  "description": "API status endpoint",
  "uri": "myapi://status",
  "mimeType": "application/json",
  "provider": "myapi"
}
EOF

# Create server.d/server.meta.json
mkdir -p "${WORKSPACE}/server.d"
cat >"${WORKSPACE}/server.d/server.meta.json" <<'EOF'
{
  "name": "test-project-providers",
  "version": "1.0.0"
}
EOF

# Create test requests
cat <<'JSON' >"${WORKSPACE}/requests.ndjson"
{"jsonrpc":"2.0","id":"init","method":"initialize","params":{}}
{"jsonrpc":"2.0","method":"notifications/initialized"}
{"jsonrpc":"2.0","id":"list","method":"resources/list","params":{}}
{"jsonrpc":"2.0","id":"read","method":"resources/read","params":{"uri":"myapi://status"}}
{"jsonrpc":"2.0","id":"shutdown","method":"shutdown"}
{"jsonrpc":"2.0","id":"exit","method":"exit"}
JSON

status=0
test_run_mcp "${WORKSPACE}" "${WORKSPACE}/requests.ndjson" "${WORKSPACE}/responses.ndjson" || status=$?
if [ "${status}" -ne 0 ]; then
	# On Windows/Git Bash, shutdown/watchdog termination and process exit codes can
	# be unreliable. Prefer validating captured responses over trusting the exit code.
	case "$(uname -s 2>/dev/null)" in
	MINGW* | MSYS* | CYGWIN*) : ;;
	*) exit "${status}" ;;
	esac
fi
assert_json_lines "${WORKSPACE}/responses.ndjson"

# Verify resource was listed
# test_assert_eq: actual, expected, message (backwards compat wrapper)
list_result="$(jq -r 'select(.id=="list") | .result.resources[0].name // empty' "${WORKSPACE}/responses.ndjson")"
test_assert_eq "${list_result}" "api-status"

# Verify resource was read successfully
read_content="$(jq -r 'select(.id=="read") | .result.contents[0].text // empty' "${WORKSPACE}/responses.ndjson")"
test_assert_eq "${read_content}" '{"status":"ok","version":"1.0"}'

printf 'Project-level provider integration test passed.\n'
