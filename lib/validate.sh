#!/usr/bin/env bash
# Validation helpers for project structure and metadata.

set -euo pipefail

mcp_validate_server_meta() {
	local json_tool_available="$1"
	local errors=0
	local warnings=0
	local server_meta="${MCPBASH_SERVER_DIR}/server.meta.json"

	if [ -f "${server_meta}" ]; then
		if [ "${json_tool_available}" = "true" ]; then
			if ! "${MCPBASH_JSON_TOOL_BIN}" -e '.' "${server_meta}" >/dev/null 2>&1; then
				printf '✗ server.d/server.meta.json - invalid JSON\n'
				errors=$((errors + 1))
			else
				local srv_name
				srv_name="$("${MCPBASH_JSON_TOOL_BIN}" -r '.name // ""' "${server_meta}" 2>/dev/null || printf '')"
				if [ -z "${srv_name}" ]; then
					printf '✗ server.d/server.meta.json - missing required "name" field\n'
					errors=$((errors + 1))
				else
					printf '✓ server.d/server.meta.json - valid\n'
				fi
			fi
		else
			printf '⚠ server.d/server.meta.json - skipped JSON validation (no jq/gojq)\n'
			warnings=$((warnings + 1))
		fi
	else
		printf '⚠ server.d/server.meta.json - missing (using smart defaults)\n'
		warnings=$((warnings + 1))
	fi

	printf '%s %s\n' "${errors}" "${warnings}"
}

mcp_validate_tools() {
	local tools_root="$1"
	local json_tool_available="$2"
	local fix="$3"
	local errors=0
	local warnings=0
	local fixes=0

	if [ -d "${tools_root}" ]; then
		while IFS= read -r tool_dir; do
			[ -d "${tool_dir}" ] || continue
			local tool_name
			tool_name="$(basename "${tool_dir}")"
			local meta_path="${tool_dir}/tool.meta.json"
			local script_path="${tool_dir}/tool.sh"
			local rel_meta="tools/${tool_name}/tool.meta.json"
			local rel_script="tools/${tool_name}/tool.sh"

			if [ -f "${meta_path}" ]; then
				if [ "${json_tool_available}" = "true" ]; then
					if ! "${MCPBASH_JSON_TOOL_BIN}" -e '.' "${meta_path}" >/dev/null 2>&1; then
						printf '✗ %s - invalid JSON\n' "${rel_meta}"
						errors=$((errors + 1))
					else
						local t_name t_desc has_schema
						t_name="$("${MCPBASH_JSON_TOOL_BIN}" -r '.name // ""' "${meta_path}" 2>/dev/null || printf '')"
						t_desc="$("${MCPBASH_JSON_TOOL_BIN}" -r '.description // ""' "${meta_path}" 2>/dev/null || printf '')"
						has_schema="$("${MCPBASH_JSON_TOOL_BIN}" -r 'if (.inputSchema? // .arguments? // {}) | (has("type") or has("properties")) then "yes" else "" end' "${meta_path}" 2>/dev/null || printf '')"

						if [ -z "${t_name}" ]; then
							printf '✗ %s - missing required "name"\n' "${rel_meta}"
							errors=$((errors + 1))
						fi
						if [ -z "${t_desc}" ]; then
							printf '⚠ %s - missing "description"\n' "${rel_meta}"
							warnings=$((warnings + 1))
						fi
						if [ -z "${has_schema}" ]; then
							printf '⚠ %s - inputSchema has no "type" or "properties"\n' "${rel_meta}"
							warnings=$((warnings + 1))
						fi
						if [ -n "${t_name}" ]; then
							printf '✓ %s - valid\n' "${rel_meta}"
							if [[ "${t_name}" != *.* ]]; then
								printf '⚠ %s - tool name lacks namespace prefix (recommended: serverName.toolName)\n' "${rel_meta}"
								warnings=$((warnings + 1))
							fi
							if [[ ! "${t_name}" =~ ^[A-Za-z][A-Za-z0-9]*(\.[A-Za-z][A-Za-z0-9]*)*$ ]]; then
								printf '⚠ %s - tool name contains non-standard characters (expected namespace.camelCase)\n' "${rel_meta}"
								warnings=$((warnings + 1))
							fi
							if [ "${#t_name}" -gt 64 ]; then
								printf '⚠ %s - tool name exceeds 64 characters\n' "${rel_meta}"
								warnings=$((warnings + 1))
							fi
						fi
						if [ -n "${t_name}" ] && [ "${t_name}" != "${tool_name}" ]; then
							printf '⚠ tools/%s - directory name does not match tool.meta.json name "%s"\n' "${tool_name}" "${t_name}"
							warnings=$((warnings + 1))
						fi
					fi
				else
					printf '⚠ %s - skipped JSON validation (no jq/gojq)\n' "${rel_meta}"
					warnings=$((warnings + 1))
				fi
			else
				printf '✗ %s - missing\n' "${rel_meta}"
				errors=$((errors + 1))
			fi

			if [ -f "${script_path}" ]; then
				if [ -x "${script_path}" ]; then
					printf '✓ %s - executable\n' "${rel_script}"
				else
					if [ "${fix}" = "true" ]; then
						if [ -L "${script_path}" ]; then
							printf '⚠ %s - not executable (symlink; skipped auto-fix, please inspect target)\n' "${rel_script}"
							warnings=$((warnings + 1))
						elif chmod +x "${script_path}"; then
							printf '✓ %s - fixed: made executable\n' "${rel_script}"
							fixes=$((fixes + 1))
						else
							printf '✗ %s - not executable (chmod failed)\n' "${rel_script}"
							errors=$((errors + 1))
						fi
					else
						printf '✗ %s - not executable\n' "${rel_script}"
						errors=$((errors + 1))
					fi
				fi

				local first_line
				first_line="$(head -n 1 "${script_path}" 2>/dev/null || printf '')"
				case "${first_line}" in
				'#!'*) ;;
				*)
					printf '⚠ %s - missing shebang\n' "${rel_script}"
					warnings=$((warnings + 1))
					;;
				esac
			else
				printf '✗ %s - missing\n' "${rel_script}"
				errors=$((errors + 1))
			fi
		done < <(find "${tools_root}" -mindepth 1 -maxdepth 1 -type d | sort)
	fi

	printf '%s %s %s\n' "${errors}" "${warnings}" "${fixes}"
}

