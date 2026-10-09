#!/usr/bin/env bats
# Unit tests for lib/file_read.sh and the providers that use it: a symlink
# swapped in between the containment/symlink check and the open must never
# return content from outside the checked location.
#
# The swaps are made deterministic with PATH stubs: a stub `realpath` swaps a
# parent directory right after the provider canonicalizes the path, and a stub
# `stat` swaps the final component right after the pre-open lstat.

load '../../node_modules/bats-support/load'
load '../../node_modules/bats-assert/load'
load '../common/fixtures'

setup() {
	case "${OSTYPE:-}" in
	msys* | cygwin*) skip "needs native symlinks" ;;
	esac
	TEST_TMPDIR="$(mktemp -d)"
	BASE="$(cd "${TEST_TMPDIR}" && pwd -P)"
	ROOT="${BASE}/root"
	OUTSIDE="${BASE}/outside"
	STUBS="${BASE}/stubs"
	mkdir -p "${ROOT}/sub" "${OUTSIDE}/sub" "${STUBS}"
	printf 'inside\n' >"${ROOT}/x"
	printf 'inside-sub\n' >"${ROOT}/sub/x"
	printf 'OUTSIDE-SECRET\n' >"${OUTSIDE}/secret"
	printf 'OUTSIDE-SECRET\n' >"${OUTSIDE}/sub/x"
	REAL_STAT="$(command -v stat)"
	REAL_REALPATH="$(command -v realpath || true)"
	export BASE ROOT OUTSIDE STUBS REAL_STAT REAL_REALPATH
	# shellcheck source=lib/file_read.sh
	# shellcheck disable=SC1091
	. "${MCPBASH_HOME}/lib/file_read.sh"
}

teardown() {
	[ -n "${TEST_TMPDIR:-}" ] && rm -rf "${TEST_TMPDIR}"
}

# Stub `stat`: behaves like the real one, but the first lstat (no -L) of
# "./NAME" swaps NAME for a symlink to TARGET right after reporting it.
install_stat_swap_stub() {
	local name="$1" target="$2"
	cat >"${STUBS}/stat" <<EOF
#!/usr/bin/env bash
"${REAL_STAT}" "\$@"
rc=\$?
follow=0
for a in "\$@"; do [ "\$a" = "-L" ] && follow=1; done
last="\${!#}"
if [ "\${follow}" = 0 ] && [ "\${last}" = "./${name}" ] && [ ! -e "${STUBS}/stat.done" ]; then
	: >"${STUBS}/stat.done"
	ln -s "${target}" ".swap.\$\$" && mv -f ".swap.\$\$" "${name}"
fi
exit \${rc}
EOF
	chmod +x "${STUBS}/stat"
}

# Stub `realpath`: behaves like the real one, but after resolving SWAP_ON it
# replaces DIR with a symlink to DIR_TARGET.
install_realpath_swap_stub() {
	local swap_on="$1" dir="$2" dir_target="$3"
	cat >"${STUBS}/realpath" <<EOF
#!/usr/bin/env bash
"${REAL_REALPATH}" "\$@"
rc=\$?
if [ "\${!#}" = "${swap_on}" ] && [ ! -e "${STUBS}/realpath.done" ]; then
	: >"${STUBS}/realpath.done"
	mv "${dir}" "${dir}.real" && ln -s "${dir_target}" "${dir}"
fi
exit \${rc}
EOF
	chmod +x "${STUBS}/realpath"
}

file_provider() {
	PATH="${STUBS}:${PATH}" MCP_RESOURCES_ROOTS="${ROOT}" \
		"${MCPBASH_HOME}/providers/file.sh" "file://$1"
}

@test "file provider: regular file inside the root is read" {
	run file_provider "${ROOT}/x"
	assert_success
	assert_output "inside"
}

@test "file provider: parent directory swapped for a symlink after the check is refused" {
	[ -n "${REAL_REALPATH}" ] || skip "realpath not available"
	install_realpath_swap_stub "${ROOT}/sub/x" "${ROOT}/sub" "${OUTSIDE}/sub"
	run file_provider "${ROOT}/sub/x"
	[ -e "${STUBS}/realpath.done" ] || fail "stub did not swap"
	refute_output --partial "OUTSIDE-SECRET"
	assert_failure 2
}

@test "file provider: final component swapped for a symlink between check and open is refused" {
	install_stat_swap_stub x "${OUTSIDE}/secret"
	run file_provider "${ROOT}/x"
	[ -e "${STUBS}/stat.done" ] || fail "stub did not swap"
	[ -L "${ROOT}/x" ] || fail "x was not swapped"
	refute_output --partial "OUTSIDE-SECRET"
	assert_failure 2
}

@test "file provider: symlink inside the root pointing outside is refused" {
	ln -s "${OUTSIDE}/secret" "${ROOT}/lnk"
	run file_provider "${ROOT}/lnk"
	refute_output --partial "OUTSIDE-SECRET"
	assert_failure 2
}

@test "file_read: reads a regular file, including empty files and odd names" {
	printf 'a b\n' >"${ROOT}/-n odd name"
	: >"${ROOT}/empty"
	run mcp_file_read_verified "${ROOT}/-n odd name"
	assert_success
	assert_output "a b"
	run mcp_file_read_verified "${ROOT}/empty" "" "${ROOT}"
	assert_success
	assert_output ""
	run mcp_file_read_verified "${ROOT}/sub/x" "" "${ROOT}"
	assert_success
	assert_output "inside-sub"
}

