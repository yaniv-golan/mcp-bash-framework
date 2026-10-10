#!/usr/bin/env bats
# Unit: shared address classification in lib/policy.sh (no network).
#
# lib/policy.sh holds the one private-range list that providers/https.sh and
# providers/git.sh use. These tables pin down which literals are refused.

load '../../node_modules/bats-support/load'
load '../../node_modules/bats-assert/load'
load '../common/fixtures'

setup() {
	# shellcheck source=lib/policy.sh
	# shellcheck disable=SC1091
	. "${MCPBASH_HOME}/lib/policy.sh"
}

# Hosts that curl would turn into a loopback/private address, or that are not
# a canonical dotted quad. All must be refused before any lookup.
OBFUSCATED_V4="0177.0.0.1 0x7f.0.0.1 0177.1 010.0.0.1 127.1 2130706433 0x7f000001 0X7F000001 127.0.0.01 0177.0.0.0 0.0.0.010 10.0.01.1 127.0.0.1. 1.2.3.0x 256.1.1.1 1.2.3.4.5"

PRIVATE_V4="0.0.0.0 0.1.2.3 10.0.0.1 100.64.0.1 100.100.100.200 100.127.255.255 127.0.0.1 127.255.255.254 169.254.169.254 172.16.0.1 172.31.255.255 192.0.0.170 192.168.1.1 198.18.0.1 198.19.255.255 224.0.0.1 239.255.255.250 240.0.0.1 255.255.255.255"

PRIVATE_V6="[::1] ::1 [0:0:0:0:0:0:0:1] [::] :: [0:0:0:0:0:0:0:0] [::ffff:127.0.0.1] [0:0:0:0:0:ffff:127.0.0.1] [::ffff:7f00:1] [0:0:0:0:0:ffff:7f00:0001] [::127.0.0.1] [::ffff:0:127.0.0.1] [64:ff9b::7f00:1] [64:ff9b::10.0.0.1] [64:ff9b:1::1] [2002:7f00:1::] [2002:a9fe:a9fe::1] [2001:0:4136:e378:8000:63bf:80ff:fffe] [fe80::1] [FE80::1] [fe80::1%25en0] [fd00::1] [fc00::1] [fec0::1] [ff02::1] [100::1] [::ffff:100.100.100.200]"

PUBLIC="93.184.216.34 8.8.8.8 1.1.1.1 100.63.255.255 100.128.0.0 172.15.255.255 172.32.0.0 192.0.1.1 192.169.0.1 198.17.255.255 198.20.0.0 223.255.255.255 [2606:4700::1111] [2606:4700:4700::1111] [2001:4860:4860::8888] [::ffff:93.184.216.34] [64:ff9b::5db8:d822] [2002:5db8:d822::1]"

MALFORMED_V6="[1::2::3] [:::1] [1:2:3:4:5:6:7:8:9] [1:2:3:4:5:6:7:8:] [:1:2:3:4:5:6:7:8] [12345::1] [g::1] [::ffff:127.0.0.01] [::ffff:127.1]"

@test "policy_ip: obfuscated and non-canonical IPv4 literals are refused" {
	local h failures=""
	for h in ${OBFUSCATED_V4}; do
		if ! mcp_policy_ip_is_private "${h}"; then
			failures="${failures} ${h}"
		fi
	done
	[ -z "${failures}" ] || fail "classified as public:${failures}"
}

@test "policy_ip: obfuscated literals are recognised as non-canonical" {
	local h failures=""
	for h in ${OBFUSCATED_V4}; do
		if ! mcp_policy_host_is_noncanonical_ip_literal "${h}"; then
			failures="${failures} ${h}"
		fi
	done
	[ -z "${failures}" ] || fail "not flagged:${failures}"
}

@test "policy_ip: private, reserved and special IPv4 ranges are refused" {
	local h failures=""
	for h in ${PRIVATE_V4}; do
		if ! mcp_policy_ip_is_private "${h}"; then
			failures="${failures} ${h}"
		fi
	done
	[ -z "${failures}" ] || fail "classified as public:${failures}"
}

@test "policy_ip: loopback, unspecified, local and v4-embedding IPv6 forms are refused" {
	local h failures=""
	for h in ${PRIVATE_V6}; do
		if ! mcp_policy_ip_is_private "${h}"; then
			failures="${failures} ${h}"
		fi
	done
	[ -z "${failures}" ] || fail "classified as public:${failures}"
}

@test "policy_ip: malformed IPv6 literals fail closed" {
	local h failures=""
	for h in ${MALFORMED_V6}; do
		if ! mcp_policy_ip_is_private "${h}"; then
			failures="${failures} ${h}"
		fi
	done
	[ -z "${failures}" ] || fail "classified as public:${failures}"
}

