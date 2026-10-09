#!/usr/bin/env bats
# Unit: git provider resolves the host once, refuses private answers, fails
# closed when resolution fails, and pins git's libcurl to the vetted addresses
# via http.curloptResolve (with redirects off).
#
# No network: git and every resolver are fakes on PATH.

load '../../node_modules/bats-support/load'
load '../../node_modules/bats-assert/load'
load '../common/fixtures'

setup() {
	PROVIDER="${MCPBASH_HOME}/providers/git.sh"
	BIN_DIR="${BATS_TEST_TMPDIR}/bin"
	mkdir -p "${BIN_DIR}"
	GIT_CALLS="${BATS_TEST_TMPDIR}/git.calls"
	RESOLVER_CALLS="${BATS_TEST_TMPDIR}/resolver.calls"
	: >"${GIT_CALLS}"
	: >"${RESOLVER_CALLS}"
	export GIT_CALLS RESOLVER_CALLS
	FAKE_GIT_VERSION="2.40.1"
	write_fake_git
	stub_resolvers ""
}

write_fake_git() {
	cat >"${BIN_DIR}/git" <<EOF
#!/usr/bin/env bash
if [ "\${1:-}" = "--version" ]; then
	printf 'git version %s\n' "${FAKE_GIT_VERSION}"
	exit 0
fi
printf '%s\n' "\$*" >>"\${GIT_CALLS:?}"
exit 1
EOF
	chmod 700 "${BIN_DIR}/git"
}

# stub_resolvers <getent-ahosts-output>
stub_resolvers() {
	printf '%s' "$1" >"${BATS_TEST_TMPDIR}/getent.out"
	cat >"${BIN_DIR}/getent" <<EOF
#!/usr/bin/env bash
printf 'getent %s\n' "\$*" >>"\${RESOLVER_CALLS:?}"
if [ -s "${BATS_TEST_TMPDIR}/getent.out" ]; then
	cat "${BATS_TEST_TMPDIR}/getent.out"
	exit 0
fi
exit 2
EOF
	chmod 700 "${BIN_DIR}/getent"
	local name
	for name in dscacheutil dig host nslookup; do
		cat >"${BIN_DIR}/${name}" <<EOF
#!/usr/bin/env bash
printf '%s %s\n' "${name}" "\$*" >>"\${RESOLVER_CALLS:?}"
exit 0
EOF
		chmod 700 "${BIN_DIR}/${name}"
	done
}

run_provider() {
	run env PATH="${BIN_DIR}:${PATH}" \
		MCPBASH_HOME="${MCPBASH_HOME}" \
		MCPBASH_ENABLE_GIT_PROVIDER=true \
		MCPBASH_GIT_ALLOW_ALL=true \
		GIT_CALLS="${GIT_CALLS}" RESOLVER_CALLS="${RESOLVER_CALLS}" \
		bash "${PROVIDER}" "$1"
}

@test "git_pinning: refuses and never runs git when resolution fails" {
	run_provider "git+https://unresolvable.example/repo.git#main:README.md"
	assert_equal "${status}" "5"
	assert_output --partial "unable to resolve"
	[ ! -s "${GIT_CALLS}" ] || fail "git was run: $(cat "${GIT_CALLS}")"
}

@test "git_pinning: pins clone to the vetted address and disables redirects" {
	stub_resolvers "93.184.216.34 STREAM example.com
2606:4700::1111 STREAM
"
	run_provider "git+https://example.com/repo.git#main:README.md"
	# The fake git fails the clone; we only care about its argv.
	assert_equal "${status}" "5"
	run cat "${GIT_CALLS}"
	assert_output --partial "http.curloptResolve=example.com:443:93.184.216.34,[2606:4700::1111]"
	assert_output --partial "http.followRedirects=false"
	assert_output --partial "clone"
}

@test "git_pinning: pins fetch-by-sha with the URL port" {
	stub_resolvers "93.184.216.34 STREAM example.com
"
	run_provider "git+https://example.com:8443/repo.git#0123456789abcdef:README.md"
	run cat "${GIT_CALLS}"
	assert_output --partial "http.curloptResolve=example.com:8443:93.184.216.34"
}

@test "git_pinning: refuses a host that resolves to a private address" {
	stub_resolvers "10.1.2.3 STREAM example.com
"
	run_provider "git+https://example.com/repo.git#main:README.md"
	assert_equal "${status}" "4"
	[ ! -s "${GIT_CALLS}" ] || fail "git was run"
}

@test "git_pinning: refuses when git is too old to pin" {
	stub_resolvers "93.184.216.34 STREAM example.com
"
	FAKE_GIT_VERSION="2.36.6"
	write_fake_git
	run_provider "git+https://example.com/repo.git#main:README.md"
	assert_equal "${status}" "4"
	assert_output --partial "2.37"
	[ ! -s "${GIT_CALLS}" ] || fail "git was run"
}

@test "git_pinning: obfuscated and private literals are refused before git" {
	local h failures=""
	for h in 0177.0.0.1 0x7f.0.0.1 0177.1 127.1 2130706433 "[0:0:0:0:0:0:0:1]" "[::]" "[::ffff:7f00:1]" 100.100.100.200; do
		: >"${GIT_CALLS}"
		run_provider "git+https://${h}/repo.git#main:README.md"
		if [ "${status}" != "4" ] || [ -s "${GIT_CALLS}" ]; then
			failures="${failures} ${h}(rc=${status})"
		fi
	done
	[ -z "${failures}" ] || fail "not refused:${failures}"
}
