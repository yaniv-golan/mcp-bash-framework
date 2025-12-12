#!/usr/bin/env bash
# Resource provider: fetch files from git:// repositories.

set -euo pipefail

mcp_git_log_block() {
	local host="$1"
	if command -v mcp_logging_warning >/dev/null 2>&1; then
		mcp_logging_warning "mcp.git" "Blocked host ${host}"
	else
		printf '%s\n' "git provider blocked host ${host}" >&2
	fi
}

mcp_git_load_policy() {
	# Prefer shared policy helpers. If unavailable, fall back to local versions
	# that STILL enforce allow/deny lists (never fail-open).
	local sourced="false"
	if [ -n "${MCPBASH_HOME:-}" ] && [ -f "${MCPBASH_HOME}/lib/policy.sh" ]; then
		# shellcheck disable=SC1090
		. "${MCPBASH_HOME}/lib/policy.sh" && sourced="true" || true
	fi
	if [ "${sourced}" != "true" ]; then
		local self_dir=""
		self_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd -P 2>/dev/null || true)"
		if [ -n "${self_dir}" ] && [ -f "${self_dir%/}/../lib/policy.sh" ]; then
			# shellcheck disable=SC1090,SC1091
			. "${self_dir%/}/../lib/policy.sh" && sourced="true" || true
		fi
	fi

	if ! command -v mcp_policy_normalize_host >/dev/null 2>&1; then
		mcp_policy_normalize_host() {
			local host="$1"
			if [ -z "${host}" ]; then
				return 1
			fi
			if [ "${host#\[}" != "${host}" ]; then
				host="${host#[}"
				host="${host%]}"
			fi
			printf '%s' "${host}" | tr '[:upper:]' '[:lower:]'
		}
	fi

	if ! command -v mcp_policy_host_allowed >/dev/null 2>&1; then
		mcp_policy_host_match_list() {
			local host="$1"
			local list="$2"
			local token
			list="${list//,/ }"
			for token in ${list}; do
				[ -z "${token}" ] && continue
				if [ "${host}" = "$(mcp_policy_normalize_host "${token}")" ]; then
					return 0
				fi
			done
			return 1
		}

		mcp_policy_host_allowed() {
			local host="$1"
			local allow_list="$2"
			local deny_list="$3"
			if [ -n "${deny_list}" ] && mcp_policy_host_match_list "${host}" "${deny_list}"; then
				return 1
			fi
			if [ -n "${allow_list}" ]; then
				if mcp_policy_host_match_list "${host}" "${allow_list}"; then
					return 0
				fi
				return 1
			fi
			return 0
		}
	fi
}

mcp_git_normalize_path() {
	local target="$1"
	# Security requirement: to prevent symlink-based escapes, canonicalization must
	# resolve symlinks (physical path). If we cannot do that reliably, fail closed.
	#
	# Note: mcp_path_normalize may fall back to a logical collapse-only mode when
	# the host lacks realpath/readlink -f. We intentionally do NOT accept that
	# mode here.
	if command -v realpath >/dev/null 2>&1; then
		realpath "${target}" 2>/dev/null && return 0
	fi
	if command -v readlink >/dev/null 2>&1; then
		if readlink -f / >/dev/null 2>&1; then
			readlink -f "${target}" 2>/dev/null && return 0
		fi
	fi
	return 1
}

mcp_git_available_kb() {
	local target_dir="$1"
	if command -v df >/dev/null 2>&1; then
		df -Pk "${target_dir}" 2>/dev/null | awk 'NR==2 {print $4}'
	fi
}

if [ "${MCPBASH_ENABLE_GIT_PROVIDER:-false}" != "true" ]; then
	printf '%s\n' "git provider is disabled (set MCPBASH_ENABLE_GIT_PROVIDER=true to enable)" >&2
	exit 4
fi