mcp_validate_prompts() {
	local prompts_root="$1"
	local json_tool_available="$2"
	local fix="$3"
	local errors=0
	local warnings=0
	local fixes=0

	if [ -d "${prompts_root}" ]; then
		while IFS= read -r prompt_dir; do
			[ -d "${prompt_dir}" ] || continue
			local prompt_name
			prompt_name="$(basename "${prompt_dir}")"
			local meta_path="${prompt_dir}/${prompt_name}.meta.json"
			local txt_path="${prompt_dir}/${prompt_name}.txt"
			local sh_path="${prompt_dir}/${prompt_name}.sh"
			local rel_meta="prompts/${prompt_name}/${prompt_name}.meta.json"

			if [ -f "${meta_path}" ]; then
				if [ "${json_tool_available}" = "true" ]; then
					if ! "${MCPBASH_JSON_TOOL_BIN}" -e '.' "${meta_path}" >/dev/null 2>&1; then
						printf '✗ %s - invalid JSON\n' "${rel_meta}"
						errors=$((errors + 1))
					else
						local p_name p_desc
						p_name="$("${MCPBASH_JSON_TOOL_BIN}" -r '.name // ""' "${meta_path}" 2>/dev/null || printf '')"
						p_desc="$("${MCPBASH_JSON_TOOL_BIN}" -r '.description // ""' "${meta_path}" 2>/dev/null || printf '')"
						if [ -z "${p_name}" ]; then
							printf '✗ %s - missing required "name"\n' "${rel_meta}"
							errors=$((errors + 1))
						fi
						if [ -z "${p_desc}" ]; then
							printf '⚠ %s - missing "description"\n' "${rel_meta}"
							warnings=$((warnings + 1))
						fi
						if [ -n "${p_name}" ]; then
							printf '✓ %s - valid\n' "${rel_meta}"
						fi
					fi
				else
					printf '⚠ %s - skipped JSON validation (no jq/gojq)\n' "${rel_meta}"
					warnings=$((warnings + 1))
				fi
			else
				printf '✗ %s - missing\n' "${rel_meta}"
				errors=$((errors + 1))
			fi

			if [ ! -f "${txt_path}" ] && [ ! -f "${sh_path}" ]; then
				printf '✗ prompts/%s - missing prompt.txt or prompt.sh\n' "${prompt_name}"
				errors=$((errors + 1))
			fi

			if [ -f "${sh_path}" ]; then
				if [ -x "${sh_path}" ]; then
					printf '✓ prompts/%s/%s.sh - executable\n' "${prompt_name}" "${prompt_name}"
				else
					if [ "${fix}" = "true" ]; then
						if [ -L "${sh_path}" ]; then
							printf '⚠ prompts/%s/%s.sh - not executable (symlink; skipped auto-fix, please inspect target)\n' "${prompt_name}" "${prompt_name}"
							warnings=$((warnings + 1))
						elif chmod +x "${sh_path}"; then
							printf '✓ prompts/%s/%s.sh - fixed: made executable\n' "${prompt_name}" "${prompt_name}"
							fixes=$((fixes + 1))
						else
							printf '✗ prompts/%s/%s.sh - not executable (chmod failed)\n' "${prompt_name}" "${prompt_name}"
							errors=$((errors + 1))
						fi
					else
						printf '✗ prompts/%s/%s.sh - not executable\n' "${prompt_name}" "${prompt_name}"
						errors=$((errors + 1))
					fi
				fi
			fi
		done < <(find "${prompts_root}" -mindepth 1 -maxdepth 1 -type d | sort)
	fi

	printf '%s %s %s\n' "${errors}" "${warnings}" "${fixes}"
}

