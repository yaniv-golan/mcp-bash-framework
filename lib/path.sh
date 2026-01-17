#!/usr/bin/env bash
# Cross-platform path normalization helpers (Bash 3.2+).
# Fallback chain: realpath -m -> realpath -> readlink -f -> manual collapse.
# Manual collapse resolves "."/".." relative to $PWD without requiring the path
# to exist. Default mode collapses then resolves symlinks when possible (physical).

set -euo pipefail

# Collapse . and .. components. For relative input, collapse relative to $PWD
# and return an absolute path; empty input becomes "." (relative result) before
# absolute expansion. Double slashes are squashed. Clamps at root for leading ..
mcp_path_collapse() {
	local raw="${1-}"
	[ -z "${raw}" ] && raw="."

	if [[ "${raw}" != /* ]]; then
		local base="${PWD:-.}"
		raw="${base%/}/${raw}"
	fi

	# squash multiple slashes
	raw="$(printf '%s' "${raw}" | tr -s '/')"

	# read -a requires bash (not zsh); arrays are Bash 3.2-compatible.
	IFS='/' read -r -a parts <<<"${raw}"
	local -a stack=() # Bash 3.2 arrays are ok; prefer array for clarity
	local comp
	for comp in "${parts[@]}"; do
		case "${comp}" in
		"" | ".") continue ;;
		"..")
			if [ "${#stack[@]}" -gt 0 ]; then
				unset "stack[${#stack[@]}-1]"
			fi
			;;
		*)
			stack+=("${comp}")
			;;
		esac
	done

	local joined="/"
	if [ "${#stack[@]}" -gt 0 ]; then
		local idx
		for idx in "${!stack[@]}"; do
			joined="${joined%/}/${stack[$idx]}"
		done
	fi

	[ -z "${joined}" ] && joined="/"
	printf '%s' "${joined}"
}

# Normalize a path with optional mode:
#   --physical (default): collapse, then resolve symlinks when resolver exists.
#   --logical: collapse only (no final symlink resolution).
# Empty input yields $PWD when a resolver exists; otherwise collapse result.
mcp_path_normalize() {
	local mode="physical"
	while [ "$#" -gt 0 ]; do
		case "$1" in
		--physical) mode="physical" ;;
		--logical) mode="logical" ;;
		--)
			shift
			break
			;;
		-*) break ;;
		*) break ;;
		esac
		shift
	done

	local raw="${1-}"
	[ -z "${raw}" ] && raw="."

	local resolver=""
	local realpath_supports_m="false"
	if command -v realpath >/dev/null 2>&1; then
		if realpath -m "/" >/dev/null 2>&1; then
			realpath_supports_m="true"
		fi
	fi

	local normalized=""
	if [ "${realpath_supports_m}" = "true" ]; then
		normalized="$(realpath -m "${raw}" 2>/dev/null || true)"
		resolver="realpath -m"
	elif command -v realpath >/dev/null 2>&1; then
		normalized="$(realpath "${raw}" 2>/dev/null || true)"
		resolver="realpath"
	elif command -v readlink >/dev/null 2>&1; then
		if readlink -f / >/dev/null 2>&1; then
			normalized="$(readlink -f "${raw}" 2>/dev/null || true)"
			resolver="readlink -f"
		fi
	fi

	if [ -z "${normalized}" ]; then
		normalized="$(mcp_path_collapse "${raw}")"
		resolver="collapse"
	fi

	if [ "${mode}" = "physical" ]; then
		if [ "${resolver}" = "collapse" ]; then
			if [ "${realpath_supports_m}" = "true" ]; then
				local tmp
				tmp="$(realpath -m "${normalized}" 2>/dev/null || true)"
				[ -n "${tmp}" ] && normalized="${tmp}" && resolver="collapse+realpath -m"
			elif command -v realpath >/dev/null 2>&1; then
				local tmp
				tmp="$(realpath "${normalized}" 2>/dev/null || true)"
				[ -n "${tmp}" ] && normalized="${tmp}" && resolver="collapse+realpath"
			elif command -v readlink >/dev/null 2>&1; then
				if readlink -f / >/dev/null 2>&1; then
					local tmp
					tmp="$(readlink -f "${normalized}" 2>/dev/null || true)"
					[ -n "${tmp}" ] && normalized="${tmp}" && resolver="collapse+readlink -f"
				fi
			fi
		fi
	fi

	[ -z "${normalized}" ] && normalized="${raw}"
	if [[ "${normalized}" != "/" ]]; then
		normalized="${normalized%/}"
		[ -z "${normalized}" ] && normalized="/"
	fi

	# Normalize drive letter case for Windows/MSYS-style paths.
	# Examples: /c/Users -> /C/Users, c:\tmp -> C:\tmp
	if [[ "${normalized}" =~ ^/([a-z])(/.*)?$ ]]; then
		local drive="${BASH_REMATCH[1]}"
		local rest="${BASH_REMATCH[2]:-}"
		local drive_upper
		drive_upper="$(printf '%s' "${drive}" | tr '[:lower:]' '[:upper:]')"
		normalized="/${drive_upper}${rest}"
	elif [[ "${normalized}" =~ ^([a-z]): ]]; then
		local drive_letter="${BASH_REMATCH[1]}"
		local drive_upper
		drive_upper="$(printf '%s' "${drive_letter}" | tr '[:lower:]' '[:upper:]')"
		normalized="${drive_upper}${normalized:1}"
	fi

	# On Windows/MSYS, canonicalize paths through Windows format and back to Unix format.
	# This resolves: (1) MSYS virtual paths like /tmp -> /c/Users/.../Temp,
	# (2) 8.3 short names like RUNNER~1 -> runneradmin, ensuring consistent path comparison.
	# The -l flag expands 8.3 short names to long names.
	if [[ "${OSTYPE:-}" == msys* || "${OSTYPE:-}" == cygwin* ]] && command -v cygpath >/dev/null 2>&1; then
		local win_path unix_path
		win_path="$(cygpath -w -l "${normalized}" 2>/dev/null || true)"
		if [ -n "${win_path}" ]; then
			unix_path="$(cygpath -u "${win_path}" 2>/dev/null || true)"
			[ -n "${unix_path}" ] && normalized="${unix_path}"
		fi
	fi

	if [ "${MCP_PATH_DEBUG:-0}" = "1" ]; then
		printf 'mcp_path_normalize: %s -> %s\n' "${raw}" "${resolver}" >&2
	fi
	printf '%s' "${normalized}"
}
