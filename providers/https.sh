#!/usr/bin/env bash
# Resource provider: fetch content from HTTPS endpoints.
#
# Address checks live in lib/policy.sh (the single private-range list). The
# provider refuses to fetch if that library cannot be loaded.
#
# Order of checks:
#   1. the host literal: non-canonical IP literals and blocked addresses;
#   2. hostname syntax (must be spelled the way curl will look it up);
#   3. allow/deny lists (denied hosts never trigger a lookup);
#   4. one resolution, every answer vetted; no answer means no fetch;
#   5. curl pinned with --resolve to exactly the vetted addresses.

set -euo pipefail

MCP_HTTPS_POLICY_FUNCS="mcp_policy_extract_host_from_url mcp_policy_extract_port_from_url mcp_policy_host_is_noncanonical_ip_literal mcp_policy_ip_is_private mcp_policy_host_is_ip_literal mcp_policy_hostname_is_valid mcp_policy_resolve_vetted_ips mcp_policy_host_allowed"

mcp_https_load_policy() {
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
	for fn in ${MCP_HTTPS_POLICY_FUNCS}; do
		command -v "${fn}" >/dev/null 2>&1 || return 1
	done
	return 0
}

mcp_https_host_is_obfuscated_ip_literal() {
	# Non-canonical IP literals (octal, hex, short or integer IPv4; malformed or
	# zoned IPv6). Curl would read these as some address we did not vet.
	local host="$1"
	[ -n "${host}" ] || return 0
	mcp_policy_host_is_noncanonical_ip_literal "${host}"
}

mcp_https_log_block() {
	local host="$1"
	if command -v mcp_logging_warning >/dev/null 2>&1; then
		mcp_logging_warning "mcp.https" "Blocked host ${host}"
	else
		printf '%s\n' "HTTPS provider blocked host ${host}" >&2
	fi
}

mcp_https_extract_port_from_url() {
	mcp_policy_extract_port_from_url "$1" 443
}

mcp_https_main() {
	if ! mcp_https_load_policy; then
		printf '%s\n' "HTTPS provider requires lib/policy.sh (set MCPBASH_HOME); refusing to fetch" >&2
		return 4
	fi
	local uri="${1:-}"
	if [ -z "${uri}" ] || [[ "${uri}" != https://* ]]; then
		printf '%s\n' "HTTPS provider requires https:// URI" >&2
		return 4
	fi

	local host
	host="$(mcp_policy_extract_host_from_url "${uri}")" || host=""
	local port
	port="$(mcp_https_extract_port_from_url "${uri}")"
	if [ -z "${host}" ]; then
		mcp_https_log_block "<empty>"
		return 4
	fi
	if mcp_https_host_is_obfuscated_ip_literal "${host}"; then
		mcp_https_log_block "${host}"
		return 4
	fi
	if mcp_policy_ip_is_private "${host}"; then
		mcp_https_log_block "${host}"
		return 4
	fi
	local host_is_literal="false"
	if mcp_policy_host_is_ip_literal "${host}"; then
		host_is_literal="true"
	elif ! mcp_policy_hostname_is_valid "${host}"; then
		mcp_https_log_block "${host}"
		printf '%s\n' "HTTPS provider requires an ASCII hostname without a trailing dot or percent-encoding" >&2
		return 4
	fi
	# Deny-by-default egress: require an explicit allowlist unless operators
	# intentionally opt into allow-all.
	local allow_all_raw="${MCPBASH_HTTPS_ALLOW_ALL:-false}"
	local allow_all="false"
	case "${allow_all_raw}" in
	true | 1 | yes | on) allow_all="true" ;;
	esac
	if [ "${allow_all}" != "true" ] && [ -z "${MCPBASH_HTTPS_ALLOW_HOSTS:-}" ]; then
		mcp_https_log_block "${host}"
		printf '%s\n' "HTTPS provider requires MCPBASH_HTTPS_ALLOW_HOSTS (or MCPBASH_HTTPS_ALLOW_ALL=true)" >&2
		return 4
	fi
	if ! mcp_policy_host_allowed "${host}" "${MCPBASH_HTTPS_ALLOW_HOSTS:-}" "${MCPBASH_HTTPS_DENY_HOSTS:-}"; then
		mcp_https_log_block "${host}"
		return 4
	fi

	if ! command -v curl >/dev/null 2>&1; then
		# Security note: we intentionally require curl because it supports DNS
		# pinning via --resolve to mitigate DNS rebinding between the check and
		# the fetch. wget cannot be pinned equivalently.
		printf '%s\n' "curl is required for HTTPS provider" >&2
		return 4
	fi

	# Resolve once and connect only to what was checked. An IP literal needs
	# no lookup: curl connects to exactly that (canonical) address.
	local -a target_ips=()
	if [ "${host_is_literal}" = "true" ]; then
		target_ips=("")
	else
		local vetted="" vet_rc=0
		vetted="$(mcp_policy_resolve_vetted_ips "${host}")" || vet_rc=$?
		case "${vet_rc}" in
		0) ;;
		2)
			mcp_https_log_block "${host}"
			return 4
			;;
		*)
			printf '%s\n' "HTTPS provider: unable to resolve ${host}; refusing an unpinned fetch" >&2
			return 5
			;;
		esac
		local ip
		while IFS= read -r ip; do
			[ -n "${ip}" ] && target_ips+=("${ip}")
		done <<EOF
