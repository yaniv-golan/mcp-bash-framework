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
# Set by check_allowed to the canonical root that contains the path (empty when
# the root is "/" or is the file itself); the verified read re-checks it by inode.
matched_root=""
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
			matched_root=""
			break
		fi
		if [ "${check_root}" = "/" ]; then
			allowed=true
			matched_root=""
			break
		fi
		local prefix="${check_root}/"
		if [ "${candidate:0:${#prefix}}" = "${prefix}" ]; then
			allowed=true
			matched_root="${check_root}"
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

# Read through the verified-open helper: it pins the parent directory and checks
# by inode that it is inside the matched root, opens the file once, and confirms
# the open descriptor is the regular file that was checked before streaming it.
# A symlink swapped in at any point (file or parent directory) is refused.
file_read_lib=""
if [ -n "${MCPBASH_HOME:-}" ] && [ -f "${MCPBASH_HOME}/lib/file_read.sh" ]; then
	file_read_lib="${MCPBASH_HOME}/lib/file_read.sh"
else
	self_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd -P)" || self_dir=""
	if [ -n "${self_dir}" ] && [ -f "${self_dir}/../lib/file_read.sh" ]; then
		file_read_lib="${self_dir}/../lib/file_read.sh"
	fi
fi
if [ -z "${file_read_lib}" ]; then
	printf '%s\n' "file provider: lib/file_read.sh not found; refusing unverified read" >&2
	exit 2
fi
# shellcheck source=lib/file_read.sh
# shellcheck disable=SC1091
. "${file_read_lib}"

status=0
mcp_file_read_verified "${path}" "" "${matched_root}" || status=$?
case "${status}" in
0) exit 0 ;;
3) exit 3 ;;
5)
	printf '%s\n' "file provider: cannot verify the opened file on this platform (needs stat and /dev/fd); refusing" >&2
	exit 2
	;;
*) exit 2 ;;
esac
