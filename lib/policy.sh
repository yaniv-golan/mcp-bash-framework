#!/usr/bin/env bash
# Host policy helpers (allow/deny lists, normalization, address checks).
#
# This file holds the ONE list of blocked address ranges. providers/https.sh
# and providers/git.sh source it and refuse to fetch when it cannot be loaded.
# The classification path uses bash builtins plus `tr` only, because providers
# may run with a minimal PATH. Compatible with bash 3.2.

set -euo pipefail

# Canonical dotted quad: four decimal octets 0-255, no leading zeros.
MCPBASH_POLICY_IPV4_OCTET_RE='(25[0-5]|2[0-4][0-9]|1[0-9][0-9]|[1-9][0-9]|[0-9])'
MCPBASH_POLICY_IPV4_RE="^${MCPBASH_POLICY_IPV4_OCTET_RE}\\.${MCPBASH_POLICY_IPV4_OCTET_RE}\\.${MCPBASH_POLICY_IPV4_OCTET_RE}\\.${MCPBASH_POLICY_IPV4_OCTET_RE}\$"
# A label that URL parsers (curl, WHATWG) read as a number: decimal, octal or 0x-hex.
MCPBASH_POLICY_NUMERIC_LABEL_RE='^([0-9]+|0[xX][0-9a-fA-F]*)$'
# One DNS label: letters, digits, hyphen (not at the ends), underscore tolerated.
MCPBASH_POLICY_HOST_LABEL_RE='^[a-z0-9_]([a-z0-9_-]{0,61}[a-z0-9_])?$'
MCPBASH_POLICY_HEXTET_RE='^[0-9a-f]{1,4}$'

mcp_policy_lower() {
	printf '%s' "$1" | tr '[:upper:]' '[:lower:]'
}

mcp_policy_strip_brackets() {
	local host="$1"
	if [ "${host#\[}" != "${host}" ]; then
		host="${host#\[}"
		host="${host%\]}"
	fi
	printf '%s' "${host}"
}

mcp_policy_ipv4_is_canonical() {
	[[ "$1" =~ ${MCPBASH_POLICY_IPV4_RE} ]]
}

mcp_policy_ipv4_octets_are_private() {
	# Args: the four decimal octets. Returns 0 when the address must not be fetched.
	local a="$1" b="$2" c="$3"
	# 0.0.0.0/8, 10/8, 127/8, 224/4 multicast, 240/4 reserved (incl. 255.255.255.255)
	if [ "${a}" -eq 0 ] || [ "${a}" -eq 10 ] || [ "${a}" -eq 127 ] || [ "${a}" -ge 224 ]; then
		return 0
	fi
	# 100.64.0.0/10 shared/CGNAT (includes Alibaba Cloud metadata 100.100.100.200)
	if [ "${a}" -eq 100 ] && [ "${b}" -ge 64 ] && [ "${b}" -le 127 ]; then
		return 0
	fi
	# 169.254.0.0/16 link-local (cloud metadata)
	if [ "${a}" -eq 169 ] && [ "${b}" -eq 254 ]; then
		return 0
	fi
	# 172.16.0.0/12
	if [ "${a}" -eq 172 ] && [ "${b}" -ge 16 ] && [ "${b}" -le 31 ]; then
		return 0
	fi
	# 192.168.0.0/16, and 192.0.0.0/24 (IETF protocol assignments)
	if [ "${a}" -eq 192 ] && [ "${b}" -eq 168 ]; then
		return 0
	fi
	if [ "${a}" -eq 192 ] && [ "${b}" -eq 0 ] && [ "${c}" -eq 0 ]; then
		return 0
	fi
	# 198.18.0.0/15 benchmarking
	if [ "${a}" -eq 198 ] && { [ "${b}" -eq 18 ] || [ "${b}" -eq 19 ]; }; then
		return 0
	fi
	return 1
}

mcp_policy_ipv4_is_private() {
	# Returns 0 for a canonical dotted quad in a blocked range, and for the empty
	# string and localhost (kept for compatibility). Anything that is not a
	# canonical dotted quad returns 1: use mcp_policy_ip_is_private for a
	# fail-closed check of arbitrary hosts.
	local ip="$1"
	case "${ip}" in
	"" | localhost) return 0 ;;
	esac
	mcp_policy_ipv4_is_canonical "${ip}" || return 1
	local a b c d
	IFS=. read -r a b c d <<<"${ip}"
	mcp_policy_ipv4_octets_are_private "${a}" "${b}" "${c}" "${d}"
}

