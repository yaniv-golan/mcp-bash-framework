#!/usr/bin/env bash
# Declarative env policy from server.d/server.meta.json ("env" object).
#
# Only the tool/provider env-policy keys may be set this way. Operator opt-ins
# (MCPBASH_*_INHERIT_ALLOW, MCPBASH_ALLOW_PROJECT_HOOKS, ...) and arbitrary
# variables are refused. Values are validated inside the JSON tool against a
# strict character set before they reach the shell, and values are never
# printed: warnings name keys only.

set -euo pipefail

MCP_META_ENV_KEYS="MCPBASH_TOOL_ENV_MODE MCPBASH_TOOL_ENV_ALLOWLIST MCPBASH_PROVIDER_ENV_MODE MCPBASH_PROVIDER_ENV_ALLOWLIST"

mcp_meta_env_file() {
	printf '%s' "${MCPBASH_SERVER_DIR:-${MCPBASH_PROJECT_ROOT:-.}/server.d}/server.meta.json"
}

# Always stderr: apply runs at startup, before initialize, and in run-tool,
# whose stdout carries the tool result. Like other startup diagnostics.
_mcp_meta_env_warn() {
	printf 'mcp-bash: %s\n' "$1" >&2
}

# Classify every entry of the "env" object. Prints one TAB-separated line per
# entry: <status> <key> [<value>]
#   apply    KEY VALUE   valid; VALUE matches a strict charset (no TAB/CR/LF)
#   refused  KEY         key not settable from server.meta.json
#   invalid  KEY REASON  allowed key with an unusable value
#   error    env REASON  the "env" member itself is unusable
# Refused/invalid keys are reduced to [A-Za-z0-9_] (others become "?") and
# truncated, so key names cannot inject control characters into logs.
# Returns 0 with no output when there is no file, no "env", or no JSON tool.
mcp_meta_env_check() {
	local meta_file="${1:-$(mcp_meta_env_file)}"
	[ -f "${meta_file}" ] || return 0
	if [ "${MCPBASH_JSON_TOOL:-none}" = "none" ] || [ -z "${MCPBASH_JSON_TOOL_BIN:-}" ]; then
		return 0
	fi
	"${MCPBASH_JSON_TOOL_BIN}" -r -s '
		def safe_key: gsub("[^A-Za-z0-9_]"; "?") | .[0:64];
		def name_ok: test("^[A-Za-z_][A-Za-z0-9_]*$");
		def name_dangerous:
			test("^(SHELLOPTS|BASHOPTS|PS4|BASH_ENV|ENV|BASH_XTRACEFD|IFS)$")
			or test("^(LD_|DYLD_|BASH_FUNC_|_MCP|MCPBASH_)")
			or test("^MCP_(SDK|LOG_STREAM|CANCEL_FILE|RESOURCES_ROOTS|CONFIG_JSON|TRANSPORT|PATH_DEBUG)$")
			or test("^MCP_(TOOL|ELICIT|PROGRESS|ROOTS|COMPLETION|PROMPT|RESOURCE)_");
		def modes($k):
			if $k == "MCPBASH_TOOL_ENV_MODE" then ["minimal", "allowlist", "inherit"]
			else ["isolate", "allowlist", "inherit"] end;
		if length != 1 then "error\tenv\tserver.meta.json must contain exactly one JSON document"
		else .[0] |
		if (type != "object") or (has("env") | not) or (.env == null) then empty
		elif (.env | type) != "object" then "error\tenv\tenv must be an object"
		else .env | to_entries[] |
			.key as $k | .value as $v |
			if ($k | IN("MCPBASH_TOOL_ENV_MODE", "MCPBASH_TOOL_ENV_ALLOWLIST",
				"MCPBASH_PROVIDER_ENV_MODE", "MCPBASH_PROVIDER_ENV_ALLOWLIST") | not)
			then "refused\t\($k | safe_key)"
			elif ($v | type) != "string" then "invalid\t\($k)\tvalue must be a string"
			elif ($v | length) > 4096 then "invalid\t\($k)\tvalue longer than 4096 characters"
			elif ($v | explode | any(. < 32 or . == 127)) then "invalid\t\($k)\tvalue contains control characters"
			elif ($k | endswith("_MODE")) then
				if ($v | IN(modes($k)[])) then "apply\t\($k)\t\($v)"
				else "invalid\t\($k)\tmode must be one of: \(modes($k) | join(", "))" end
			else
				($v | [splits("[, ]+")] | map(select(. != ""))) as $names |
				if ($v | test("^[A-Za-z0-9_, ]*$") | not) or any($names[]; name_ok | not) then
					"invalid\t\($k)\tnames must match [A-Za-z_][A-Za-z0-9_]*, separated by commas"
				elif any($names[]; name_dangerous) then
					"invalid\t\($k)\tlists a reserved or shell-control variable name"
				else "apply\t\($k)\t\($names | join(","))" end
			end
		end
		end
	' "${meta_file}" 2>/dev/null || printf 'error\tenv\tserver.meta.json is not valid JSON\n'
}

# A launch-env value counts as unset when empty or when it is an unexpanded
# MCPB placeholder (Claude Desktop leaves ${user_config.x} literal when the
# setting has no value and no default).
_mcp_meta_env_launch_set() {
	local value="${1-}"
	[ -n "${value}" ] || return 1
	case "${value}" in
	'${user_config.'*) return 1 ;;
	esac
	return 0
}

# Scope ("TOOL" or "PROVIDER") is operator-controlled when the launch env sets
# either variable of its MODE/ALLOWLIST pair; meta values for it are ignored.
mcp_meta_env_scope_from_launch() {
	local scope="$1"
	local mode_var="MCPBASH_${scope}_ENV_MODE"
	local list_var="MCPBASH_${scope}_ENV_ALLOWLIST"
	_mcp_meta_env_launch_set "${!mode_var-}" || _mcp_meta_env_launch_set "${!list_var-}"
}

