#!/usr/bin/env bash
# Resource provider: fetch content from HTTPS endpoints.

set -euo pipefail

uri="${1:-}"
if [ -z "${uri}" ] || [[ "${uri}" != https://* ]]; then
	printf '%s\n' "HTTPS provider requires https:// URI" >&2
	exit 4
fi

if command -v curl >/dev/null 2>&1; then
	if ! curl -fsSL "${uri}"; then
		exit 5
	fi
	exit 0
fi

if command -v wget >/dev/null 2>&1; then
	if ! wget -q -O - "${uri}"; then
		exit 5
	fi
	exit 0
fi

printf '%s\n' "Neither curl nor wget available for HTTPS provider" >&2
exit 4
