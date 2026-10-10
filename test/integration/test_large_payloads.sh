#!/usr/bin/env bash
# shellcheck disable=SC2034  # Used by test runner for reporting.
TEST_DESC="Payloads past the argv limits (128 KiB per argument on Linux) arrive whole."
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../common/env.sh
# shellcheck disable=SC1091
. "${SCRIPT_DIR}/../common/env.sh"
# shellcheck source=../common/assert.sh
# shellcheck disable=SC1091
. "${SCRIPT_DIR}/../common/assert.sh"

# Every payload here is bigger than one argument may be on Linux
# (MAX_ARG_STRLEN, 128 KiB). The server must hand such data to jq on stdin or
# from a file; passed as an argument, Linux refuses to start jq and the
# content is lost.

test_require_command jq
test_init_sha256_cmd
test_create_tmpdir

WS="${TEST_TMPDIR}/ws"
test_stage_workspace "${WS}"
rm -f "${WS}/server.d/register.sh"
mkdir -p "${WS}/resources" "${WS}/prompts/big" "${WS}/prompts/echo" "${WS}/tools/embed" "${WS}/tools/icon" "${WS}/data"
FILES="${TEST_TMPDIR}/expected"
mkdir -p "${FILES}"

# Valid UTF-8 text of exactly N bytes and no trailing newline.
make_text() {
	local bytes="$1"
	# The last head closes the pipe early; that SIGPIPE is expected.
	(
		set +o pipefail
		head -c "${bytes}" /dev/urandom | base64 | tr -d '\r\n' | head -c "${bytes}"
	)
}

digest() {
	"${TEST_SHA256_CMD[@]}" | awk '{print $1}'
}

# --- Fixtures ---
# Long server instructions. They once went into the environment of every child
# process, where Linux caps one string at 128 KiB, so nothing could start.
make_text 204800 >"${WS}/server.d/server.instructions.md"

make_text 512000 >"${WS}/resources/big.txt"
head -c 307200 /dev/urandom >"${WS}/resources/big.bin"
# Past macOS's 1 MiB cap on all arguments and environment together.
make_text 1258291 >"${WS}/resources/huge.txt"
cat >"${WS}/resources/big.txt.meta.json" <<EOF
{"name": "big.text", "uri": "file://${WS}/resources/big.txt", "mimeType": "text/plain"}
EOF
cat >"${WS}/resources/huge.txt.meta.json" <<EOF
{"name": "huge.text", "uri": "file://${WS}/resources/huge.txt", "mimeType": "text/plain"}
EOF
cat >"${WS}/resources/big.bin.meta.json" <<EOF
{"name": "big.bin", "uri": "file://${WS}/resources/big.bin", "mimeType": "application/octet-stream"}
EOF

# A 500 KB prompt template with one placeholder.
make_text 512000 >"${FILES}/prompt-body.txt"
{
	printf 'Hello {{name}}! '
	cat "${FILES}/prompt-body.txt"
} >"${WS}/prompts/big/big.txt"
{
	printf 'Hello World! '
	cat "${FILES}/prompt-body.txt"
} >"${FILES}/prompt-expected.txt"
cat >"${WS}/prompts/big/big.meta.json" <<'EOF'
{"name": "big.prompt", "path": "big/big.txt",
 "arguments": {"type": "object", "properties": {"name": {"type": "string"}}}}
EOF

# A small template filled with a 200 KB client argument.
printf '[{{value}}]' >"${WS}/prompts/echo/echo.txt"
cat >"${WS}/prompts/echo/echo.meta.json" <<'EOF'
{"name": "echo.prompt", "path": "echo/echo.txt",
 "arguments": {"type": "object", "properties": {"value": {"type": "string"}}}}
EOF
make_text 204800 >"${FILES}/arg-value.txt"
{
	printf '['
	cat "${FILES}/arg-value.txt"
	printf ']'
} >"${FILES}/echo-expected.txt"

# A completion script that returns 100 suggestions of 2,000 characters each.
cat >"${WS}/prompts/big/big.completion.sh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
item="$(head -c 2000 /dev/zero | tr '\0' 'c')"
printf '['
i=0
while [ "${i}" -lt 100 ]; do
	[ "${i}" -gt 0 ] && printf ','
	printf '"%s"' "${item}"
	i=$((i + 1))
done
printf ']'
SH
chmod +x "${WS}/prompts/big/big.completion.sh"

# A tool that embeds a 300 KB text file in its result.
make_text 307200 >"${WS}/data/embed.txt"
cat >"${WS}/tools/embed/tool.meta.json" <<'EOF'
{"name": "embed-big", "description": "Embeds a large file", "arguments": {"type": "object", "properties": {}}}
EOF
cat >"${WS}/tools/embed/tool.sh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\ttext/plain\t\n' "${MCPBASH_PROJECT_ROOT}/data/embed.txt" >>"${MCP_TOOL_RESOURCES_FILE}"
printf 'ok'
SH
chmod +x "${WS}/tools/embed/tool.sh"

# A tool whose icon becomes a data URI of about 400 KB.
{
	printf '<svg xmlns="http://www.w3.org/2000/svg"><!-- '
	make_text 307200
	printf ' --></svg>'
} >"${WS}/tools/icon/icon.svg"
cat >"${WS}/tools/icon/tool.meta.json" <<'EOF'
{"name": "icon-big", "description": "Has a large icon", "arguments": {"type": "object", "properties": {}},
 "icons": [{"src": "./icon.svg"}]}
