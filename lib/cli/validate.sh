#!/usr/bin/env bash
# CLI validate command.

set -euo pipefail

if [[ -z "${BASH_VERSION:-}" ]]; then
	printf 'Bash is required for mcp-bash validate; BASH_VERSION missing\n' >&2
	exit 1
fi

# Globals: usage() from bin, MCPBASH_PROJECT_ROOT and runtime globals set by initialize_runtime_paths.

mcp_cli_validate() {
	local project_root=""
	local fix="false"
	local json_mode="false"
	local explain_defaults="false"
	local strict="false"
	local inspector="false"
	local deprecations_as_errors="false"

	while [ $# -gt 0 ]; do
		case "$1" in
		--project-root)
			shift
			project_root="${1:-}"
			;;
		--fix)
			fix="true"
			;;
		--json)
			json_mode="true"
			;;
		--explain-defaults)
			explain_defaults="true"
			;;
		--strict)
			strict="true"
			;;
		--inspector)
			inspector="true"
			;;
		--deprecations-as-errors)
			deprecations_as_errors="true"
			;;
		--help | -h)
			cat <<'EOF'
Usage:
  mcp-bash validate [--project-root DIR] [--fix] [--json]
                     [--explain-defaults] [--strict] [--inspector]
                     [--deprecations-as-errors]

Validate the current MCP project structure and metadata.

Options:
  --strict     Treat warnings as errors. Deprecations are counted
               separately and do not fail --strict.
  --deprecations-as-errors
               Fail when the project uses APIs that change in the next
               major version (see `mcp-bash migrate`).
  --inspector  Show command to run MCP Inspector CLI for strict schema
               validation. The inspector catches schema violations that
               basic validation may miss.
