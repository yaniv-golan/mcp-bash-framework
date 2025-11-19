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
	if command -v realpath >/dev/null 2>&1; then
		realpath "${target}"
		return
	fi
	(
		cd "$(dirname "${target}")" 2>/dev/null || exit 1
		printf '%s/%s\n' "$(pwd -P)" "$(basename "${target}")"
	)
}

path="$(normalize_path "${path}")"
roots_input="${MCP_RESOURCES_ROOTS:-${MCPBASH_ROOT}}"
allowed=false
while IFS= read -r root; do
	[ -z "${root}" ] && continue
	check_root="$(normalize_path "${root}")"
	case "${path}" in
	"${check_root}" | "${check_root}"/*)
		allowed=true
		break
		;;
	esac
done <<<"$(printf '%s\n' "${roots_input}" | tr ':' '\n')"
if [ "${allowed}" != true ]; then
	printf '%s' "" >&2
	exit 2
fi
if [ ! -f "${path}" ]; then
	exit 3
fi
cat "${path}"