EOF
cat >"${WS}/tools/icon/tool.sh" <<'SH'
#!/usr/bin/env bash
printf 'ok'
SH
chmod +x "${WS}/tools/icon/tool.sh"
{
	printf 'data:image/svg+xml;base64,'
	base64 <"${WS}/tools/icon/icon.svg" | tr -d '\r\n'
} >"${FILES}/icon-expected.txt"

chmod -R go-w "${WS}"

{
	printf '%s\n' '{"jsonrpc":"2.0","id":"init","method":"initialize","params":{}}'
	printf '%s\n' '{"jsonrpc":"2.0","method":"notifications/initialized"}'
	printf '{"jsonrpc":"2.0","id":"read-text","method":"resources/read","params":{"uri":"file://%s/resources/big.txt"}}\n' "${WS}"
	printf '{"jsonrpc":"2.0","id":"read-bin","method":"resources/read","params":{"uri":"file://%s/resources/big.bin"}}\n' "${WS}"
	printf '{"jsonrpc":"2.0","id":"read-huge","method":"resources/read","params":{"uri":"file://%s/resources/huge.txt"}}\n' "${WS}"
	printf '%s\n' '{"jsonrpc":"2.0","id":"prompt","method":"prompts/get","params":{"name":"big.prompt","arguments":{"name":"World"}}}'
	printf '{"jsonrpc":"2.0","id":"prompt-arg","method":"prompts/get","params":{"name":"echo.prompt","arguments":{"value":"%s"}}}\n' "$(cat "${FILES}/arg-value.txt")"
	printf '%s\n' '{"jsonrpc":"2.0","id":"complete","method":"completion/complete","params":{"ref":{"type":"ref/prompt","name":"big.prompt"},"argument":{"name":"name","value":""},"limit":100}}'
	printf '%s\n' '{"jsonrpc":"2.0","id":"embed","method":"tools/call","params":{"name":"embed-big","arguments":{}}}'
	printf '%s\n' '{"jsonrpc":"2.0","id":"list","method":"tools/list","params":{}}'
} >"${WS}/requests.ndjson"

test_run_mcp "${WS}" "${WS}/requests.ndjson" "${WS}/responses.ndjson" || true
RESP="${WS}/responses.ndjson"

response_for() {
	local id="$1"
	local line
	line="$(jq -c --arg id "${id}" 'select(.id == $id)' "${RESP}")"
	if [ -z "${line}" ]; then
		test_fail "${id}: no response"
	fi
	if printf '%s' "${line}" | jq -e 'has("error")' >/dev/null; then
		test_fail "${id}: error $(printf '%s' "${line}" | jq -c '.error')"
	fi
	printf '%s' "${line}"
}

# Compare a payload extracted with jq -j against the expected file, by size and hash.
check_payload() {
	local label="$1"
	local id="$2"
	local filter="$3"
	local expected_file="$4"
	local actual_file="${TEST_TMPDIR}/actual.${id}"
	response_for "${id}" | jq -j "${filter}" >"${actual_file}"
	assert_eq "$(wc -c <"${expected_file}" | tr -d ' ')" "$(wc -c <"${actual_file}" | tr -d ' ')" "${label}: length"
	assert_eq "$(digest <"${expected_file}")" "$(digest <"${actual_file}")" "${label}: sha256"
	printf '  ok: %s (%s bytes)\n' "${label}" "$(wc -c <"${actual_file}" | tr -d ' ')"
}

check_payload "200 KB server instructions" "init" '.result.instructions' "${WS}/server.d/server.instructions.md"
check_payload "500 KB text resource" "read-text" '.result.contents[0].text' "${WS}/resources/big.txt"
check_payload "1.2 MB text resource" "read-huge" '.result.contents[0].text' "${WS}/resources/huge.txt"

response_for "read-bin" | jq -j '.result.contents[0].blob' | base64 -d >"${TEST_TMPDIR}/actual.bin" 2>/dev/null \
	|| test_fail "300 KB binary resource: blob is not valid base64"
assert_eq "$(digest <"${WS}/resources/big.bin")" "$(digest <"${TEST_TMPDIR}/actual.bin")" "300 KB binary resource: sha256"
printf '  ok: 300 KB binary resource\n'

check_payload "500 KB prompt" "prompt" '.result.messages[0].content.text' "${FILES}/prompt-expected.txt"
check_payload "200 KB prompt argument" "prompt-arg" '.result.messages[0].content.text' "${FILES}/echo-expected.txt"
check_payload "embedded 300 KB resource" "embed" '.result.content[] | select(.type == "resource") | .resource.text' "${WS}/data/embed.txt"
check_payload "400 KB icon data URI" "list" '.result.tools[] | select(.name == "icon-big") | .icons[0].src' "${FILES}/icon-expected.txt"

completion_shape="$(response_for "complete" | jq -c '.result.completion.values | [length, (map(length) | unique)]')"
assert_eq '[100,[2000]]' "${completion_shape}" "200 KB completion output: values"
printf '  ok: 200 KB completion output\n'

printf 'Large payload test passed\n'
