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
printf 'LFS_SKIP=%s %s\n' "\${GIT_LFS_SKIP_SMUDGE:-unset}" "\$*" >>"\${GIT_CALLS:?}"
# FAKE_GIT_FAIL_ON: fail only on this subcommand (default: fail every call).
if [ -n "\${FAKE_GIT_FAIL_ON:-}" ]; then
	case " \$* " in
	*" \${FAKE_GIT_FAIL_ON} "*) exit 1 ;;
	esac
	exit 0
fi
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
		FAKE_GIT_FAIL_ON="${FAKE_GIT_FAIL_ON:-}" \
		bash "${PROVIDER}" "$1"
}

# Every recorded git call must run with LFS smudging off and the lfs filter
# driver blanked, so a repository's .lfsconfig cannot steer git-lfs (its own
# HTTP client, outside the pinning and redirect controls) to any URL.
assert_lfs_disabled_on_every_call() {
	local line failures=""
	[ -s "${GIT_CALLS}" ] || fail "git was not run"
	while IFS= read -r line; do
		case "${line}" in
		"LFS_SKIP=1 "*) ;;
		*) failures="${failures} [env] ${line}" ;;
		esac
		case "${line}" in
		*"-c filter.lfs.smudge= "*"-c filter.lfs.process= "*"-c filter.lfs.required=false "*) ;;
		*) failures="${failures} [cfg] ${line}" ;;
		esac
	done <"${GIT_CALLS}"
	[ -z "${failures}" ] || fail "lfs not disabled:${failures}"
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

@test "git_pinning: refuses non-canonical ports before resolving or running git" {
	stub_resolvers "93.184.216.34 STREAM example.com
"
	local p failures=""
	for p in 000080 080 0 0000000000443 65536 80:90 ""; do
		: >"${GIT_CALLS}"
		: >"${RESOLVER_CALLS}"
		run_provider "git+https://example.com:${p}/repo.git#main:README.md"
		if [ "${status}" != "4" ] || [ -s "${GIT_CALLS}" ] || [ -s "${RESOLVER_CALLS}" ]; then
			failures="${failures} :${p}(rc=${status},git=$(tr '\n' ' ' <"${GIT_CALLS}"))"
		fi
	done
	[ -z "${failures}" ] || fail "not refused:${failures}"
	run_provider "git+https://example.com:000080/repo.git#main:README.md"
	assert_output --partial "port"
}

@test "git_pinning: clone runs with git-lfs smudging disabled" {
	stub_resolvers "93.184.216.34 STREAM example.com
"
	run_provider "git+https://example.com/repo.git#main:README.md"
	assert_equal "${status}" "5"
	run grep -c ' clone ' "${GIT_CALLS}"
	assert_output "1"
	assert_lfs_disabled_on_every_call
}

@test "git_pinning: fetch-by-sha runs every step with git-lfs smudging disabled" {
	stub_resolvers "93.184.216.34 STREAM example.com
"
	FAKE_GIT_FAIL_ON="checkout" run_provider "git+https://example.com/repo.git#0123456789abcdef:README.md"
	assert_equal "${status}" "5"
	run grep -c -e ' init ' -e ' remote ' -e ' fetch ' -e ' checkout ' "${GIT_CALLS}"
	assert_output "4"
	assert_lfs_disabled_on_every_call
}
