#!/usr/bin/env bash
# Default file provider.

set -euo pipefail

uri="$1"
path="${uri#file://}"
case "${path}" in
[A-Za-z]:/*)
	drive="${path%%:*}"
	rest="${path#*:}"
	if [ -n "${BASH_VERSINFO:-}" ] && [ "${BASH_VERSINFO[0]}" -ge 4 ]; then
		path="/${drive,,}${rest}"
	else
		case "${drive}" in
		[A-Z])
			lower_drive=$(printf '%s' "${drive}" | tr '[:upper:]' '[:lower:]')
			path="/${lower_drive}${rest}"
			;;
		*)
			path="/${drive}${rest}"
			;;
		esac
	fi
	;;
esac
path="${path//\\//}"
if [ -z "${MSYS2_ARG_CONV_EXCL:-}" ]; then
	MSYS2_ARG_CONV_EXCL="*"
fi

normalize_path() {
	local target="$1"
	local normalized=""
	if command -v realpath >/dev/null 2>&1; then
		normalized="$(realpath "${target}" 2>/dev/null || true)"
	fi
	if [ -z "${normalized}" ]; then
		normalized="$(
			cd "$(dirname "${target}")" 2>/dev/null || exit 1
			printf '%s/%s\n' "$(pwd -P)" "$(basename "${target}")"
		)"
	fi
	# On Windows/MSYS, canonicalize via cygpath to expand 8.3 short names (e.g., RUNNER~1 -> runneradmin)
	# and resolve MSYS virtual paths (e.g., /tmp -> /c/Users/.../Temp). The -l flag expands short names.
	if [[ "${OSTYPE:-}" == msys* || "${OSTYPE:-}" == cygwin* ]] && command -v cygpath >/dev/null 2>&1; then
		local win_path unix_path
		win_path="$(cygpath -w -l "${normalized}" 2>/dev/null || true)"
		if [ -n "${win_path}" ]; then
			unix_path="$(cygpath -u "${win_path}" 2>/dev/null || true)"
			[ -n "${unix_path}" ] && normalized="${unix_path}"
		fi
	fi
	printf '%s' "${normalized}"
}

path="$(normalize_path "${path}" 2>/dev/null || true)"
if [ -z "${path}" ]; then
	# Path could not be normalized (likely missing); treat as not found.
	exit 3
fi
roots_input="${MCP_RESOURCES_ROOTS:-${MCPBASH_RESOURCES_DIR:-${MCPBASH_PROJECT_ROOT:-}}}"
check_allowed() {
	local candidate="$1"
	local allowed=false
	local check_root=""
	while IFS= read -r root; do
		[ -z "${root}" ] && continue
		check_root="$(normalize_path "${root}" 2>/dev/null || true)"
		[ -z "${check_root}" ] && continue
		# SECURITY: containment checks must be literal (not shell patterns).
		# Paths can contain glob metacharacters like []?* which would turn a
		# prefix check into a wildcard match and allow root bypasses.
		if [ "${check_root}" != "/" ]; then
			check_root="${check_root%/}"
		fi
		if [ "${candidate}" = "${check_root}" ]; then
			allowed=true
			break
		fi
		if [ "${check_root}" = "/" ]; then
			allowed=true
			break
		fi
		local prefix="${check_root}/"
		if [ "${candidate:0:${#prefix}}" = "${prefix}" ]; then
			allowed=true
			break
		fi
	done <<<"$(printf '%s\n' "${roots_input}" | tr ':' '\n')"
	if [ "${allowed}" != true ]; then
		return 1
	fi
	return 0
}

if ! check_allowed "${path}"; then
	# Fail closed if no roots were usable or path is outside allowed roots.
	exit 2
fi
if [ ! -f "${path}" ]; then
	exit 3
fi

# Reject symlinks up front; prevents swapping a validated path to an external target.
if [ -L "${path}" ]; then
	exit 2
fi

if ! exec 3<"${path}"; then
	exit 3
fi

if [ -L "${path}" ]; then
	exec 3<&-
	exit 2
fi
cat <&3
exec 3<&-