mcp_policy_host_is_ipv4_like() {
	# True when a URL parser would read the host as an IPv4 address: its last
	# label (ignoring one trailing dot) is a decimal, octal or 0x-hex number.
	# Catches 0177.0.0.1, 0x7f.0.0.1, 0177.1, 127.1, 2130706433 and 0x7f000001
	# without matching names made of hex letters (cafe.face, bad.de).
	local host="${1%.}"
	[ -n "${host}" ] || return 1
	local last="${host##*.}"
	[[ "${last}" =~ ${MCPBASH_POLICY_NUMERIC_LABEL_RE} ]]
}

mcp_policy_ipv6_expand() {
	# Print the eight hextets of an IPv6 address as space-separated decimals.
	# Accepts :: compression and a trailing canonical dotted quad. The input
	# must be lowercase, without brackets or zone ID. Returns 1 if malformed.
	local ip="$1"
	case "${ip}" in
	"" | *[!0-9a-f:.]* | *:::*) return 1 ;;
	*:*) ;;
	*) return 1 ;;
	esac
	local tail="${ip##*:}"
	case "${tail}" in
	*.*)
		mcp_policy_ipv4_is_canonical "${tail}" || return 1
		local a b c d
		IFS=. read -r a b c d <<<"${tail}"
		ip="${ip%:*}:$(printf '%x:%x' $((a * 256 + b)) $((c * 256 + d)))"
		;;
	esac
	case "${ip}" in *.*) return 1 ;; esac

	local head="" rest="" compressed="false"
	if [ "${ip#*::}" != "${ip}" ]; then
		compressed="true"
		head="${ip%%::*}"
		rest="${ip#*::}"
		case "${rest}" in *::*) return 1 ;; esac
	else
		head="${ip}"
	fi
	case "${head}" in :* | *:) return 1 ;; esac
	case "${rest}" in :* | *:) return 1 ;; esac

	local -a head_groups=() rest_groups=()
	if [ -n "${head}" ]; then
		IFS=: read -r -a head_groups <<<"${head}"
	fi
	if [ -n "${rest}" ]; then
		IFS=: read -r -a rest_groups <<<"${rest}"
	fi
	local nh="${#head_groups[@]}" nr="${#rest_groups[@]}"
	local total=$((nh + nr))
	if [ "${compressed}" = "true" ]; then
		[ "${total}" -le 7 ] || return 1
	else
		[ "${total}" -eq 8 ] || return 1
	fi

	local out="" g i=0
	while [ "${i}" -lt "${nh}" ]; do
		g="${head_groups[${i}]}"
		[[ "${g}" =~ ${MCPBASH_POLICY_HEXTET_RE} ]] || return 1
		out="${out} $((16#${g}))"
		i=$((i + 1))
	done
	i=$((8 - total))
	while [ "${i}" -gt 0 ]; do
		out="${out} 0"
		i=$((i - 1))
	done
	i=0
	while [ "${i}" -lt "${nr}" ]; do
		g="${rest_groups[${i}]}"
		[[ "${g}" =~ ${MCPBASH_POLICY_HEXTET_RE} ]] || return 1
		out="${out} $((16#${g}))"
		i=$((i + 1))
	done
	printf '%s' "${out# }"
}

