#!/usr/bin/env bats
# Unit: HTTPS provider resolves the host once, refuses private answers, fails
# closed when resolution fails, and pins curl to the vetted addresses.
#
# No network: curl and every resolver the policy library may consult (getent,
# dscacheutil, dig, host, nslookup) are fakes on PATH.

load '../../node_modules/bats-support/load'
load '../../node_modules/bats-assert/load'
load '../common/fixtures'

setup() {
	PROVIDER="${MCPBASH_HOME}/providers/https.sh"
	BIN_DIR="${BATS_TEST_TMPDIR}/bin"
	mkdir -p "${BIN_DIR}"
	CURL_CALLS="${BATS_TEST_TMPDIR}/curl.calls"
	RESOLVER_CALLS="${BATS_TEST_TMPDIR}/resolver.calls"
	: >"${CURL_CALLS}"
	: >"${RESOLVER_CALLS}"
	export CURL_CALLS RESOLVER_CALLS

	# Fake curl: record argv, write a body to -o, print a 200 for -w.
	cat >"${BIN_DIR}/curl" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"${CURL_CALLS:?}"
out=""
prev=""
for a in "$@"; do
	[ "${prev}" = "-o" ] && out="${a}"
	prev="${a}"
done
[ -n "${out}" ] && printf 'body\n' >"${out}"
printf '200'
exit 0
EOF
	chmod 700 "${BIN_DIR}/curl"

	# Default: every resolver knows nothing.
	stub_resolvers "" ""
	stderr_file="${BATS_TEST_TMPDIR}/stderr.txt"
	: >"${stderr_file}"
}

# stub_resolvers <getent-ahosts-output> <dscacheutil-output>
stub_resolvers() {
	local getent_out="$1" dscache_out="$2"
	printf '%s' "${getent_out}" >"${BATS_TEST_TMPDIR}/getent.out"
	printf '%s' "${dscache_out}" >"${BATS_TEST_TMPDIR}/dscacheutil.out"
	local name
	for name in getent dscacheutil; do
		cat >"${BIN_DIR}/${name}" <<EOF
#!/usr/bin/env bash
printf '%s %s\n' "${name}" "\$*" >>"\${RESOLVER_CALLS:?}"
if [ -s "${BATS_TEST_TMPDIR}/${name}.out" ]; then
	cat "${BATS_TEST_TMPDIR}/${name}.out"
	exit 0
fi
[ "${name}" = "getent" ] && exit 2
exit 0
EOF
		chmod 700 "${BIN_DIR}/${name}"
	done
	for name in dig host nslookup; do
		cat >"${BIN_DIR}/${name}" <<EOF
#!/usr/bin/env bash
printf '%s %s\n' "${name}" "\$*" >>"\${RESOLVER_CALLS:?}"
exit 1
EOF
		chmod 700 "${BIN_DIR}/${name}"
	done
}

run_provider() {
	local uri="$1"
	run env PATH="${BIN_DIR}:${PATH}" \
		MCPBASH_HOME="${MCPBASH_HOME}" \
		MCPBASH_HTTPS_ALLOW_ALL="${ALLOW_ALL:-true}" \
		MCPBASH_HTTPS_ALLOW_HOSTS="${ALLOW_HOSTS:-}" \
		CURL_CALLS="${CURL_CALLS}" RESOLVER_CALLS="${RESOLVER_CALLS}" \
		bash "${PROVIDER}" "${uri}"
}

@test "https_resolution: refuses and never calls curl when resolution fails" {
	run_provider "https://unresolvable.example/file"
	assert_equal "${status}" "5"
	assert_output --partial "unable to resolve"
	[ ! -s "${CURL_CALLS}" ] || fail "curl was called: $(cat "${CURL_CALLS}")"
}

@test "https_resolution: pins curl to the address the resolver returned" {
	stub_resolvers "93.184.216.34   STREAM example.com
93.184.216.34   DGRAM
93.184.216.34   RAW
" ""
	run_provider "https://example.com/file"
	assert_success
	assert_output "body"
	run cat "${CURL_CALLS}"
	assert_output --partial "--resolve example.com:443:93.184.216.34"
	assert_equal "$(wc -l <"${CURL_CALLS}" | tr -d ' ')" "1"
}

@test "https_resolution: pins IPv6 answers in brackets and honours the URL port" {
	stub_resolvers "2606:4700::1111 STREAM example.com
" ""
	run_provider "https://example.com:8443/file"
	assert_success
	run cat "${CURL_CALLS}"
	assert_output --partial "--resolve example.com:8443:[2606:4700::1111]"
}

@test "https_resolution: adds the wildcard pin only when no proxy is configured" {
	stub_resolvers "93.184.216.34 STREAM example.com
" ""
	run_provider "https://example.com/file"
	assert_success
	run cat "${CURL_CALLS}"
	assert_output --partial "--resolve *:443:93.184.216.34"

	: >"${CURL_CALLS}"
	run env PATH="${BIN_DIR}:${PATH}" MCPBASH_HOME="${MCPBASH_HOME}" \
		MCPBASH_HTTPS_ALLOW_ALL=true https_proxy="http://proxy.invalid:443" \
		CURL_CALLS="${CURL_CALLS}" RESOLVER_CALLS="${RESOLVER_CALLS}" \
		bash "${PROVIDER}" "https://example.com/file"
	assert_success
	run cat "${CURL_CALLS}"
	assert_output --partial "--resolve example.com:443:93.184.216.34"
	refute_output --partial "--resolve *:"
}

@test "https_resolution: uses dscacheutil answers when getent has none" {
	stub_resolvers "" "name: example.com
ip_address: 93.184.216.34
"
	run_provider "https://example.com/file"
	assert_success
	run cat "${CURL_CALLS}"
	assert_output --partial "--resolve example.com:443:93.184.216.34"
}

