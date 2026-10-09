#!/usr/bin/env bash
# Resource provider: fetch files from git+https:// repositories.
#
# Address checks live in lib/policy.sh (the single private-range list). The
# provider refuses to fetch if that library cannot be loaded. Hostnames are
# resolved once, every answer is vetted, and git's libcurl is pinned to the
# vetted addresses with http.curloptResolve (git >= 2.37); redirects are off.

set -euo pipefail

MCP_GIT_POLICY_FUNCS="mcp_policy_extract_host_from_url mcp_policy_extract_port_from_url mcp_policy_host_is_noncanonical_ip_literal mcp_policy_ip_is_private mcp_policy_host_is_ip_literal mcp_policy_hostname_is_valid mcp_policy_resolve_vetted_ips mcp_policy_host_allowed mcp_policy_proxy_configured"
# First git release with http.curloptResolve.
MCP_GIT_PIN_MIN_MAJOR=2
MCP_GIT_PIN_MIN_MINOR=37

mcp_git_log_block() {
	local host="$1"
	if command -v mcp_logging_warning >/dev/null 2>&1; then
		mcp_logging_warning "mcp.git" "Blocked host ${host}"
	else
		printf '%s\n' "git provider blocked host ${host}" >&2
	fi
}

mcp_git_load_policy() {
	# Source the shared policy helpers. There is deliberately no local fallback
	# copy: a second range list is how the copies diverged. Returns 1 if any
	# required helper is missing, and the caller refuses to fetch.
	local sourced="false"
	if [ -n "${MCPBASH_HOME:-}" ] && [ -f "${MCPBASH_HOME}/lib/policy.sh" ]; then
		# shellcheck disable=SC1090,SC1091
		if . "${MCPBASH_HOME}/lib/policy.sh"; then sourced="true"; fi
	fi
	if [ "${sourced}" != "true" ]; then
		local self_dir=""
		self_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd -P 2>/dev/null)" || true
		if [ -n "${self_dir}" ] && [ -f "${self_dir%/}/../lib/policy.sh" ]; then
			# shellcheck disable=SC1090,SC1091
			. "${self_dir%/}/../lib/policy.sh" || true
		fi
	fi
	local fn
	for fn in ${MCP_GIT_POLICY_FUNCS}; do
		command -v "${fn}" >/dev/null 2>&1 || return 1
	done
	return 0
}

mcp_git_supports_pinning() {
	# True when the installed git understands http.curloptResolve.
	local version major minor rest
	version="$(git --version 2>/dev/null)" || return 1
	version="${version#git version }"
	major="${version%%.*}"
	rest="${version#*.}"
	minor="${rest%%[!0-9]*}"
	case "${major}" in '' | *[!0-9]*) return 1 ;; esac
	case "${minor}" in '' | *[!0-9]*) return 1 ;; esac
	if [ "${major}" -gt "${MCP_GIT_PIN_MIN_MAJOR}" ]; then
		return 0
	fi
	[ "${major}" -eq "${MCP_GIT_PIN_MIN_MAJOR}" ] && [ "${minor}" -ge "${MCP_GIT_PIN_MIN_MINOR}" ]
}