mcp_policy_ipv6_groups_are_private() {
	# Args: the eight hextets as decimals. Returns 0 when the address is blocked.
	local g0="$1" g1="$2" g2="$3" g3="$4" g4="$5" g5="$6" g6="$7" g7="$8"
	# ::/96 (unspecified, loopback, v4-compatible) and ::ffff:0:0/96 (v4-mapped):
	# judge the embedded IPv4 address; :: and ::1 fall in 0.0.0.0/8.
	if [ $((g0 | g1 | g2 | g3 | g4)) -eq 0 ] && { [ "${g5}" -eq 0 ] || [ "${g5}" -eq 65535 ]; }; then
		mcp_policy_ipv4_octets_are_private $((g6 >> 8)) $((g6 & 255)) $((g7 >> 8)) $((g7 & 255))
		return
	fi
	# ::ffff:0:0:0/96 (SIIT v4-translated)
	if [ $((g0 | g1 | g2 | g3)) -eq 0 ] && [ "${g4}" -eq 65535 ] && [ "${g5}" -eq 0 ]; then
		mcp_policy_ipv4_octets_are_private $((g6 >> 8)) $((g6 & 255)) $((g7 >> 8)) $((g7 & 255))
		return
	fi
	# 64:ff9b::/96 NAT64 well-known prefix: judge the embedded IPv4 address.
	if [ "${g0}" -eq 100 ] && [ "${g1}" -eq 65435 ] && [ $((g2 | g3 | g4 | g5)) -eq 0 ]; then
		mcp_policy_ipv4_octets_are_private $((g6 >> 8)) $((g6 & 255)) $((g7 >> 8)) $((g7 & 255))
		return
	fi
	# 2002::/16 6to4: the IPv4 address is in hextets 1-2.
	if [ "${g0}" -eq 8194 ]; then
		mcp_policy_ipv4_octets_are_private $((g1 >> 8)) $((g1 & 255)) $((g2 >> 8)) $((g2 & 255))
		return
	fi
	# 2001::/32 Teredo (tunnels to an address we cannot vet), 2001:db8::/32 docs.
	if [ "${g0}" -eq 8193 ] && { [ "${g1}" -eq 0 ] || [ "${g1}" -eq 3512 ]; }; then
		return 0
	fi
	# Only 2000::/3 is global unicast. Everything else is blocked, including
	# 64:ff9b:1::/48, 100::/64, fc00::/7, fe80::/10, fec0::/10 and ff00::/8.
	if [ $((g0 & 57344)) -ne 8192 ]; then
		return 0
	fi
	return 1
}

mcp_policy_host_is_noncanonical_ip_literal() {
	# True when the host is meant as an IP literal but cannot be vetted exactly
	# as curl will read it:
	# - IPv4-looking hosts that are not a canonical dotted quad (octal, hex,
	#   leading zeros, fewer than four parts, integer forms, trailing dot);
	# - IPv6 literals that do not parse, or that carry a zone ID.
	local host
	host="$(mcp_policy_lower "$(mcp_policy_strip_brackets "$1")")"
	case "${host}" in
	*:*)
		case "${host}" in *%*) return 0 ;; esac
		if mcp_policy_ipv6_expand "${host}" >/dev/null; then
			return 1
		fi
		return 0
		;;
	esac
	if mcp_policy_host_is_ipv4_like "${host}"; then
		if mcp_policy_ipv4_is_canonical "${host}"; then
			return 1
		fi
		return 0
	fi
	return 1
}

mcp_policy_host_is_ip_literal() {
	# True for a canonical dotted quad or a parseable IPv6 address without zone.
	local host
	host="$(mcp_policy_lower "$(mcp_policy_strip_brackets "$1")")"
	case "${host}" in
	*%*) return 1 ;;
	*:*) mcp_policy_ipv6_expand "${host}" >/dev/null ;;
	*) mcp_policy_ipv4_is_canonical "${host}" ;;
	esac
}

mcp_policy_ip_is_private() {
	# Literal check, no DNS. Returns 0 (refuse) for:
	# - empty, localhost and *.localhost;
	# - non-canonical or malformed IP literals (fail closed);
	# - addresses in a blocked IPv4 or IPv6 range.
	# Returns 1 for public literals and for ordinary hostnames, which still
	# need mcp_policy_resolve_vetted_ips.
	local ip
	ip="$(mcp_policy_lower "$(mcp_policy_strip_brackets "$1")")"
	case "${ip}" in
	"" | localhost | localhost. | *.localhost | *.localhost.) return 0 ;;
	esac
	if mcp_policy_host_is_noncanonical_ip_literal "${ip}"; then
		return 0
	fi
	case "${ip}" in
	*:*)
		local groups=""
		groups="$(mcp_policy_ipv6_expand "${ip}")" || return 0
		# shellcheck disable=SC2086 # eight numbers, split on purpose
		mcp_policy_ipv6_groups_are_private ${groups}
		return
		;;
	esac
	if mcp_policy_ipv4_is_canonical "${ip}"; then
		mcp_policy_ipv4_is_private "${ip}"
		return
	fi
	return 1
}