EOF
			exit 0
			;;
		*)
			usage
			exit 1
			;;
		esac
		shift
	done

	if [ -n "${project_root}" ]; then
		MCPBASH_PROJECT_ROOT="${project_root}"
		export MCPBASH_PROJECT_ROOT
	fi

	require_bash_runtime
	initialize_runtime_paths
	mcp_runtime_init_paths "cli"
	mcp_runtime_detect_json_tool
	mcp_runtime_load_server_meta

	project_root="${MCPBASH_PROJECT_ROOT}"
	if [ "${json_mode}" != "true" ]; then
		printf 'Validating project at %s...\n\n' "${project_root}"
	fi

	local errors=0
	local warnings=0
	local fixes_applied=0
	local json_tool_available="false"
	local tools_root="${MCPBASH_TOOLS_DIR}"
	local prompts_root="${MCPBASH_PROMPTS_DIR}"
	local resources_root="${MCPBASH_RESOURCES_DIR}"

	if [ "${MCPBASH_JSON_TOOL:-none}" != "none" ] && [ -n "${MCPBASH_JSON_TOOL_BIN:-}" ]; then
		json_tool_available="true"
	fi

	local output counts
	local messages_json="[]"
	local server_defaults=""

	if [ "${explain_defaults}" = "true" ] || [ "${json_mode}" = "true" ]; then
		server_defaults="$(printf '{\"name\":%s,\"title\":%s,\"version\":%s}' \
			"$(mcp_json_escape_string "${MCPBASH_SERVER_NAME}")" \
			"$(mcp_json_escape_string "${MCPBASH_SERVER_TITLE}")" \
			"$(mcp_json_escape_string "${MCPBASH_SERVER_VERSION}")")"
	fi

	append_to_array() {
		local arr="$1"
		local item="$2"
		if [ "${arr}" = "[]" ]; then
			printf '[%s]' "${item}"
		else
			printf '%s,%s]' "${arr%"]"}" "${item}"
		fi
	}

	append_messages() {
		local section="$1"
		local lines="$2"
		local arr="$3"
		while IFS= read -r line; do
			[ -z "${line}" ] && continue
			local symbol="${line%% *}"
			local msg="${line#"${symbol} "}"
			# ℹ is a note: level "info", like a pass, with the symbol dropped.
			if [ "${symbol}" != "✗" ] && [ "${symbol}" != "⚠" ] && [ "${symbol}" != "✓" ] && [ "${symbol}" != "ℹ" ]; then
				msg="${line}"
				symbol="✓"
			fi
			local level="info"
			case "${symbol}" in
			✗) level="error" ;;
			⚠) level="warning" ;;
			*) level="info" ;;
			esac
			local obj
			obj="$(printf '{"level":"%s","section":"%s","message":%s}' "${level}" "${section}" "$(mcp_json_quote_text "${msg}")")"
			arr="$(append_to_array "${arr}" "${obj}")"
		done <<<"${lines}"
		printf '%s' "${arr}"
	}

	output="$(mcp_validate_server_meta "${json_tool_available}")"
	if [ "${json_mode}" != "true" ]; then
		printf '%s\n' "${output}" | sed '$d'
	else
		messages_json="$(append_messages "server" "$(printf '%s\n' "${output}" | sed '$d')" "${messages_json}")"
	fi
	counts="$(printf '%s\n' "${output}" | tail -n 1)"
	# shellcheck disable=SC2086  # Intentional splitting of counts
	set -- ${counts}
	errors=$((errors + $1))
	warnings=$((warnings + $2))

	output="$(mcp_validate_tools "${tools_root}" "${json_tool_available}" "${fix}")"
	if [ "${json_mode}" != "true" ]; then
		printf '%s\n' "${output}" | sed '$d'
	else
		messages_json="$(append_messages "tools" "$(printf '%s\n' "${output}" | sed '$d')" "${messages_json}")"
	fi
	counts="$(printf '%s\n' "${output}" | tail -n 1)"
	# shellcheck disable=SC2086  # Intentional splitting of counts
	set -- ${counts}
	errors=$((errors + $1))
	warnings=$((warnings + $2))
	fixes_applied=$((fixes_applied + $3))

	output="$(mcp_validate_prompts "${prompts_root}" "${json_tool_available}" "${fix}")"
	if [ "${json_mode}" != "true" ]; then
		printf '%s\n' "${output}" | sed '$d'
	else
		messages_json="$(append_messages "prompts" "$(printf '%s\n' "${output}" | sed '$d')" "${messages_json}")"
	fi
	counts="$(printf '%s\n' "${output}" | tail -n 1)"
	# shellcheck disable=SC2086  # Intentional splitting of counts
	set -- ${counts}
	errors=$((errors + $1))
	warnings=$((warnings + $2))
	fixes_applied=$((fixes_applied + $3))

	output="$(mcp_validate_resources "${resources_root}" "${json_tool_available}" "${fix}")"
	if [ "${json_mode}" != "true" ]; then
		printf '%s\n' "${output}" | sed '$d'
	else
		messages_json="$(append_messages "resources" "$(printf '%s\n' "${output}" | sed '$d')" "${messages_json}")"
	fi
	counts="$(printf '%s\n' "${output}" | tail -n 1)"
	# shellcheck disable=SC2086  # Intentional splitting of counts
	set -- ${counts}
	errors=$((errors + $1))
	warnings=$((warnings + $2))
	fixes_applied=$((fixes_applied + $3))

	# Deprecations: uses of APIs that change in the next major version.
	# Counted on their own (not as warnings), so --strict keeps its meaning.
	local deprecations=0
	if [ -f "${MCPBASH_HOME}/lib/migrate_rules.sh" ]; then
		# shellcheck source=../migrate_rules.sh disable=SC1091
		. "${MCPBASH_HOME}/lib/migrate_rules.sh"
		local findings
		findings="$(mcp_migrate_detect_resolved "${project_root}" --validate 2>/dev/null || true)"
		if [ -n "${findings}" ]; then
			# Rules whose old code keeps running in 2.0 but does the wrong
			# thing, with no error: marked, and summed up below.
			local silent_rules silent=0 silent_ids="" is_silent
			silent_rules=" $(mcp_migrate_silent_rules | tr '\n' ' ') "
			local f_id f_kind f_file f_line f_summary f_fix f_text
			while IFS=$'\t' read -r f_id f_kind f_file f_line f_summary f_fix f_text; do
				[ -n "${f_id}" ] || continue
				deprecations=$((deprecations + 1))
				is_silent=false
				case "${silent_rules}" in *" ${f_id} "*)
					is_silent=true
					silent=$((silent + 1))
					case " ${silent_ids} " in *" ${f_id} "*) ;; *) silent_ids="${silent_ids:+${silent_ids} }${f_id}" ;; esac
					;;
				esac
				if [ "${json_mode}" = "true" ]; then
					local obj
					obj="$(printf '{"level":"deprecation","section":"deprecations","id":%s,"kind":%s,"file":%s,"line":%s,"message":%s,"fix":%s,"text":%s,"silent":%s}' \
						"$(mcp_json_quote_text "${f_id}")" "$(mcp_json_quote_text "${f_kind}")" \
						"$(mcp_json_quote_text "${f_file}")" "${f_line}" \
						"$(mcp_json_quote_text "${f_summary}")" "$(mcp_json_quote_text "${f_fix}")" \
						"$(mcp_json_quote_text "${f_text}")" "${is_silent}")"
					messages_json="$(append_to_array "${messages_json}" "${obj}")"
				elif [ "${is_silent}" = true ]; then
					printf '✗ %s:%s %s [%s]\n    fails silently in 2.0: the tool keeps running but takes the wrong branch, with no error\n    fix: %s\n' \
						"${f_file}" "${f_line}" "${f_summary}" "${f_id}" "${f_fix}"
				else
					printf '⚠ %s:%s %s [%s]\n    fix: %s\n' "${f_file}" "${f_line}" "${f_summary}" "${f_id}" "${f_fix}"
				fi
			done <<<"${findings}"
			if [ "${silent}" -gt 0 ] && [ "${json_mode}" != "true" ]; then
				printf '\n✗ %d deprecation(s); %d of them fail(s) silently in mcp-bash 2.0 (%s): fix those before upgrading. See: mcp-bash migrate --explain ID\n' \
					"${deprecations}" "${silent}" "${silent_ids}"
			fi
		fi
	fi
	if [ "${deprecations_as_errors}" = "true" ]; then
		errors=$((errors + deprecations))
	fi

	if [ "${json_mode}" != "true" ]; then
		printf '\n'
	fi

	if [ "${fix}" = "true" ]; then
		if [ "${errors}" -gt 0 ]; then
			printf '%d error(s) remaining. Please fix manually.\n' "${errors}"
			exit 1
		fi
		if [ "${fixes_applied}" -gt 0 ]; then
			printf 'All remaining issues are warnings. %d file(s) were auto-fixed.\n' "${fixes_applied}"
		else
			printf 'All checks passed (no errors).\n'
		fi
		exit 0
	fi

	if [ "${json_mode}" = "true" ]; then
		local exit_errors="${errors}"
		if [ "${strict}" = "true" ] && [ "${warnings}" -gt 0 ]; then
			exit_errors=$((exit_errors + warnings))
		fi
		local payload=""
		if [ "${json_tool_available}" = "true" ]; then
			payload="$("${MCPBASH_JSON_TOOL_BIN}" -n \
				--arg projectRoot "${project_root}" \
				--arg errors "${errors}" \
				--arg warnings "${warnings}" \
				--arg fixes "${fixes_applied}" \
				--arg deprecations "${deprecations}" \
				--arg strict "${strict}" \
				--argjson defaults "${server_defaults:-"{}"}" \
				--argjson messages "${messages_json}" \
				'$ARGS.named
				| .errors = (.errors|tonumber)
				| .warnings = (.warnings|tonumber)
				| .fixesApplied = (.fixes|tonumber)
				| .deprecations = (.deprecations|tonumber)
				| .strict = (.strict == "true")
				| .defaults = $defaults
				| .messages = $messages' 2>/dev/null || printf '')"
		fi
		if [ -z "${payload}" ]; then
			payload="$(
				cat <<EOF
{
  "projectRoot": $(mcp_json_escape_string "${project_root}"),
  "errors": ${errors},
  "warnings": ${warnings},
  "fixesApplied": ${fixes_applied},
  "deprecations": ${deprecations},
  "strict": ${strict},
  "defaults": ${server_defaults:-"{}"},
  "messages": ${messages_json}
}
EOF
			)"
			# Normalize occasional double-closer patterns if server_defaults carries an extra brace (bash 3-compatible).
			payload="$(printf '%s\n' "${payload}" | sed 's/}},/},/g')"
		fi
		printf '%s\n' "${payload}"
		if [ "${exit_errors}" -gt 0 ]; then
			exit 1
		fi
		exit 0
	fi

	if [ "${explain_defaults}" = "true" ] && [ -n "${server_defaults}" ]; then
		printf 'Defaults used: name=%s, title=%s, version=%s\n' "${MCPBASH_SERVER_NAME}" "${MCPBASH_SERVER_TITLE}" "${MCPBASH_SERVER_VERSION}"
	fi

	if [ "${strict}" = "true" ] && [ "${warnings}" -gt 0 ]; then
		errors=$((errors + warnings))
	fi

	if [ "${errors}" -gt 0 ]; then
		printf '%d error(s) found. Run '\''mcp-bash validate --fix'\'' to fix auto-fixable issues.\n' "${errors}"
		exit 1
	fi

	printf 'All checks passed (warnings: %d).\n' "${warnings}"
	if [ "${deprecations}" -gt 0 ]; then
		printf '%d deprecation(s): APIs that change in mcp-bash 2.0. Run '\''mcp-bash migrate'\'' for details.\n' "${deprecations}"
	fi

	# Show MCP Inspector instructions if requested
	if [ "${inspector}" = "true" ]; then
		printf '\n'
		printf 'To run MCP Inspector for strict schema validation:\n\n'

		local mcp_bash_bin

		# Use project's bin/mcp-bash if it exists, otherwise use framework's
		if [ -x "${project_root}/bin/mcp-bash" ]; then
			mcp_bash_bin="${project_root}/bin/mcp-bash"
		elif [ -x "${MCPBASH_HOME}/bin/mcp-bash" ]; then
			mcp_bash_bin="${MCPBASH_HOME}/bin/mcp-bash"
		else
			mcp_bash_bin="./bin/mcp-bash"
		fi

		printf '  npx @modelcontextprotocol/inspector --cli --transport stdio -- \\\n'
		printf '    MCPBASH_PROJECT_ROOT="%s" %s\n\n' "${project_root}" "${mcp_bash_bin}"
		printf 'This opens an interactive CLI where you can test methods like:\n'
		printf '  tools/list, resources/list, prompts/list, initialize\n\n'
		printf 'Schema violations will be reported with exact field paths.\n'
		printf 'See docs/INSPECTOR.md for more details.\n'
	fi

	exit 0
}
