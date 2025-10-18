#!/usr/bin/env bash
# Spec §8/§12 default file provider.

set -euo pipefail

uri="$1"
path="${uri#file://}"
case "${path}" in
[A-Za-z]:/*)
	drive="${path%%:*}"
	rest="${path#*:}"
	path="/${drive,,}${rest}"
	;;
esac
path="${path//\\//}"
if [ -z "${MSYS2_ARG_CONV_EXCL:-}" ]; then
	MSYS2_ARG_CONV_EXCL="*"
fi

normalize_path() {
	local target="$1"
	if command -v python3 >/dev/null 2>&1; then
		python3 - "$target" <<'PY'
import os, sys
print(os.path.realpath(sys.argv[1]))
PY
		return
	fi
	if command -v python >/dev/null 2>&1; then
		python - "$target" <<'PY'
import os, sys
print(os.path.realpath(sys.argv[1]))
PY
		return
	fi
	if command -v realpath >/dev/null 2>&1; then
		realpath "${target}"
		return
	fi
	(
		cd "$(dirname "${target}")" 2>/dev/null || exit 1
		printf '%s/%s\n' "$(pwd)" "$(basename "${target}")"
	)
}

path="$(normalize_path "${path}")"
roots="${MCP_RESOURCES_ROOTS:-${MCPBASH_ROOT}}"
allowed=false
for root in ${roots}; do
	check_root="$(normalize_path "${root}")"
	case "${path}" in
	"${check_root}" | "${check_root}"/*)
		allowed=true
		break
		;;
	esac
done
if [ "${allowed}" != true ]; then
	printf '%s' "" >&2
	exit 2
fi
if [ ! -f "${path}" ]; then
	exit 3
fi
cat "${path}"
