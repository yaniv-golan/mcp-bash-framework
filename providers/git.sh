#!/usr/bin/env bash
# Resource provider: fetch files from git:// repositories.

set -euo pipefail

uri="${1:-}"
if [ -z "${uri}" ] || [[ "${uri}" != git://* ]]; then
	printf '%s\n' "Invalid git URI" >&2
	exit 4
fi

if ! command -v git >/dev/null 2>&1; then
	printf '%s\n' "git command not available" >&2
	exit 4
fi

spec="${uri#git://}"
repo="git://${spec}"
ref="HEAD"
path=""
if [[ "${repo}" == *#* ]]; then
	repo_without_fragment="${repo%%#*}"
	fragment="${repo#*#}"
	repo="${repo_without_fragment}"
	if [[ "${fragment}" == *:* ]]; then
		ref="${fragment%%:*}"
		path="${fragment#*:}"
	else
		path="${fragment}"
	fi
else
	printf '%s\n' "git resources must include #ref:path" >&2
	exit 4
fi

path="${path#/}"
if [ -z "${path}" ]; then
	printf '%s\n' "git resource missing path" >&2
	exit 4
fi

tmp_root="${TMPDIR:-/tmp}"
workdir="$(mktemp -d "${tmp_root}/mcp-git-resource.XXXXXX")"
cleanup() {
	rm -rf "${workdir}"
}
trap cleanup EXIT

if ! git clone --depth 1 --branch "${ref}" "${repo}" "${workdir}/repo" >/dev/null 2>&1; then
	printf '%s\n' "Failed to clone ${repo} @ ${ref}" >&2
	exit 5
fi

target="${workdir}/repo/${path}"
if [ ! -f "${target}" ]; then
	printf '%s\n' "File ${path} not found in repository" >&2
	exit 3
fi

cat "${target}"
