#!/usr/bin/env bats
# Unit: HTTPS provider requires curl (wget fallback removed).

load '../../node_modules/bats-support/load'
load '../../node_modules/bats-assert/load'
load '../common/fixtures'

setup() {
	PROVIDER="${MCPBASH_HOME}/providers/https.sh"

	FAKE_HOME="${BATS_TEST_TMPDIR}/home"
	mkdir -p "${FAKE_HOME}/lib"

	# Minimal policy shim so the provider doesn't depend on system DNS tools.
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
	local host="${authority%%:*}"
	printf '%s' "${host}" | tr '[:upper:]' '[:lower:]'
}
mcp_policy_host_is_private() { return 1; }
mcp_policy_host_allowed() { return 0; }
mcp_policy_resolve_ips() { printf '%s\n' "203.0.113.10"; }
EOF

	BIN_DIR="${BATS_TEST_TMPDIR}/bin"
	mkdir -p "${BIN_DIR}"

	# Provide mktemp without putting /usr/bin on PATH.
	cat >"${BIN_DIR}/mktemp" <<'EOF'
#!/usr/bin/env bash
exec /usr/bin/mktemp "$@"
EOF
	chmod 700 "${BIN_DIR}/mktemp"

	# Provide bash shim.
	cat >"${BIN_DIR}/bash" <<'EOF'
#!/bin/bash
exec /bin/bash "$@"
EOF
	chmod 700 "${BIN_DIR}/bash"

	# Provider uses rm in EXIT trap.
	cat >"${BIN_DIR}/rm" <<'EOF'
#!/bin/bash
exec /bin/rm "$@"
EOF
	chmod 700 "${BIN_DIR}/rm"

	# Minimal coreutils shims.
	cat >"${BIN_DIR}/tr" <<'EOF'
#!/usr/bin/env bash
exec /usr/bin/tr "$@"
EOF
	chmod 700 "${BIN_DIR}/tr"

	cat >"${BIN_DIR}/grep" <<'EOF'
#!/usr/bin/env bash
exec /usr/bin/grep "$@"
EOF
	chmod 700 "${BIN_DIR}/grep"

	# Provide a wget stub to prove we don't call it.
	WGET_CALLED_FILE="${BATS_TEST_TMPDIR}/wget.called"
	export WGET_CALLED_FILE
	cat >"${BIN_DIR}/wget" <<EOF
#!/usr/bin/env bash
set -euo pipefail
: >"${WGET_CALLED_FILE}"
exit 0
EOF
	chmod 700 "${BIN_DIR}/wget"

	stderr_file="${BATS_TEST_TMPDIR}/stderr.txt"
	: >"${stderr_file}"
}

@test "https_requires_curl: fails closed when curl is missing" {
	stderr_file="${BATS_TEST_TMPDIR}/stderr.txt"
	run bash -c "
		PATH='${BIN_DIR}' \
		MCPBASH_HOME='${FAKE_HOME}' \
		MCPBASH_HTTPS_ALLOW_ALL='true' \
		/bin/bash '${PROVIDER}' 'https://example.com/' 2>'${stderr_file}'
	"
	assert_equal "4" "${status}"

	run grep -q "curl is required" "${stderr_file}"
	assert_success

	[ ! -f "${WGET_CALLED_FILE}" ]
}