mcp_git_load_policy
if ! command -v mcp_policy_extract_host_from_url >/dev/null 2>&1; then
	mcp_policy_extract_host_from_url() {
		local url="$1"
		# Best-effort URL host extraction for fallback mode. This must strip
		# userinfo (user:pass@) to avoid SSRF bypasses.
		local authority="${url#*://}"
		authority="${authority%%/*}"
		authority="${authority%%\?*}"
		authority="${authority%%\#*}"
		authority="${authority##*@}"
		local host=""
		case "${authority}" in
		\[*\]*)
			host="${authority#\[}"
			host="${host%%\]*}"
			;;
		*)
			host="${authority%%:*}"
			;;
		esac
		printf '%s' "${host}" | tr '[:upper:]' '[:lower:]'
	}
	mcp_policy_resolve_ips() {
		local host="$1"
		local resolved=""
		if command -v getent >/dev/null 2>&1; then
			resolved="$(getent ahosts "${host}" 2>/dev/null | awk '{print $1}')"
		fi
		if [ -z "${resolved}" ] && command -v dig >/dev/null 2>&1; then
			resolved="$(dig +short "${host}" A AAAA 2>/dev/null | sed '/^$/d')"
		fi
		if [ -z "${resolved}" ] && command -v host >/dev/null 2>&1; then
			resolved="$(host "${host}" 2>/dev/null | awk '/has address/{print $4}/IPv6 address/{print $5}')"
		fi
		if [ -z "${resolved}" ] && command -v nslookup >/dev/null 2>&1; then
			resolved="$(nslookup "${host}" 2>/dev/null | awk '/^Address: /{print $2}' | tail -n +2)"
		fi
		resolved="$(printf '%s\n' "${resolved}" | sed '/^$/d' | sort -u)"
		if [ -z "${resolved}" ]; then
			return 1
		fi
		printf '%s\n' "${resolved}"
	}
	mcp_policy_host_is_private() {
		local host="$1"
		local resolved_ips
		case "${host}" in
		"" | localhost | 127.* | 0.0.0.0 | ::1 | "[::1]" | 10.* | 192.168.* | 172.1[6-9].* | 172.2[0-9].* | 172.3[0-1].* | 169.254.*)
			return 0
			;;
		esac
		if resolved_ips="$(mcp_policy_resolve_ips "${host}")"; then
			while IFS= read -r ip; do
				[ -z "${ip}" ] && continue
				case "${ip}" in
				10.* | 192.168.* | 172.1[6-9].* | 172.2[0-9].* | 172.3[0-1].* | 127.* | 169.254.* | ::1 | fe80:* | fc??:* | fd??:* | ::ffff:127.* | ::ffff:10.* | ::ffff:192.168.* | ::ffff:172.1[6-9].* | ::ffff:172.2[0-9].* | ::ffff:172.3[0-1].* | ::ffff:169.254.* | ::ffff:0:0:127.* | ::ffff:0:0:10.* | ::ffff:0:0:192.168.* | ::ffff:0:0:172.1[6-9].* | ::ffff:0:0:172.2[0-9].* | ::ffff:0:0:172.3[0-1].* | ::ffff:0:0:169.254.*)
					return 0
					;;
				esac
			done <<EOF
${resolved_ips}
EOF
		fi
		return 1
	}
	mcp_policy_host_allowed() {
		# Enforce allow/deny even in fallback mode (never fail-open).
		local host="$1"
		local allow_list="$2"
		local deny_list="$3"
		if [ -n "${deny_list}" ] && mcp_policy_host_match_list "${host}" "${deny_list}"; then
			return 1
		fi
		if [ -n "${allow_list}" ]; then
			if mcp_policy_host_match_list "${host}" "${allow_list}"; then
				return 0
			fi
			return 1
		fi
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
	mcp_git_log_block "<empty>"
	exit 4
fi
if mcp_policy_host_is_private "${host}"; then
	mcp_git_log_block "${host}"
	exit 4
fi
if [ -z "${MCPBASH_GIT_ALLOW_HOSTS:-}" ] && [ "${MCPBASH_GIT_ALLOW_ALL:-false}" != "true" ]; then
	printf '%s\n' "git provider requires MCPBASH_GIT_ALLOW_HOSTS or MCPBASH_GIT_ALLOW_ALL=true when enabled" >&2
	mcp_git_log_block "${host}"
	exit 4
fi
if ! mcp_policy_host_allowed "${host}" "${MCPBASH_GIT_ALLOW_HOSTS:-}" "${MCPBASH_GIT_DENY_HOSTS:-}"; then
	mcp_git_log_block "${host}"
	exit 4
fi
if command -v getent >/dev/null 2>&1 && getent ahosts "${host}" >/dev/null 2>&1; then
	while read -r ip _; do
		case "${ip}" in
		10.* | 192.168.* | 172.1[6-9].* | 172.2[0-9].* | 172.3[0-1].* | 127.* | 169.254.* | ::1 | fe80:* | fc??:* | fd??:*)
			mcp_git_log_block "${host}"
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

available_kb="$(mcp_git_available_kb "${workdir}")"
required_kb=$((max_kb + 1024))
case "${available_kb}" in
'' | *[!0-9]*) available_kb=0 ;;
esac
if [ "${available_kb}" -gt 0 ] && [ "${available_kb}" -lt "${required_kb}" ]; then
	printf '%s\n' "Insufficient disk space for git provider (need at least ${required_kb} KB free)" >&2
	exit 5
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

repo_dir_canonical="$(mcp_git_normalize_path "${repo_dir}" 2>/dev/null || true)"
target="$(mcp_git_normalize_path "${repo_dir}/${path}" 2>/dev/null || true)"
if [ -z "${repo_dir_canonical}" ] || [ -z "${target}" ]; then
	printf '%s\n' "Failed to canonicalize repository paths (requires realpath or readlink -f for safe symlink resolution)" >&2
	exit 5
fi
case "${target}" in
"${repo_dir_canonical}" | "${repo_dir_canonical}"/*) ;;
*)
	printf '%s\n' "File ${path} escapes repository root" >&2
	exit 3
	;;
esac
if [ ! -f "${target}" ]; then
	printf '%s\n' "File ${path} not found in repository" >&2
	exit 3
fi

cat "${target}"