${vetted}
EOF
		if [ "${#target_ips[@]}" -eq 0 ]; then
			printf '%s\n' "HTTPS provider: unable to resolve ${host}; refusing an unpinned fetch" >&2
			return 5
		fi
	fi

	local timeout_secs="${MCPBASH_HTTPS_TIMEOUT:-15}"
	local timeout_ceil=60
	case "${timeout_secs}" in
	'' | *[!0-9]*) timeout_secs=15 ;;
	esac
	if [ "${timeout_secs}" -gt "${timeout_ceil}" ]; then
		timeout_secs="${timeout_ceil}"
	fi
	local max_bytes="${MCPBASH_HTTPS_MAX_BYTES:-10485760}"
	local max_bytes_ceil=20971520
	case "${max_bytes}" in
	'' | *[!0-9]*) max_bytes=10485760 ;;
	esac
	if [ "${max_bytes}" -gt "${max_bytes_ceil}" ]; then
		max_bytes="${max_bytes_ceil}"
	fi
	local user_agent="${MCPBASH_HTTPS_USER_AGENT:-}"

	local tmp_file header_file
	tmp_file="$(mktemp "${TMPDIR:-/tmp}/mcp-https.XXXXXX")"
	header_file="$(mktemp "${TMPDIR:-/tmp}/mcp-https-hdr.XXXXXX")"
	# NOTE: EXIT traps run after function locals go out of scope. Capture the
	# temp paths via globals so set -u doesn't trip on unbound locals.
	MCPBASH_HTTPS_TMP_FILE="${tmp_file}"
	MCPBASH_HTTPS_HDR_FILE="${header_file}"
	trap 'rm -f -- "${MCPBASH_HTTPS_TMP_FILE:-}" "${MCPBASH_HTTPS_HDR_FILE:-}"' EXIT

	# Build optional curl arguments (e.g., User-Agent)
	local -a curl_opts=()
	if [ -n "${user_agent}" ]; then
		curl_opts+=(-A "${user_agent}")
	fi

	# Try each vetted address in order (all were checked as public). The
	# host:port entry pins the name curl looks up; the "*:port" entry also
	# catches any spelling of the host curl might derive differently.
	local curl_rc=1
	local ip addr http_code location
	local -a pin_args=()
	for ip in "${target_ips[@]}"; do
		pin_args=()
		if [ -n "${ip}" ]; then
			addr="${ip}"
			case "${addr}" in *:*) addr="[${addr}]" ;; esac
			pin_args=(--resolve "${host}:${port}:${addr}" --resolve "*:${port}:${addr}")
		fi
		# Capture HTTP code and headers in single request (with all security flags)
		# NOTE: Remove -f flag to get HTTP status codes instead of curl failing on 4xx/5xx
		# NOTE: ${arr[@]+"${arr[@]}"} safely handles empty arrays with set -u
		# CRITICAL: Do NOT use 2>&1 - stderr must stay separate to avoid corrupting http_code
		http_code=$(curl -w '%{http_code}' -D "${header_file}" -o "${tmp_file}" \
			-sS ${curl_opts[@]+"${curl_opts[@]}"} \
			--max-time "${timeout_secs}" --connect-timeout "${timeout_secs}" \
			--max-filesize "${max_bytes}" \
			--proto '=https' --proto-redir '=https' --max-redirs 0 \
			${pin_args[@]+"${pin_args[@]}"} \
			"${uri}") && curl_rc=0 || curl_rc=$?

		# Check curl exit code FIRST (before examining http_code). 63 means the
		# size limit was exceeded; anything else moves on to the next address.
		if [[ $curl_rc -ne 0 ]]; then
			[[ $curl_rc -eq 63 ]] && return 6
			continue
		fi

		# Handle http_code "000" - curl succeeded but no HTTP response (rare edge
		# case). Force non-zero so we don't accidentally succeed; try the next address.
		if [[ "${http_code}" == "000" ]]; then
			curl_rc=1
			continue
		fi

		# Check for redirect status (3xx) - exit code 7
		# NOTE: Multi-IP redirect behavior is "first redirect wins"
		if [[ "${http_code}" =~ ^3[0-9][0-9]$ ]]; then
			location=$(grep -i '^location:' "${header_file}" | sed 's/^[^:]*: *//' | tr -d '\r\n')
			printf 'redirect:%s\n' "${location}" >&2
			return 7
		fi

		# Check for HTTP errors (4xx/5xx)
		# NOTE: All HTTP errors return exit 5 (network_error). 404 is permanent but
		# will still be retried - this is a known v1 limitation.
		if [[ "${http_code}" =~ ^[45][0-9][0-9]$ ]]; then
			printf 'HTTP error: %s\n' "${http_code}" >&2
			return 5
		fi

		# Success (2xx) - stop trying addresses
		break
	done
	if [ "${curl_rc}" -ne 0 ]; then
		return 5
	fi

	cat "${tmp_file}"
}

mcp_https_main "$@"