mcp_policy_hostname_is_valid() {
	# Strict DNS hostname: LDH labels, no trailing dot, no percent-encoding and
	# no non-ASCII (use punycode). A looser host could be spelled differently by
	# curl than by our --resolve pin, and curl would then resolve it itself.
	local host
	host="$(mcp_policy_lower "$1")"
	if [ -z "${host}" ] || [ "${#host}" -gt 253 ]; then
		return 1
	fi
	case "${host}" in
	.* | *. | *..*) return 1 ;;
	esac
	local -a labels=()
	IFS=. read -r -a labels <<<"${host}"
	[ "${#labels[@]}" -gt 0 ] || return 1
	local i=0
	while [ "${i}" -lt "${#labels[@]}" ]; do
		[[ "${labels[${i}]}" =~ ${MCPBASH_POLICY_HOST_LABEL_RE} ]] || return 1
		i=$((i + 1))
	done
	return 0
}

mcp_policy_normalize_host() {
	local host="$1"
	if [ -z "${host}" ]; then
		return 1
	fi
	mcp_policy_lower "$(mcp_policy_strip_brackets "${host}")"
}

mcp_policy_extract_authority_from_url() {
	# Authority without userinfo: strip path/query/fragment, then everything up
	# to the last '@' (userinfo is otherwise an SSRF bypass vector).
	local authority="${1#*://}"
	authority="${authority%%/*}"
	authority="${authority%%\?*}"
	authority="${authority%%\#*}"
	authority="${authority##*@}"
	printf '%s' "${authority}"
}

mcp_policy_extract_host_from_url() {
	local authority host=""
	authority="$(mcp_policy_extract_authority_from_url "$1")"
	case "${authority}" in
	\[*\]*)
		# [ipv6]:port or [ipv6]
		host="${authority#\[}"
		host="${host%%\]*}"
		;;
	*)
		host="${authority%%:*}"
		;;
	esac
	mcp_policy_normalize_host "${host}"
}

mcp_policy_extract_port_from_url() {
	# Port from the URL authority; the default (443 unless given) when the URL
	# has no port. A port that is present must be canonical decimal 1-65535
	# without leading zeros; anything else returns 1 and prints nothing. The
	# pin is built from this value, so it must be exactly the port curl/git
	# will connect to (they read ":000080" as 80 and ":0" as 0; a lenient
	# parser that fell back to the default left those connections unpinned).
	local default_port="${2:-443}"
	local authority port=""
	authority="$(mcp_policy_extract_authority_from_url "$1")"
	case "${authority}" in
	\[*\]) ;;
	\[*\]:*)
		port="${authority#*]:}"
		[ -n "${port}" ] || return 1
		;;
	\[*) return 1 ;;
	*:*)
		port="${authority#*:}"
		[ -n "${port}" ] || return 1
		;;
	esac
	if [ -z "${port}" ]; then
		printf '%s' "${default_port}"
		return 0
	fi
	case "${port}" in
	*[!0-9]* | 0*) return 1 ;;
	esac
	if [ "${#port}" -gt 5 ] || [ "${port}" -gt 65535 ]; then
		return 1
	fi
	printf '%s' "${port}"
}

mcp_policy_resolve_ips() {
	# Print the addresses for a host, one per line, in resolver order without
	# duplicates. Only well-formed IP addresses are printed (resolver chatter
	# such as CNAME targets is dropped). Returns 1 when none were found.
	#
	# Resolver preference follows what curl's getaddrinfo() sees: getent (NSS,
	# including /etc/hosts) on Linux, then dscacheutil (system resolver,
	# including /etc/hosts and mDNS) on macOS, then DNS-only tools. Providers
	# pin the fetch to these exact addresses, so a resolver that disagrees
	# with curl can only cause a refusal, never an unvetted connection.
	local host="$1"
	if mcp_policy_host_is_ip_literal "${host}"; then
		mcp_policy_lower "$(mcp_policy_strip_brackets "${host}")"
		printf '\n'
		return 0
	fi
	local raw=""
	if [ -z "${raw}" ] && command -v getent >/dev/null 2>&1; then
		raw="$(getent ahosts "${host}" 2>/dev/null | awk '{print $1}')" || raw=""
	fi
	if [ -z "${raw}" ] && command -v dscacheutil >/dev/null 2>&1; then
		raw="$(dscacheutil -q host -a name "${host}" 2>/dev/null | awk '$1 == "ip_address:" || $1 == "ipv6_address:" {print $2}')" || raw=""
	fi
	if [ -z "${raw}" ] && command -v dig >/dev/null 2>&1; then
		raw="$(dig +short "${host}" A "${host}" AAAA 2>/dev/null)" || raw=""
	fi
	if [ -z "${raw}" ] && command -v host >/dev/null 2>&1; then
		raw="$(host "${host}" 2>/dev/null | awk '/has address/{print $4}/IPv6 address/{print $5}')" || raw=""
	fi
	if [ -z "${raw}" ] && command -v nslookup >/dev/null 2>&1; then
		raw="$(nslookup "${host}" 2>/dev/null | awk '/^Address: /{print $2}' | tail -n +2)" || raw=""
	fi

	local out="" seen=" " ip
	while IFS= read -r ip; do
		ip="$(mcp_policy_lower "${ip}")"
		[ -n "${ip}" ] || continue
		# Keep anything address-shaped, including zoned or odd forms, so the
		# vetting step can refuse it rather than silently dropping it.
		case "${ip}" in
		*:*) ;;
		*)
			mcp_policy_ipv4_is_canonical "${ip}" || continue
			;;
		esac
		case "${seen}" in *" ${ip} "*) continue ;; esac
		seen="${seen}${ip} "
		out="${out}${ip}
