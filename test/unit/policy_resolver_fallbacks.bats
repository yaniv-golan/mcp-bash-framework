#!/usr/bin/env bats
# Unit layer: the DNS-only resolver fallbacks in mcp_policy_resolve_ips
# (lib/policy.sh), used when getent and dscacheutil are missing.

load '../../node_modules/bats-support/load'
load '../../node_modules/bats-assert/load'
load '../common/fixtures'

setup() {
	# shellcheck source=lib/policy.sh
	# shellcheck disable=SC1091
	. "${MCPBASH_HOME}/lib/policy.sh"
	# Only the stubbed resolver and the tools the function needs are on PATH,
	# so the host's real resolvers can't answer first.
	BIN_DIR="${BATS_TEST_TMPDIR}/bin"
	mkdir -p "${BIN_DIR}"
	local tool
	for tool in awk tail tr cat; do
		ln -s "$(command -v "${tool}")" "${BIN_DIR}/${tool}"
	done
	OUTPUT_FILE="${BATS_TEST_TMPDIR}/resolver.out"
}

# stub <tool>: the tool prints OUTPUT_FILE.
stub() {
	printf '#!/bin/sh\ncat "%s"\n' "${OUTPUT_FILE}" >"${BIN_DIR}/$1"
	chmod +x "${BIN_DIR}/$1"
}

resolve() {
	PATH="${BIN_DIR}" mcp_policy_resolve_ips "$1"
}

@test "resolver: nslookup (BIND/macOS layout) keeps the first answer" {
	stub nslookup
	printf 'Server:\t\t192.0.2.53\nAddress:\t192.0.2.53#53\n\nNon-authoritative answer:\nName:\texample.com\nAddress: 93.184.216.34\n' >"${OUTPUT_FILE}"
	run resolve example.com
	assert_success
	assert_output "93.184.216.34"
}

@test "resolver: nslookup (BusyBox layout) skips the server address" {
	stub nslookup
	printf 'Server:    192.0.2.53\nAddress:    192.0.2.53:53\n\nNon-authoritative answer:\nName:\texample.com\nAddress: 93.184.216.34\nName:\texample.com\nAddress: 2606:2800:220:1::1\n' >"${OUTPUT_FILE}"
	run resolve example.com
	assert_success
	assert_output "93.184.216.34
2606:2800:220:1::1"
}

@test "resolver: dig error lines are not taken for addresses" {
	stub dig
	printf ';; communications error to 192.0.2.53#53: timed out\n;; no servers could be reached\n' >"${OUTPUT_FILE}"
	run resolve example.com
	assert_failure
	assert_output ""
}

@test "resolver: dig answers are kept alongside error lines" {
	stub dig
	printf ';; communications error to 192.0.2.53#53: timed out\n93.184.216.34\n' >"${OUTPUT_FILE}"
	run resolve example.com
	assert_success
	assert_output "93.184.216.34"
}
