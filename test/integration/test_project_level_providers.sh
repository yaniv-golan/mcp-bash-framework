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
myapi://items/*)
    printf '{"item":"%s"}' "${uri#myapi://items/}"
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

# Templated resource with the custom scheme and no "provider" field: template
# metadata never reaches the static registry, so resources/read must infer the
# provider from the URI scheme.
cat >"${WORKSPACE}/resources/api-item.meta.json" <<'EOF'
{
  "name": "api-item",
  "description": "API item by id",
  "uriTemplate": "myapi://items/{id}",
  "mimeType": "application/json"
}
EOF

# Provider scripts that must never run: their schemes are not declared by any
# resource or template. Each one records that it ran.
MARKER_DIR="${TEST_TMPDIR}/markers"
mkdir -p "${MARKER_DIR}"
for stray in stray git bar; do
	cat >"${WORKSPACE}/providers/${stray}.sh" <<EOF
#!/usr/bin/env bash
: >"${MARKER_DIR}/${stray}"
printf 'ran ${stray}'
EOF
	chmod +x "${WORKSPACE}/providers/${stray}.sh"
done

# A static resource bound to its own scheme declares that scheme (svc://other
# reaches svc.sh). A static resource bound to another provider does not declare
# its scheme (bar://y must not reach bar.sh).
cat >"${WORKSPACE}/providers/svc.sh" <<'EOF'
#!/usr/bin/env bash
printf 'svc got %s' "$1"
EOF
chmod +x "${WORKSPACE}/providers/svc.sh"
echo svc >"${WORKSPACE}/resources/svc-status.txt"
cat >"${WORKSPACE}/resources/svc-status.meta.json" <<'EOF'
{"name": "svc-status", "uri": "svc://status", "provider": "svc"}
EOF
echo bar >"${WORKSPACE}/resources/bar-item.txt"
cat >"${WORKSPACE}/resources/bar-item.meta.json" <<'EOF'
{"name": "bar-item", "uri": "bar://x", "provider": "svc"}
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
{"jsonrpc":"2.0","id":"read-templated","method":"resources/read","params":{"uri":"myapi://items/42"}}
{"jsonrpc":"2.0","id":"read-stray","method":"resources/read","params":{"uri":"stray://x"}}
{"jsonrpc":"2.0","id":"read-git-plain","method":"resources/read","params":{"uri":"git://example.com/repo"}}
{"jsonrpc":"2.0","id":"read-bar","method":"resources/read","params":{"uri":"bar://y"}}
{"jsonrpc":"2.0","id":"read-upper","method":"resources/read","params":{"uri":"MYAPI://items/1"}}
{"jsonrpc":"2.0","id":"read-svc-sibling","method":"resources/read","params":{"uri":"svc://other"}}
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

# Verify a URI expanded from a custom-scheme template routes to the project provider
templated_content="$(jq -r 'select(.id=="read-templated") | .result.contents[0].text // .error.message // empty' "${WORKSPACE}/responses.ndjson")"
test_assert_eq "${templated_content}" '{"item":"42"}'

# Undeclared schemes never reach their provider script
for case_id in read-stray read-git-plain read-bar read-upper; do
	has_error="$(jq -r --arg id "${case_id}" 'select(.id==$id) | has("error")' "${WORKSPACE}/responses.ndjson")"
	test_assert_eq "${has_error}" "true"
done
for stray in stray git bar; do
	if [ -e "${MARKER_DIR}/${stray}" ]; then
		test_fail "undeclared provider ${stray}.sh was executed"
	fi
done

# A static resource bound to its scheme's provider declares the scheme
svc_content="$(jq -r 'select(.id=="read-svc-sibling") | .result.contents[0].text // .error.message // empty' "${WORKSPACE}/responses.ndjson")"
test_assert_eq "${svc_content}" 'svc got svc://other'

printf 'Project-level provider integration test passed.\n'