@test "https_resolution: refuses a host that resolves to a private address" {
	stub_resolvers "93.184.216.34 STREAM example.com
100.100.100.200 STREAM
" ""
	run_provider "https://example.com/file"
	assert_equal "${status}" "4"
	[ ! -s "${CURL_CALLS}" ] || fail "curl was called: $(cat "${CURL_CALLS}")"
}

@test "https_resolution: refuses a host that resolves to non-canonical IPv6 loopback" {
	stub_resolvers "0:0:0:0:0:0:0:1 STREAM example.com
" ""
	run_provider "https://example.com/file"
	assert_equal "${status}" "4"
	[ ! -s "${CURL_CALLS}" ] || fail "curl was called"
}

@test "https_resolution: obfuscated IPv4 literals are refused before curl" {
	local h failures=""
	for h in 0177.0.0.1 0x7f.0.0.1 0177.1 010.0.0.1 127.1 2130706433 0x7f000001; do
		: >"${CURL_CALLS}"
		run_provider "https://${h}/"
		if [ "${status}" != "4" ] || [ -s "${CURL_CALLS}" ]; then
			failures="${failures} ${h}(rc=${status})"
		fi
	done
	[ -z "${failures}" ] || fail "not refused:${failures}"
}

@test "https_resolution: private and non-canonical IPv6 literals are refused before curl" {
	local h failures=""
	for h in "[::1]" "[0:0:0:0:0:0:0:1]" "[::]" "[::ffff:127.0.0.1]" "[::ffff:7f00:1]" "[64:ff9b::7f00:1]" "[2002:7f00:1::]" "[fe80::1]" "[fd00::1]"; do
		: >"${CURL_CALLS}"
		run_provider "https://${h}/"
		if [ "${status}" != "4" ] || [ -s "${CURL_CALLS}" ]; then
			failures="${failures} ${h}(rc=${status})"
		fi
	done
	[ -z "${failures}" ] || fail "not refused:${failures}"
}

@test "https_resolution: new private IPv4 ranges are refused as literals" {
	local h failures=""
	for h in 0.1.2.3 100.64.0.1 100.100.100.200 192.0.0.170 198.18.0.1 224.0.0.1 240.0.0.1 255.255.255.255; do
		: >"${CURL_CALLS}"
		run_provider "https://${h}/"
		if [ "${status}" != "4" ] || [ -s "${CURL_CALLS}" ]; then
			failures="${failures} ${h}(rc=${status})"
		fi
	done
	[ -z "${failures}" ] || fail "not refused:${failures}"
}

@test "https_resolution: public literals are fetched without a lookup" {
	run_provider "https://93.184.216.34/file"
	assert_success
	run_provider "https://[2606:4700::1111]/file"
	assert_success
	assert_equal "$(wc -l <"${CURL_CALLS}" | tr -d ' ')" "2"
	[ ! -s "${RESOLVER_CALLS}" ] || fail "resolver consulted: $(cat "${RESOLVER_CALLS}")"
}

@test "https_resolution: hosts curl could spell differently are refused" {
	run_provider "https://example.com./file"
	assert_equal "${status}" "4"
	run_provider "https://ex%61mple.com/file"
	assert_equal "${status}" "4"
	[ ! -s "${CURL_CALLS}" ] || fail "curl was called"
}

@test "https_resolution: denied hosts are refused without a lookup" {
	ALLOW_ALL="false" ALLOW_HOSTS="other.example" run_provider "https://example.com/file"
	assert_equal "${status}" "4"
	[ ! -s "${RESOLVER_CALLS}" ] || fail "resolver consulted: $(cat "${RESOLVER_CALLS}")"
}

@test "https_resolution: mcp_download_safe refuses a host resolving to cloud metadata" {
	stub_resolvers "100.100.100.200 STREAM metadata.example
" ""
	local out="${BATS_TEST_TMPDIR}/dl.out"
	run env PATH="${BIN_DIR}:${PATH}" \
		MCPBASH_HOME="${MCPBASH_HOME}" \
		MCPBASH_JSON_TOOL_BIN="${MCPBASH_JSON_TOOL_BIN:-}" \
		CURL_CALLS="${CURL_CALLS}" RESOLVER_CALLS="${RESOLVER_CALLS}" \
		bash -c '. "${MCPBASH_HOME}/sdk/tool-sdk.sh"; mcp_download_safe --url "https://metadata.example/latest" --out "$1" --allow metadata.example' _ "${out}"
	assert_success
	assert_output --partial '"host_blocked"'
	[ ! -s "${CURL_CALLS}" ] || fail "curl was called: $(cat "${CURL_CALLS}")"
	[ ! -e "${out}" ] || fail "output written"
}

@test "https_resolution: mcp_download_safe pins the vetted address" {
	stub_resolvers "93.184.216.34 STREAM example.com
" ""
	local out="${BATS_TEST_TMPDIR}/dl.out"
	run env PATH="${BIN_DIR}:${PATH}" \
		MCPBASH_HOME="${MCPBASH_HOME}" \
		MCPBASH_JSON_TOOL_BIN="${MCPBASH_JSON_TOOL_BIN:-}" \
		CURL_CALLS="${CURL_CALLS}" RESOLVER_CALLS="${RESOLVER_CALLS}" \
		bash -c '. "${MCPBASH_HOME}/sdk/tool-sdk.sh"; mcp_download_safe --url "https://example.com/f" --out "$1" --allow example.com' _ "${out}"
	assert_success
	assert_output --partial '"success":true'
	run cat "${CURL_CALLS}"
	assert_output --partial "--resolve example.com:443:93.184.216.34"
}