# Apply the "env" object to the current process. Call once, after JSON tool
# detection and before any tool or provider is spawned.
mcp_meta_env_apply() {
	case "${MCPBASH_IGNORE_META_ENV:-false}" in
	true | 1 | yes | on) return 0 ;;
	esac
	local tool_from_launch=false provider_from_launch=false
	mcp_meta_env_scope_from_launch TOOL && tool_from_launch=true
	mcp_meta_env_scope_from_launch PROVIDER && provider_from_launch=true

	local status key value
	while IFS=$'\t' read -r status key value; do
		case "${status}" in
		apply)
			case "${key}" in
			MCPBASH_TOOL_*) [ "${tool_from_launch}" = "true" ] && continue ;;
			MCPBASH_PROVIDER_*) [ "${provider_from_launch}" = "true" ] && continue ;;
			*) continue ;;
			esac
			export "${key}=${value}"
			;;
		refused)
			_mcp_meta_env_warn "server.meta.json env: ignoring ${key} (only ${MCP_META_ENV_KEYS// /, } may be set there; set others in the launch environment)"
			;;
		invalid)
			_mcp_meta_env_warn "server.meta.json env: ignoring ${key}: ${value}"
			;;
		error)
			_mcp_meta_env_warn "server.meta.json env: ${value}"
			;;
		esac
	done < <(mcp_meta_env_check)
	return 0
}

# Describe the effective env policy for diagnostics (doctor), without changing
# the environment. Mirrors mcp_meta_env_apply. Prints TAB-separated lines:
#   switch   ignored                       MCPBASH_IGNORE_META_ENV is set
#   policy   SCOPE MODE SOURCE             SOURCE: launch env | server.meta.json | default
#   name     SCOPE NAME STATE              STATE: set | empty | placeholder | not set
#   badname  SCOPE NAME                    allowlist entry that is not a valid name
#   inherit  SCOPE                         inherit without the operator's *_INHERIT_ALLOW
#   refused / invalid / error              as from mcp_meta_env_check
# Values are never printed; names are validated before any lookup.
mcp_meta_env_report() {
	local meta_file="${1:-$(mcp_meta_env_file)}"
	local ignore_meta=false
	case "${MCPBASH_IGNORE_META_ENV:-false}" in
	true | 1 | yes | on)
		ignore_meta=true
		printf 'switch\tignored\n'
		;;
	esac

	local meta_lines=""
	meta_lines="$(mcp_meta_env_check "${meta_file}")"
	local status key detail
	while IFS=$'\t' read -r status key detail; do
		case "${status}" in
		refused) printf 'refused\t%s\n' "${key}" ;;
		invalid | error) printf '%s\t%s\t%s\n' "${status}" "${key}" "${detail}" ;;
		esac
	done <<<"${meta_lines}"

	local scope default_mode mode list source mode_var list_var meta_mode meta_list
	for scope in TOOL PROVIDER; do
		mode_var="MCPBASH_${scope}_ENV_MODE"
		list_var="MCPBASH_${scope}_ENV_ALLOWLIST"
		if [ "${scope}" = "TOOL" ]; then default_mode="minimal"; else default_mode="isolate"; fi
		meta_mode="$(printf '%s\n' "${meta_lines}" | awk -F'\t' -v k="${mode_var}" '$1=="apply" && $2==k {print $3}')"
		meta_list="$(printf '%s\n' "${meta_lines}" | awk -F'\t' -v k="${list_var}" '$1=="apply" && $2==k {print $3}')"
		if mcp_meta_env_scope_from_launch "${scope}"; then
			source="launch env"
			mode="${!mode_var-}"
			list="${!list_var-}"
			_mcp_meta_env_launch_set "${mode}" || mode=""
			_mcp_meta_env_launch_set "${list}" || list=""
		elif [ "${ignore_meta}" = "false" ] && [ -n "${meta_mode}${meta_list}" ]; then
			source="server.meta.json"
			mode="${meta_mode}"
			list="${meta_list}"
		else
			source="default"
			mode=""
			list=""
		fi
		mode="$(printf '%s' "${mode:-${default_mode}}" | tr '[:upper:]' '[:lower:]' | tr -c 'a-z_-' '?' | cut -c1-32)"
		printf 'policy\t%s\t%s\t%s\n' "${scope}" "${mode}" "${source}"

		local inherit_allow_var="MCPBASH_${scope}_ENV_INHERIT_ALLOW"
		if [ "${mode}" = "inherit" ] && [ "${!inherit_allow_var:-false}" != "true" ]; then
			printf 'inherit\t%s\n' "${scope}"
		fi

		[ "${mode}" = "allowlist" ] || continue
		local name state
		local -a names=()
		IFS=', ' read -r -a names <<<"${list}"
		for name in ${names[@]+"${names[@]}"}; do
			[ -n "${name}" ] || continue
			if ! [[ "${name}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
				printf 'badname\t%s\t%s\n' "${scope}" "$(printf '%s' "${name}" | tr -c 'A-Za-z0-9_' '?' | cut -c1-64)"
				continue
			fi
			if [ -z "${!name+x}" ]; then
				state="not set"
			elif [ -z "${!name}" ]; then
				state="empty"
			else
				case "${!name}" in
				'${user_config.'*) state="placeholder" ;;
				*) state="set" ;;
				esac
			fi
			printf 'name\t%s\t%s\t%s\n' "${scope}" "${name}" "${state}"
		done
	done
}