mcp_validate_resources() {
	local resources_root="$1"
	local json_tool_available="$2"
	local fix="$3"
	local errors=0
	local warnings=0
	local fixes=0

	if [ -d "${resources_root}" ]; then
		while IFS= read -r res_dir; do
			[ -d "${res_dir}" ] || continue
			local res_name
			res_name="$(basename "${res_dir}")"
			local meta_path="${res_dir}/${res_name}.meta.json"
			local sh_path="${res_dir}/${res_name}.sh"
			local rel_meta="resources/${res_name}/${res_name}.meta.json"

			if [ -f "${meta_path}" ]; then
				if [ "${json_tool_available}" = "true" ]; then
					if ! "${MCPBASH_JSON_TOOL_BIN}" -e '.' "${meta_path}" >/dev/null 2>&1; then
						printf '✗ %s - invalid JSON\n' "${rel_meta}"
						errors=$((errors + 1))
					else
						local r_name r_uri
						r_name="$("${MCPBASH_JSON_TOOL_BIN}" -r '.name // ""' "${meta_path}" 2>/dev/null || printf '')"
						r_uri="$("${MCPBASH_JSON_TOOL_BIN}" -r '.uri // ""' "${meta_path}" 2>/dev/null || printf '')"
						if [ -z "${r_name}" ]; then
							printf '✗ %s - missing required "name"\n' "${rel_meta}"
							errors=$((errors + 1))
						fi
						if [ -z "${r_uri}" ]; then
							printf '✗ %s - missing required "uri"\n' "${rel_meta}"
							errors=$((errors + 1))
						else
							case "${r_uri}" in
							*://*) ;;
							*)
								printf '⚠ %s - uri does not look like scheme://...\n' "${rel_meta}"
								warnings=$((warnings + 1))
								;;
							esac
						fi
						if [ -n "${r_name}" ] && [ -n "${r_uri}" ]; then
							printf '✓ %s - valid\n' "${rel_meta}"
						fi
					fi
				else
					printf '⚠ %s - skipped JSON validation (no jq/gojq)\n' "${rel_meta}"
					warnings=$((warnings + 1))
				fi
			else
				printf '✗ %s - missing\n' "${rel_meta}"
				errors=$((errors + 1))
			fi

			if [ -f "${sh_path}" ]; then
				if [ -x "${sh_path}" ]; then
					printf '✓ resources/%s/%s.sh - executable\n' "${res_name}" "${res_name}"
				else
					if [ "${fix}" = "true" ]; then
						if [ -L "${sh_path}" ]; then
							printf '⚠ resources/%s/%s.sh - not executable (symlink; skipped auto-fix, please inspect target)\n' "${res_name}" "${res_name}"
							warnings=$((warnings + 1))
						elif chmod +x "${sh_path}"; then
							printf '✓ resources/%s/%s.sh - fixed: made executable\n' "${res_name}" "${res_name}"
							fixes=$((fixes + 1))
						else
							printf '✗ resources/%s/%s.sh - not executable (chmod failed)\n' "${res_name}" "${res_name}"
							errors=$((errors + 1))
						fi
					else
						printf '✗ resources/%s/%s.sh - not executable\n' "${res_name}" "${res_name}"
						errors=$((errors + 1))
					fi
				fi
			fi
		done < <(find "${resources_root}" -mindepth 1 -maxdepth 1 -type d | sort)
	fi

	printf '%s %s %s\n' "${errors}" "${warnings}" "${fixes}"
}
