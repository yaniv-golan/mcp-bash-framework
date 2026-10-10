#!/usr/bin/env bats
# Unit: tool-embedded resources are read through the verified file read.
#
# The embed path checked the file against the roots and then opened it by name
# (several times: mime detection, NUL sniff, content). A file swapped for a
# symlink between the check and the read returned the symlink target's bytes.

load '../../node_modules/bats-support/load'
load '../../node_modules/bats-assert/load'
load '../common/fixtures'

setup() {
	# shellcheck source=lib/runtime.sh
	# shellcheck disable=SC1091
	. "${MCPBASH_HOME}/lib/runtime.sh"
	MCPBASH_FORCE_MINIMAL=false
	mcp_runtime_detect_json_tool
	if [ "${MCPBASH_MODE}" = "minimal" ]; then
		skip "JSON tooling unavailable"
	fi
	local lib
	for lib in logging path roots resource_content tools; do
		# shellcheck disable=SC1090
		. "${MCPBASH_HOME}/lib/${lib}.sh"
	done

	ROOT_DIR="$(cd "${BATS_TEST_TMPDIR}" && pwd -P)/root"
	OUTSIDE_DIR="$(cd "${BATS_TEST_TMPDIR}" && pwd -P)/outside"
	mkdir -p "${ROOT_DIR}" "${OUTSIDE_DIR}"
	printf 'inside content\n' >"${ROOT_DIR}/report.txt"
	printf 'outside secret\n' >"${OUTSIDE_DIR}/secret.txt"
	MCPBASH_ROOTS_PATHS=("${ROOT_DIR}")
}

@test "embed: a regular file inside the roots is embedded as text" {
	run mcp_tools_embed_resource_from_path "${ROOT_DIR}/report.txt" "text/plain" ""
	assert_success
	assert_equal "$(printf '%s' "${output}" | jq -r '.text')" "inside content"
	assert_equal "$(printf '%s' "${output}" | jq -r '.mimeType')" "text/plain"
}

@test "embed: binary content is still a base64 blob" {
	printf 'a\000b' >"${ROOT_DIR}/bin.dat"
	run mcp_tools_embed_resource_from_path "${ROOT_DIR}/bin.dat" "" ""
	assert_success
	assert_equal "$(printf '%s' "${output}" | jq -r '.blob' | base64 --decode 2>/dev/null | od -An -c | tr -d ' \n')" 'a\0b'
}

@test "embed: a symlink to a file outside the roots is skipped" {
	ln -s "${OUTSIDE_DIR}/secret.txt" "${ROOT_DIR}/link.txt"
	run mcp_tools_embed_resource_from_path "${ROOT_DIR}/link.txt" "text/plain" ""
	assert_failure
	refute_output --partial "outside secret"
}

@test "embed: a file swapped for a symlink after the roots check is not read" {
	# Swap the checked file for a symlink to an outside file between the
	# containment check and the read.
	eval "orig_$(declare -f mcp_roots_contains_path)"
	mcp_roots_contains_path() {
		local rc=0
		orig_mcp_roots_contains_path "$@" || rc=$?
		rm -f "${ROOT_DIR}/report.txt"
		ln -s "${OUTSIDE_DIR}/secret.txt" "${ROOT_DIR}/report.txt"
		return "${rc}"
	}
	run mcp_tools_embed_resource_from_path "${ROOT_DIR}/report.txt" "text/plain" ""
	refute_output --partial "outside secret"
	assert_failure
}
