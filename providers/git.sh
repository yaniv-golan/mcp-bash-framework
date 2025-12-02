#!/usr/bin/env bash
# Resource provider: fetch files from git:// repositories.

set -euo pipefail

if [ "${MCPBASH_ENABLE_GIT_PROVIDER:-false}" != "true" ]; then
	printf '%s\n' "git provider is disabled (set MCPBASH_ENABLE_GIT_PROVIDER=true to enable)" >&2
	exit 4
fi

if [ -n "${MCPBASH_HOME:-}" ] && [ -f "${MCPBASH_HOME}/lib/policy.sh" ]; then
	# shellcheck disable=SC1090
	. "${MCPBASH_HOME}/lib/policy.sh"
fi
if ! command -v mcp_policy_extract_host_from_url >/dev/null 2>&1; then
	mcp_policy_extract_host_from_url() {
		local url="$1"
		local host="${url#*://}"
		host="${host%%/*}"
		host="${host%%:*}"
		host="${host#\[}"
		host="${host%\]}"
		printf '%s' "${host}" | tr '[:upper:]' '[:lower:]'
	}
	mcp_policy_host_is_private() {
		local host="$1"
		case "${host}" in
		"" | localhost | 127.* | 0.0.0.0 | ::1 | "[::1]" | 10.* | 192.168.* | 172.1[6-9].* | 172.2[0-9].* | 172.3[0-1].* | 169.254.*)
			return 0
			;;
		esac
		return 1
	}
	mcp_policy_host_allowed() {
		return 0
	}
fi

uri="${1:-}"
if [ -z "${uri}" ] || [[ "${uri}" != git://* ]]; then
	printf '%s\n' "Invalid git URI" >&2
	exit 4
fi

host="$(mcp_policy_extract_host_from_url "${uri}")"
if [ -z "${host}" ]; then
	printf '%s\n' "git provider blocked internal/unsupported host" >&2
	exit 4
fi
if mcp_policy_host_is_private "${host}"; then
	printf '%s\n' "git provider blocked internal/unsupported host" >&2
	exit 4
fi
if ! mcp_policy_host_allowed "${host}" "${MCPBASH_GIT_ALLOW_HOSTS:-}" "${MCPBASH_GIT_DENY_HOSTS:-}"; then
	printf '%s\n' "git provider blocked internal/unsupported host" >&2
	exit 4
fi
if command -v getent >/dev/null 2>&1 && getent ahosts "${host}" >/dev/null 2>&1; then
	while read -r ip _; do
		case "${ip}" in
		10.* | 192.168.* | 172.1[6-9].* | 172.2[0-9].* | 172.3[0-1].* | 127.* | 169.254.* | ::1 | fe80:* | fc??:* | fd??:*)
			printf '%s\n' "git provider blocked internal/unsupported host" >&2
			exit 4
			;;
		esac
	done <<EOF
$(getent ahosts "${host}" | awk '{print $1}')
EOF
fi

if ! command -v git >/dev/null 2>&1; then
	printf '%s\n' "git command not available" >&2
	exit 4
fi

export GIT_TERMINAL_PROMPT=0
export GIT_ALLOW_PROTOCOL=git
export GIT_OPTIONAL_LOCKS=0

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

repo_dir="${workdir}/repo"
sha_regex='^[0-9a-fA-F]{7,64}$'
timeout_secs="${MCPBASH_GIT_TIMEOUT:-30}"
case "${timeout_secs}" in
'' | *[!0-9]*) timeout_secs=30 ;;
esac
if [ "${timeout_secs}" -gt 60 ]; then
	timeout_secs=60
fi
max_kb="${MCPBASH_GIT_MAX_KB:-51200}"
case "${max_kb}" in
'' | *[!0-9]*) max_kb=51200 ;;
esac
if [ "${max_kb}" -gt 1048576 ]; then
	max_kb=1048576
fi

run_git() {
	if command -v timeout >/dev/null 2>&1; then
		timeout -k 5 "${timeout_secs}" "$@"
	else
		"$@"
	fi
}

if [[ "${ref}" =~ ${sha_regex} ]]; then
	if ! run_git git init -q "${repo_dir}" >/dev/null 2>&1; then
		printf '%s\n' "Failed to initialize git repository" >&2
		exit 5
	fi
	if ! run_git git -C "${repo_dir}" remote add origin "${repo}" >/dev/null 2>&1; then
		printf '%s\n' "Failed to add remote ${repo}" >&2
		exit 5
	fi
	if ! run_git git -C "${repo_dir}" fetch --quiet --depth 1 origin "${ref}" >/dev/null 2>&1; then
		printf '%s\n' "Failed to fetch commit ${ref}" >&2
		exit 5
	fi
	if ! run_git git -C "${repo_dir}" checkout --quiet FETCH_HEAD >/dev/null 2>&1; then
		printf '%s\n' "Failed to checkout commit ${ref}" >&2
		exit 5
	fi
else
	if ! run_git git clone --depth 1 --shallow-submodules --branch "${ref}" "${repo}" "${repo_dir}" >/dev/null 2>&1; then
		printf '%s\n' "Failed to clone ${repo} @ ${ref}" >&2
		exit 5
	fi
fi

dir_size_kb="$(du -sk "${repo_dir}" 2>/dev/null | awk '{print $1}')"
dir_size_kb="${dir_size_kb:-0}"
if [ "${dir_size_kb}" -gt "${max_kb}" ]; then
	printf '%s\n' "Repository size exceeds limit (${max_kb} KB)" >&2
	exit 6
fi

target="${repo_dir}/${path}"
if [ ! -f "${target}" ]; then
	printf '%s\n' "File ${path} not found in repository" >&2
	exit 3
fi

cat "${target}"