@test "file_read: refuses symlinks, directories and FIFOs without opening them" {
	ln -s "${OUTSIDE}/secret" "${ROOT}/lnk"
	mkdir "${ROOT}/d"
	mkfifo "${ROOT}/fifo"
	run mcp_file_read_verified "${ROOT}/lnk"
	assert_failure 2
	refute_output --partial "OUTSIDE-SECRET"
	run mcp_file_read_verified "${ROOT}/d"
	assert_failure 2
	# A FIFO would block an open(); it must be refused before the open.
	run mcp_file_read_verified "${ROOT}/fifo"
	assert_failure 2
}

@test "file_read: missing file is not found" {
	run mcp_file_read_verified "${ROOT}/missing"
	assert_failure 3
}

@test "file_read: size limit applies to the opened file" {
	printf '0123456789' >"${ROOT}/ten"
	run mcp_file_read_verified "${ROOT}/ten" 10
	assert_success
	assert_output "0123456789"
	run mcp_file_read_verified "${ROOT}/ten" 9
	assert_failure 4
	assert_output ""
}

@test "file_read: directory that is not really under ROOT is refused" {
	# root/sub is a symlink to an outside directory: the path string looks
	# inside, but the directory actually entered is not a descendant of ROOT.
	rm -rf "${ROOT}/sub"
	ln -s "${OUTSIDE}/sub" "${ROOT}/sub"
	run mcp_file_read_verified "${ROOT}/sub/x" "" "${ROOT}"
	refute_output --partial "OUTSIDE-SECRET"
	assert_failure 2
}

@test "file_read: ROOT that does not contain the path is refused" {
	run mcp_file_read_verified "${ROOT}/x" "" "${OUTSIDE}"
	assert_failure 2
}

@test "file_read: final component swapped between lstat and open is refused" {
	install_stat_swap_stub x "${OUTSIDE}/secret"
	PATH="${STUBS}:${PATH}" run mcp_file_read_verified "${ROOT}/x" "" "${ROOT}"
	[ -e "${STUBS}/stat.done" ] || fail "stub did not swap"
	refute_output --partial "OUTSIDE-SECRET"
	assert_failure 2
}

@test "file_read: no usable stat means refuse, not an unchecked read" {
	printf '#!/bin/sh\nexit 1\n' >"${STUBS}/stat"
	chmod +x "${STUBS}/stat"
	PATH="${STUBS}:${PATH}" run mcp_file_read_verified "${ROOT}/x"
	assert_failure 5
	assert_output ""
}

ui_provider() {
	PATH="${STUBS}:${PATH}" MCPBASH_UI_DIR="${BASE}/ui" MCPBASH_TOOLS_DIR="${BASE}/tools" \
		"$@" "${MCPBASH_HOME}/providers/ui.sh" "ui://srv/app"
}

@test "ui provider: final component swapped between check and open is refused" {
	mkdir -p "${BASE}/ui/app"
	printf '<html>ok</html>\n' >"${BASE}/ui/app/index.html"
	run ui_provider env -u MCPBASH_HOME
	assert_success
	assert_output "<html>ok</html>"
	install_stat_swap_stub index.html "${OUTSIDE}/secret"
	run ui_provider env -u MCPBASH_HOME
	[ -e "${STUBS}/stat.done" ] || fail "stub did not swap"
	refute_output --partial "OUTSIDE-SECRET"
	assert_failure 2
}

@test "ui provider: registry-backed read refuses a symlinked index.html" {
	# With a JSON tool (as the server passes it), the provider serves static
	# HTML through mcp_ui_get_content, which used to cat the path unchecked.
	local json_bin json_name
	json_bin="$(command -v jq || command -v gojq || true)"
	[ -n "${json_bin}" ] || skip "JSON tooling unavailable"
	json_name="$(basename "${json_bin}")"
	mkdir -p "${BASE}/ui/app" "${BASE}/state" "${BASE}/tools"
	ln -s "${OUTSIDE}/secret" "${BASE}/ui/app/index.html"
	run ui_provider env MCPBASH_PROJECT_ROOT="${BASE}" MCPBASH_STATE_DIR="${BASE}/state" \
		MCPBASH_REGISTRY_DIR="${BASE}/state" \
		MCPBASH_JSON_TOOL_BIN="${json_bin}" MCPBASH_JSON_TOOL="${json_name}"
	refute_output --partial "OUTSIDE-SECRET"
	assert_failure 2
}

@test "ui provider: registry-backed read serves a regular index.html" {
	local json_bin json_name
	json_bin="$(command -v jq || command -v gojq || true)"
	[ -n "${json_bin}" ] || skip "JSON tooling unavailable"
	json_name="$(basename "${json_bin}")"
	mkdir -p "${BASE}/ui/app" "${BASE}/state" "${BASE}/tools"
	printf '<html>registry</html>\n' >"${BASE}/ui/app/index.html"
	run ui_provider env MCPBASH_PROJECT_ROOT="${BASE}" MCPBASH_STATE_DIR="${BASE}/state" \
		MCPBASH_REGISTRY_DIR="${BASE}/state" \
		MCPBASH_JSON_TOOL_BIN="${json_bin}" MCPBASH_JSON_TOOL="${json_name}"
	assert_success
	assert_output "<html>registry</html>"
}

@test "ui provider: size limit applies to the opened file" {
	mkdir -p "${BASE}/ui/app"
	printf '0123456789' >"${BASE}/ui/app/index.html"
	run ui_provider env -u MCPBASH_HOME MCPBASH_MAX_UI_RESOURCE_BYTES=9
	assert_failure 3
	assert_output --partial "too large"
	run ui_provider env -u MCPBASH_HOME MCPBASH_MAX_UI_RESOURCE_BYTES=10
	assert_success
	assert_output "0123456789"
}