@test "policy_ip: public addresses still pass" {
	local h failures=""
	for h in ${PUBLIC}; do
		if mcp_policy_ip_is_private "${h}"; then
			failures="${failures} ${h}"
		fi
		if mcp_policy_host_is_noncanonical_ip_literal "${h}"; then
			failures="${failures} noncanonical:${h}"
		fi
	done
	[ -z "${failures}" ] || fail "refused:${failures}"
}

@test "policy_ip: ordinary hostnames are not literals (including hex-letter names)" {
	local h failures=""
	for h in example.com abc.ca bad.de cafe.face deadbeef api.github.com x0.example a-b.example; do
		if mcp_policy_host_is_noncanonical_ip_literal "${h}"; then
			failures="${failures} ${h}"
		fi
		if mcp_policy_ip_is_private "${h}"; then
			failures="${failures} private:${h}"
		fi
	done
	[ -z "${failures}" ] || fail "misclassified:${failures}"
}

@test "policy_ip: localhost names are refused" {
	local h failures=""
	for h in localhost LOCALHOST foo.localhost ""; do
		if ! mcp_policy_ip_is_private "${h}"; then
			failures="${failures} [${h}]"
		fi
	done
	[ -z "${failures}" ] || fail "classified as public:${failures}"
}

@test "policy_ip: hostnames curl could spell differently are invalid" {
	local h failures=""
	for h in "example.com." "ex%41mple.com" "exämple.com" "a..b" ".example.com" "-a.example" "a b"; do
		if mcp_policy_hostname_is_valid "${h}"; then
			failures="${failures} [${h}]"
		fi
	done
	for h in example.com api.github.com xn--bcher-kva.example a_b.example 1password.com; do
		if ! mcp_policy_hostname_is_valid "${h}"; then
			failures="${failures} rejected:[${h}]"
		fi
	done
	[ -z "${failures}" ] || fail "misclassified:${failures}"
}

@test "policy_ip: host_is_private fails closed when resolution fails" {
	mcp_policy_resolve_ips() { return 1; }
	run mcp_policy_host_is_private "unresolvable.example"
	assert_success
}

@test "policy_ip: resolve_vetted_ips reports unresolvable, blocked and public answers" {
	mcp_policy_resolve_ips() { return 1; }
	run mcp_policy_resolve_vetted_ips "a.example"
	assert_equal "${status}" "1"

	mcp_policy_resolve_ips() { printf '%s\n' "93.184.216.34" "100.100.100.200"; }
	run mcp_policy_resolve_vetted_ips "a.example"
	assert_equal "${status}" "2"

	mcp_policy_resolve_ips() { printf '%s\n' "93.184.216.34" "2606:4700::1111"; }
	run mcp_policy_resolve_vetted_ips "a.example"
	assert_success
	assert_output "93.184.216.34
2606:4700::1111"
}

@test "policy_ip: extract_port_from_url handles defaults, IPv6 and userinfo" {
	assert_equal "$(mcp_policy_extract_port_from_url 'https://example.com/x')" "443"
	assert_equal "$(mcp_policy_extract_port_from_url 'https://example.com:8443/x')" "8443"
	assert_equal "$(mcp_policy_extract_port_from_url 'https://[2606:4700::1111]:8443/x')" "8443"
	assert_equal "$(mcp_policy_extract_port_from_url 'https://[2606:4700::1111]/x')" "443"
	assert_equal "$(mcp_policy_extract_port_from_url 'https://u:p@example.com:9443/x')" "9443"
	assert_equal "$(mcp_policy_extract_port_from_url 'git+https://example.com/r#main:a:b')" "443"
	assert_equal "$(mcp_policy_extract_port_from_url 'https://example.com:65535/')" "65535"
	assert_equal "$(mcp_policy_extract_port_from_url 'https://example.com:1/')" "1"
}

# Port spellings that are not canonical decimal 1-65535. curl/git would read
# some of these as a different port than a lenient parser, so the pin would
# not match the connection. All must be refused (non-zero, no output).
NONCANONICAL_PORTS="000080 080 0 00 0000000000443 65536 99999 +80 -1 80:90 0x50 8a :"

@test "policy_ip: extract_port_from_url refuses non-canonical ports" {
	local p out rc failures=""
	for p in ${NONCANONICAL_PORTS}; do
		rc=0
		out="$(mcp_policy_extract_port_from_url "https://example.com:${p}/x")" || rc=$?
		if [ "${rc}" -eq 0 ] || [ -n "${out}" ]; then
			failures="${failures} ${p}(rc=${rc},out=${out})"
		fi
	done
	for p in "https://example.com:/x" "https://[2606:4700::1111]:/x" "https://[2606:4700::1111]:000080/x" "https://[2606:4700::1111]x/"; do
		rc=0
		out="$(mcp_policy_extract_port_from_url "${p}")" || rc=$?
		if [ "${rc}" -eq 0 ] || [ -n "${out}" ]; then
			failures="${failures} ${p}(rc=${rc},out=${out})"
		fi
	done
	[ -z "${failures}" ] || fail "accepted:${failures}"
}
