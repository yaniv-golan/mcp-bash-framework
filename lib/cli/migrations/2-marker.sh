#!/usr/bin/env bash
# Migration rule; see lib/migrate_rules.sh for the contract.
# shellcheck disable=SC2034  # MIG_* are read by the engine that sources this file
MIG_ID=2-marker
MIG_API=2
MIG_KIND=auto
MIG_SCOPE="config"
MIG_VALIDATE=0
MIG_SUMMARY='server.meta.json does not record "mcpBash": {"apiVersion": 2}'
MIG_FIX='mcp-bash migrate --write sets it once nothing else is pending'
mig_detect() {
	local file="$1" bin="${MCPBASH_JSON_TOOL_BIN:-}"
	case "${file##*/}" in server.meta.json) ;; *) return 0 ;; esac
	[ -n "${bin}" ] || bin="$(command -v jq 2>/dev/null || true)"
	[ -n "${bin}" ] || return 0
	"${bin}" -e '(.mcpBash.apiVersion // 0) >= 2' "${file}" >/dev/null 2>&1 && return 0
	printf '1\t-\t%s\n' "no mcpBash.apiVersion"
}
mig_apply() {
	local file="$1" bin="${MCPBASH_JSON_TOOL_BIN:-}" tmp
	[ -n "${bin}" ] || bin="$(command -v jq 2>/dev/null || true)"
	[ -n "${bin}" ] || return 1
	tmp="$(mktemp "${file}.mig.XXXXXX")" || return 1
	if "${bin}" '.mcpBash = ((.mcpBash // {}) + {apiVersion: 2})' "${file}" >"${tmp}" 2>/dev/null; then
		cat "${tmp}" >"${file}"
	fi
	rm -f "${tmp}"
}