mcp_git_normalize_path() {
	local target="$1"
	local normalized=""
	# Security requirement: to prevent symlink-based escapes, canonicalization must
	# resolve symlinks (physical path). If we cannot do that reliably, fail closed.
	#
	# Note: mcp_path_normalize may fall back to a logical collapse-only mode when
	# the host lacks realpath/readlink -f. We intentionally do NOT accept that
	# mode here.
	if command -v realpath >/dev/null 2>&1; then
		normalized="$(realpath "${target}" 2>/dev/null || true)"
	fi
	if [ -z "${normalized}" ] && command -v readlink >/dev/null 2>&1; then
		if readlink -f / >/dev/null 2>&1; then
			normalized="$(readlink -f "${target}" 2>/dev/null || true)"
		fi
	fi
	if [ -z "${normalized}" ]; then
		return 1
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

if ! mcp_git_load_policy; then
	printf '%s\n' "git provider requires lib/policy.sh (set MCPBASH_HOME); refusing to fetch" >&2
	exit 4
fi

uri="${1:-}"
if [ -z "${uri}" ] || [[ "${uri}" != git+https://* ]]; then
	printf '%s\n' "Invalid git+https URI" >&2
	exit 4
fi

# Reject embedded credentials in the authority portion. Even if host policy
# strips userinfo for allow/deny checks, passing userinfo through to git would
# risk leaking secrets via process listings/logs.
authority="${uri#*://}"
authority="${authority%%/*}"
authority="${authority%%\?*}"
authority="${authority%%\#*}"
if [[ "${authority}" == *"@"* ]]; then
	printf '%s\n' "git provider refuses userinfo in URI" >&2
	exit 4
fi

host="$(mcp_policy_extract_host_from_url "${uri}")" || host=""
if ! port="$(mcp_policy_extract_port_from_url "${uri}" 443)"; then
	mcp_git_log_block "${host:-<empty>}"
	printf '%s\n' "git provider requires a decimal port 1-65535 without leading zeros" >&2
	exit 4
fi
if [ -z "${host}" ]; then
	mcp_git_log_block "<empty>"
	exit 4
fi
if mcp_policy_host_is_noncanonical_ip_literal "${host}" || mcp_policy_ip_is_private "${host}"; then
	mcp_git_log_block "${host}"
	exit 4
fi
host_is_literal="false"
if mcp_policy_host_is_ip_literal "${host}"; then
	host_is_literal="true"
elif ! mcp_policy_hostname_is_valid "${host}"; then
	mcp_git_log_block "${host}"
	printf '%s\n' "git provider requires an ASCII hostname without a trailing dot or percent-encoding" >&2
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

if ! command -v git >/dev/null 2>&1; then
	printf '%s\n' "git command not available" >&2
	exit 4
fi

# Config passed to every git invocation. Redirects are never followed: a
# redirect target would not have been vetted or pinned.
git_cfg=(-c http.followRedirects=false)
if [ "${host_is_literal}" != "true" ]; then
	if ! mcp_git_supports_pinning; then
		printf '%s\n' "git provider requires git >= ${MCP_GIT_PIN_MIN_MAJOR}.${MCP_GIT_PIN_MIN_MINOR} (http.curloptResolve) to pin DNS; refusing to fetch" >&2
		exit 4
	fi
	vet_rc=0
	vetted="$(mcp_policy_resolve_vetted_ips "${host}")" || vet_rc=$?
	case "${vet_rc}" in
	0) ;;
	2)
		mcp_git_log_block "${host}"
		exit 4
		;;
	*)
		printf '%s\n' "git provider: unable to resolve ${host}; refusing an unpinned fetch" >&2
		exit 5
		;;
	esac
	pin_addrs=""
	while IFS= read -r ip; do
		[ -n "${ip}" ] || continue
		case "${ip}" in *:*) ip="[${ip}]" ;; esac
		pin_addrs="${pin_addrs:+${pin_addrs},}${ip}"
	done <<EOF
${vetted}
EOF
	if [ -z "${pin_addrs}" ]; then
		printf '%s\n' "git provider: unable to resolve ${host}; refusing an unpinned fetch" >&2
		exit 5
	fi
	# The host:port entry pins the name git's libcurl looks up; "*:port" also
	# catches any spelling of the host libcurl might derive differently. It
	# is left out behind a proxy, where it would also capture the proxy's name.
	git_cfg+=(-c "http.curloptResolve=${host}:${port}:${pin_addrs}")
	if ! mcp_policy_proxy_configured; then
		git_cfg+=(-c "http.curloptResolve=*:${port}:${pin_addrs}")
	fi
fi

export GIT_TERMINAL_PROMPT=0
export GIT_ALLOW_PROTOCOL=https
export GIT_OPTIONAL_LOCKS=0

repo="${uri#git+}"
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
	if ! run_git git "${git_cfg[@]}" init -q "${repo_dir}" >/dev/null 2>&1; then
		printf '%s\n' "Failed to initialize git repository" >&2
		exit 5
	fi
	if ! run_git git "${git_cfg[@]}" -C "${repo_dir}" remote add origin "${repo}" >/dev/null 2>&1; then
		printf '%s\n' "Failed to add remote ${repo}" >&2
		exit 5
	fi
	if ! run_git git "${git_cfg[@]}" -C "${repo_dir}" fetch --quiet --depth 1 origin "${ref}" >/dev/null 2>&1; then
		printf '%s\n' "Failed to fetch commit ${ref}" >&2
		exit 5
	fi
	if ! run_git git "${git_cfg[@]}" -C "${repo_dir}" checkout --quiet FETCH_HEAD >/dev/null 2>&1; then
		printf '%s\n' "Failed to checkout commit ${ref}" >&2
		exit 5
	fi
else
	if ! run_git git "${git_cfg[@]}" clone --depth 1 --shallow-submodules --branch "${ref}" "${repo}" "${repo_dir}" >/dev/null 2>&1; then
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
# SECURITY: do not use case/glob matching for containment checks. Paths can
# contain glob metacharacters like []?* which would turn the check into a
# wildcard match. Use literal string comparisons.
base="${repo_dir_canonical}"
if [ "${base}" != "/" ]; then
	base="${base%/}"
fi
if [ "${target}" != "${base}" ]; then
	if [ "${base}" != "/" ]; then
		prefix="${base}/"
		if [ "${target:0:${#prefix}}" != "${prefix}" ]; then
			printf '%s\n' "File ${path} escapes repository root" >&2
			exit 3
		fi
	fi
fi
if [ ! -f "${target}" ]; then
	printf '%s\n' "File ${path} not found in repository" >&2
	exit 3
fi

cat "${target}"
