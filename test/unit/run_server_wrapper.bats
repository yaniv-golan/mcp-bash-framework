#!/usr/bin/env bats
# Unit layer: run-server.sh wrapper (bundle template and the inline fallback in
# lib/cli/embed.sh) clears unexpanded ${user_config.*} placeholders.

load '../../node_modules/bats-support/load'
load '../../node_modules/bats-assert/load'
load '../common/fixtures'

bats_require_minimum_version 1.5.0

# Build a server dir holding a stub framework binary that just prints its env.
# $1 = "template" or "fallback" (no template available, inline copy is used)
make_wrapper_dir() {
	local mode="$1"
	WRAP_DIR="${BATS_TEST_TMPDIR}/wrap-${mode}"
	mkdir -p "${WRAP_DIR}/.mcp-bash/bin"
	printf '%s\n' '#!/bin/sh' 'echo STUB-RAN' 'env' >"${WRAP_DIR}/.mcp-bash/bin/mcp-bash"
	chmod +x "${WRAP_DIR}/.mcp-bash/bin/mcp-bash"

	local home="${MCPBASH_HOME}"
	if [ "${mode}" = "fallback" ]; then
		home="${BATS_TEST_TMPDIR}/nohome"
		mkdir -p "${home}"
	fi
	# shellcheck disable=SC1091
	MCPBASH_HOME="${home}" bash -c ". '${MCPBASH_HOME}/lib/cli/embed.sh' && mcp_embed_generate_wrapper '${WRAP_DIR}'" >/dev/null
	[ -x "${WRAP_DIR}/run-server.sh" ] || chmod +x "${WRAP_DIR}/run-server.sh"
}

run_wrapper() {
	local shell_bin=""
	local -a vars=()
	local arg
	for arg in "$@"; do
		case "${arg}" in
		WRAP_BASH=*) shell_bin="${arg#WRAP_BASH=}" ;;
		*) vars+=("${arg}") ;;
		esac
	done
	env -i PATH="${PATH}" HOME="${BATS_TEST_TMPDIR}" MCPB_SKIP_LOGIN_SHELL=1 "${vars[@]}" ${shell_bin:+"${shell_bin}"} "${WRAP_DIR}/run-server.sh"
}

check_mode() {
	local mode="$1"
	make_wrapper_dir "${mode}"

	# Debug: the name is reported, values never are.
	run --separate-stderr run_wrapper MCPBASH_LOG_LEVEL=debug 'EMPTY_KEY=${user_config.api_key}' 'KEEP_ME=real-value-1'
	assert_success
	assert_contains_text() { case "$1" in *"$2"*) return 0 ;; *) return 1 ;; esac; }
	assert_contains_text "${stderr}" "EMPTY_KEY"
	if assert_contains_text "${stderr}" 'user_config'; then
		# Only the generic description may mention user_config; never the ${...} placeholder.
		if assert_contains_text "${stderr}" '${user_config.api_key}'; then
			printf 'placeholder leaked on stderr: %s\n' "${stderr}" >&2
			return 1
		fi
	fi
	if assert_contains_text "${stderr}" "real-value-1"; then
		printf 'other value leaked on stderr: %s\n' "${stderr}" >&2
		return 1
	fi
	[ "$(printf '%s\n' "${stderr}" | grep -c 'EMPTY_KEY')" -eq 1 ]
	# The variable is gone, the other one survives.
	assert_contains_text "${output}" "STUB-RAN"
	if assert_contains_text "${output}" "EMPTY_KEY"; then return 1; fi
	assert_contains_text "${output}" "KEEP_ME=real-value-1"

	# Not debug: no line at all.
	run --separate-stderr run_wrapper 'EMPTY_KEY=${user_config.api_key}'
	assert_success
	if assert_contains_text "${stderr}" "EMPTY_KEY"; then return 1; fi
	if assert_contains_text "${output}" "EMPTY_KEY"; then return 1; fi

	# Debug but nothing to clear: no line.
	run --separate-stderr run_wrapper MCPBASH_LOG_LEVEL=debug 'KEEP_ME=real-value-1'
	assert_success
	[ -z "${stderr}" ]
}

@test "run-server template: debug logs cleared placeholder names only" {
	check_mode template
}

@test "run-server inline fallback: debug logs cleared placeholder names only" {
	check_mode fallback
}

@test "run-server template: works under /bin/bash (3.2 on macOS)" {
	make_wrapper_dir template
	run --separate-stderr run_wrapper MCPBASH_LOG_LEVEL=debug 'EMPTY_KEY=${user_config.k}' WRAP_BASH=/bin/bash
	assert_success
	[[ "${stderr}" == *EMPTY_KEY* ]]
	[[ "${output}" != *EMPTY_KEY* ]]
}
