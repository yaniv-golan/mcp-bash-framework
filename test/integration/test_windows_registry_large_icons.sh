#!/usr/bin/env bash
# shellcheck disable=SC2034  # Used by test runner for reporting.
TEST_DESC="Windows/Git Bash: registry builds survive large icon payloads (E2BIG mitigation)."
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../common/env.sh
# shellcheck disable=SC1091
. "${SCRIPT_DIR}/../common/env.sh"
# shellcheck source=../common/assert.sh
# shellcheck disable=SC1091
. "${SCRIPT_DIR}/../common/assert.sh"

case "$(uname -s 2>/dev/null || printf '')" in
MINGW* | MSYS* | CYGWIN*) : ;;
*)
	# This test targets MSYS/Git Bash argv limits.
	exit 0
	;;
esac

test_create_tmpdir
WORKSPACE="${TEST_TMPDIR}/registry-large-icons"
test_stage_workspace "${WORKSPACE}"

# Remove register.sh to force auto-discovery.
rm -f "${WORKSPACE}/server.d/register.sh"

mkdir -p "${WORKSPACE}/tools/large-icon"

# Create a large local icon payload to exceed Windows argv limits.
icon_path="${WORKSPACE}/tools/large-icon/icon.svg"
printf '<svg xmlns="http://www.w3.org/2000/svg">' >"${icon_path}"
if command -v head >/dev/null 2>&1; then
	head -c 262144 /dev/zero | tr '\0' 'A' >>"${icon_path}"
elif command -v dd >/dev/null 2>&1; then
	dd if=/dev/zero bs=1024 count=256 2>/dev/null | tr '\0' 'A' >>"${icon_path}"
else
	chunk="$(printf 'A%.0s' {1..1024})"
	i=0
	while [ "${i}" -lt 256 ]; do
		printf '%s' "${chunk}" >>"${icon_path}"
		i=$((i + 1))
	done
fi
printf '</svg>' >>"${icon_path}"

cat <<'META' >"${WORKSPACE}/tools/large-icon/tool.meta.json"
{
  "name": "large-icon-tool",
  "description": "Tool with a large icon payload",
  "arguments": {"type": "object", "properties": {}},
  "icons": [
    {"src": "./icon.svg"}
  ]
}
META

cat <<'SH' >"${WORKSPACE}/tools/large-icon/tool.sh"
#!/usr/bin/env bash
printf '{"result":"ok"}'
SH
chmod +x "${WORKSPACE}/tools/large-icon/tool.sh"

cat <<'JSON' >"${WORKSPACE}/requests.ndjson"
{"jsonrpc":"2.0","id":"init","method":"initialize","params":{}}
{"jsonrpc":"2.0","method":"notifications/initialized"}
{"jsonrpc":"2.0","id":"tools-list","method":"tools/list","params":{}}
JSON

test_run_mcp "${WORKSPACE}" "${WORKSPACE}/requests.ndjson" "${WORKSPACE}/responses.ndjson"

tools_resp="$(grep '"id":"tools-list"' "${WORKSPACE}/responses.ndjson" | head -n1)"
if [ -z "${tools_resp}" ]; then
	test_fail "missing tools/list response"
fi
if printf '%s' "${tools_resp}" | jq -e '.error' >/dev/null 2>&1; then
	test_fail "tools/list failed with large icon payload"
fi

icon_len="$(printf '%s' "${tools_resp}" | jq -r '.result.tools[] | select(.name=="large-icon-tool") | .icons[0].src | length' | head -n1)"
case "${icon_len}" in
'' | *[!0-9]*)
	test_fail "expected large-icon-tool icons in tools/list response"
	;;
esac
if [ "${icon_len}" -lt 200000 ]; then
	test_fail "expected large data URI (length >= 200000), got ${icon_len}"
fi

printf 'Large icon registry test passed\n'
