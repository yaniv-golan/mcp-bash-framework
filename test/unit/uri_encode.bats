#!/usr/bin/env bats
# Unit layer: mcp_uri_url_encode byte encoding across bash versions.

load '../../node_modules/bats-support/load'
load '../../node_modules/bats-assert/load'
load '../common/fixtures'

encode_with() {
	local shell_bin="$1" value="$2"
	"${shell_bin}" -c '. "$1/lib/uri.sh"; mcp_uri_url_encode "$2"' _ "${MCPBASH_HOME}" "${value}"
}

@test "uri_encode: ASCII and reserved characters" {
	run encode_with bash "file:///tmp/a b/c~d_e-f.g?h#i"
	assert_output "file:///tmp/a%20b/c~d_e-f.g%3Fh%23i"
}

@test "uri_encode: non-ASCII bytes are encoded as two hex digits (current bash)" {
	run encode_with bash "file:///tmp/é/日"
	assert_output "file:///tmp/%C3%A9/%E6%97%A5"
}

@test "uri_encode: non-ASCII bytes are encoded as two hex digits (/bin/bash, 3.2 on macOS)" {
	[ -x /bin/bash ] || skip "/bin/bash not available"
	run encode_with /bin/bash "file:///tmp/é/日"
	assert_output "file:///tmp/%C3%A9/%E6%97%A5"
}