"
	done <<EOF
${raw}
EOF
	if [ -z "${out}" ]; then
		return 1
	fi
	printf '%s' "${out}"
}

mcp_policy_proxy_configured() {
	# True when curl/git would send requests through a proxy. Then the proxy
	# resolves the target and a "*:port" pin entry must not be added: curl
	# shares one host cache between target and proxy, so the wildcard would
	# also redirect the proxy connection.
	[ -n "${https_proxy:-}${HTTPS_PROXY:-}${http_proxy:-}${HTTP_PROXY:-}${all_proxy:-}${ALL_PROXY:-}" ]
}

# First git release with http.curloptResolve, which the git provider needs to
# pin a hostname fetch. Shared by providers/git.sh and doctor.
MCPBASH_POLICY_GIT_PIN_MIN_MAJOR=2
MCPBASH_POLICY_GIT_PIN_MIN_MINOR=37
# shellcheck disable=SC2034 # used by providers/git.sh and lib/cli/doctor.sh
MCPBASH_POLICY_GIT_PIN_MIN_VERSION="${MCPBASH_POLICY_GIT_PIN_MIN_MAJOR}.${MCPBASH_POLICY_GIT_PIN_MIN_MINOR}"

mcp_policy_git_supports_pinning() {
	# True when the installed git understands http.curloptResolve. False when
	# git is missing or its version cannot be read.
	local version major minor rest
	version="$(git --version 2>/dev/null)" || return 1
	version="${version#git version }"
	major="${version%%.*}"
	rest="${version#*.}"
	minor="${rest%%[!0-9]*}"
	case "${major}" in '' | *[!0-9]*) return 1 ;; esac
	case "${minor}" in '' | *[!0-9]*) return 1 ;; esac
	if [ "${major}" -gt "${MCPBASH_POLICY_GIT_PIN_MIN_MAJOR}" ]; then
		return 0
	fi
	[ "${major}" -eq "${MCPBASH_POLICY_GIT_PIN_MIN_MAJOR}" ] && [ "${minor}" -ge "${MCPBASH_POLICY_GIT_PIN_MIN_MINOR}" ]
}

mcp_policy_resolve_vetted_ips() {
	# Resolve once and vet every answer. Prints the addresses (all public) on
	# success. Callers must connect only to these addresses.
	# Returns 1 when the host does not resolve, 2 when any answer is blocked.
	local host="$1" resolved="" ip out=""
	resolved="$(mcp_policy_resolve_ips "${host}")" || return 1
	while IFS= read -r ip; do
		[ -n "${ip}" ] || continue
		if mcp_policy_ip_is_private "${ip}"; then
			return 2
		fi
		out="${out}${ip}
"
	done <<EOF
${resolved}
EOF
	[ -n "${out}" ] || return 1
	printf '%s' "${out}"
}

mcp_policy_host_is_private() {
	# Fail-closed host check: 0 (refuse) when the host is a blocked or
	# non-canonical literal, does not resolve, or resolves to any blocked
	# address. Providers should prefer mcp_policy_resolve_vetted_ips so the
	# addresses checked are the ones they connect to.
	local host="$1"
	if mcp_policy_ip_is_private "${host}"; then
		return 0
	fi
	if mcp_policy_host_is_ip_literal "${host}"; then
		return 1
	fi
	if mcp_policy_resolve_vetted_ips "${host}" >/dev/null; then
		return 1
	fi
	return 0
}

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
