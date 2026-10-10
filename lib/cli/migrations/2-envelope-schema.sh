#!/usr/bin/env bash
# Migration rule; see lib/migrate_rules.sh for the contract.
# shellcheck disable=SC2034  # MIG_* are read by the engine that sources this file
MIG_ID=2-envelope-schema
MIG_API=2
MIG_KIND=manual
MIG_SCOPE="tool-meta"
MIG_SUMMARY="outputSchema describes the {success, result} envelope, which mcp_result_json does not send"
MIG_FIX='outputSchema = its properties.result (migrate does this together with mcp_result_success)'
mig_detect() {
	local file="$1" bin="${MCPBASH_JSON_TOOL_BIN:-}"
	[ -n "${bin}" ] || bin="$(command -v jq 2>/dev/null || true)"
	[ -n "${bin}" ] || return 0
	# The 1.x envelope: properties "success" plus "result" and/or "error".
	"${bin}" -e '(.outputSchema.properties // {}) as $p
		| ($p | has("success")) and (($p | has("result")) or ($p | has("error")))' \
		"${file}" >/dev/null 2>&1 || return 0
	local kind=manual
	# Auto only when the data schema is there to unwrap (properties.result).
	"${bin}" -e '.outputSchema.properties.result != null' "${file}" >/dev/null 2>&1 && kind=auto
	local line
	line="$(grep -n '"outputSchema"' "${file}" | head -n 1 | cut -d: -f1)"
	printf '%s\t%s\t%s\n' "${line:-1}" "${kind}" '"outputSchema" describes {success, result}'
}
