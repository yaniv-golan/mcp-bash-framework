#!/usr/bin/env bats
# Unit: HTTPS provider pins DNS resolution with curl --resolve to prevent
# DNS-rebinding TOCTOU between "check host/IPs" and the actual fetch.

load '../../node_modules/bats-support/load'
load '../../node_modules/bats-assert/load'
load '../common/fixtures'
load '../common/ndjson'

setup() {
	PROVIDER="${MCPBASH_HOME}/providers/https.sh"

	FAKE_HOME="${BATS_TEST_TMPDIR}/home"
	mkdir -p "${FAKE_HOME}/lib"

	# Minimal policy shim so the provider sources our resolver.
	cat >"${FAKE_HOME}/lib/policy.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

mcp_policy_normalize_host() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }
mcp_policy_extract_host_from_url() {
	local url="$1"
	local authority="${url#*://}"
	authority="${authority%%/*}"
	authority="${authority%%\?*}"
	authority="${authority%%\#*}"
	authority="${authority##*@}"
	printf '%s' "${authority%%:*}" | tr '[:upper:]' '[:lower:]'
}
mcp_policy_host_is_private() { return 1; }
mcp_policy_host_allowed() { return 0; }
mcp_policy_resolve_ips() {
	# Provide two public IPs; fake curl will fail the first and succeed the second.
	printf '%s\n' "203.0.113.10" "203.0.113.11"
}
EOF

	BIN_DIR="${BATS_TEST_TMPDIR}/bin"
	mkdir -p "${BIN_DIR}"

	CALLS_FILE="${BATS_TEST_TMPDIR}/curl.calls"
	STATE_FILE="${BATS_TEST_TMPDIR}/curl.state"
	: >"${CALLS_FILE}"
	: >"${STATE_FILE}"
	export CALLS_FILE STATE_FILE

	# Fake curl: record argv; fail first call, succeed second; write output file.
	cat >"${BIN_DIR}/curl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

calls_file="${CALLS_FILE:?}"
state_file="${STATE_FILE:?}"

printf '%s\n' "$*" >>"${calls_file}"

out=""
prev=""
for a in "$@"; do
	if [ "${prev}" = "-o" ]; then
		out="${a}"
	fi
	prev="${a}"
done
if [ -n "${out}" ]; then
	printf 'ok\n' >"${out}"
fi

n=0
if [ -f "${state_file}" ]; then
	n="$(cat "${state_file}" 2>/dev/null || printf '0')"
fi
n=$((n + 1))
printf '%s' "${n}" >"${state_file}"

if [ "${n}" -eq 1 ]; then
	exit 7
fi
exit 0
EOF
	chmod 700 "${BIN_DIR}/curl"
}

@test "https_dns_pinning: pins curl to resolved IPs with --resolve and retries" {
	run bash -c "
		PATH='${BIN_DIR}:${PATH}' \
		CALLS_FILE='${CALLS_FILE}' \
		STATE_FILE='${STATE_FILE}' \
		MCPBASH_HOME='${FAKE_HOME}' \
		MCPBASH_HTTPS_ALLOW_ALL='true' \
		bash '${PROVIDER}' 'https://example.com:8443/path'
	"
	assert_success

	calls="$(cat "${CALLS_FILE}")"
	assert_contains "--resolve example.com:8443:203.0.113.10" "${calls}"
	assert_contains "--resolve example.com:8443:203.0.113.11" "${calls}"
}
