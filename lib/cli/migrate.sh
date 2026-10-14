#!/usr/bin/env bash
# CLI migrate command: find (and with --write, fix) uses of APIs that change
# in the next major version. Rules live in lib/cli/migrations/.

set -euo pipefail

if [[ -z "${BASH_VERSION:-}" ]]; then
	printf 'Bash is required for mcp-bash migrate; BASH_VERSION missing\n' >&2
	exit 1
fi

# Exit codes: 0 nothing pending, 1 auto fixes pending, 2 manual work pending
# (wins over 1), 3 usage or error.

mcp_cli_migrate_usage() {
	cat <<'EOF'
Usage:
  mcp-bash migrate [--project-root DIR] [--write [--force]]
                   [--only ID,..] [--skip ID,..] [--json]
  mcp-bash migrate --list
  mcp-bash migrate --explain ID

Find uses of APIs that change in the next major version of mcp-bash.
By default nothing is changed (check mode).

Options:
  --write     Apply the automatic fixes, then record the API version in
              server.d/server.meta.json once nothing else is pending.
              Refuses a git tree with uncommitted changes unless --force;
              outside git, keeps a .bak copy of every file it changes.
  --only/--skip  Limit the rules (comma-separated ids; see --list).
  --json      Machine-readable report.

Exit status: 0 nothing pending, 1 automatic fixes pending, 2 manual work
pending, 3 usage error.
EOF
}

# Print one field of a rule (sourced in a subshell).
mcp_cli_migrate_rule_field() {
	local rule="$1" field="$2"
	(
		# shellcheck disable=SC2034  # defaults the sourced rule may override
		MIG_ID="" MIG_API="" MIG_KIND="manual" MIG_SUMMARY="" MIG_FIX="" MIG_SCOPE="" MIG_REPLACEMENT="frozen"
		# shellcheck disable=SC1090
		. "${rule}" >/dev/null 2>&1 || exit 0
		case "${field}" in
		api) printf '%s' "${MIG_API}" ;;
		kind) printf '%s' "${MIG_KIND}" ;;
		summary) printf '%s' "${MIG_SUMMARY}" ;;
		fix) printf '%s' "${MIG_FIX}" ;;
		scope) printf '%s' "${MIG_SCOPE}" ;;
		replacement) printf '%s' "${MIG_REPLACEMENT}" ;;
		apply) declare -F mig_apply >/dev/null 2>&1 && printf 'yes' || printf 'no' ;;
		esac
	)
}

# Apply one rule's rewrite to FILE at LINE.
mcp_cli_migrate_apply_one() {
	local rule="$1" file="$2" line="$3"
	(
		# shellcheck disable=SC1090
		. "${rule}" >/dev/null 2>&1 || exit 1
		declare -F mig_apply >/dev/null 2>&1 || exit 1
		mig_apply "${file}" "${line}"
	)
}

mcp_cli_migrate() {
	local project_root="" write="false" force="false" json_mode="false"
	local only="" skip="" list="false" explain=""

	while [ $# -gt 0 ]; do
		case "$1" in
		--project-root)
			shift
			project_root="${1:-}"
			;;
		--write) write="true" ;;
		--force) force="true" ;;
		--json) json_mode="true" ;;
		--only)
			shift
			only="${1:-}"
			;;
		--skip)
			shift
			skip="${1:-}"
			;;
		--list) list="true" ;;
		--explain)
			shift
			explain="${1:-}"
			;;
		--help | -h)
			mcp_cli_migrate_usage
			exit 0
			;;
		*)
			mcp_cli_migrate_usage >&2
			exit 3
			;;
		esac
		shift
	done

	# shellcheck source=../migrate_rules.sh disable=SC1091
	. "${MCPBASH_HOME}/lib/migrate_rules.sh"

	local rule id
	if [ "${list}" = "true" ]; then
		while IFS= read -r rule; do
			id="${rule##*/}"
			id="${id%.sh}"
			printf '%-22s API %s  %-6s  %s\n' "${id}" "$(mcp_cli_migrate_rule_field "${rule}" api)" \
				"$([ "$(mcp_cli_migrate_rule_field "${rule}" apply)" = "yes" ] && printf 'auto' || printf 'manual')" \
				"$(mcp_cli_migrate_rule_field "${rule}" summary)"
		done < <(mcp_migrate_rule_files)
		exit 0
	fi

	if [ -n "${explain}" ]; then
		rule="$(mcp_migrate_rules_dir)/${explain}.sh"
		if [ ! -f "${rule}" ]; then
			printf 'Unknown rule: %s (see mcp-bash migrate --list)\n' "${explain}" >&2
			exit 3
		fi
		printf '%s (API %s)\n' "${explain}" "$(mcp_cli_migrate_rule_field "${rule}" api)"
		printf '  What: %s\n' "$(mcp_cli_migrate_rule_field "${rule}" summary)"
		printf '  Fix:  %s\n' "$(mcp_cli_migrate_rule_field "${rule}" fix)"
		if [ "$(mcp_cli_migrate_rule_field "${rule}" replacement)" = "none" ]; then
			printf '  The replacement arrives with the next major version; nothing to change yet.\n'
		elif [ "$(mcp_cli_migrate_rule_field "${rule}" apply)" = "yes" ]; then
			printf '  --write rewrites the unambiguous cases; others are reported as manual.\n'
		else
			printf '  Always manual.\n'
		fi
		exit 0
	fi

	if [ -n "${project_root}" ]; then
		MCPBASH_PROJECT_ROOT="${project_root}"
		export MCPBASH_PROJECT_ROOT
	fi
	require_bash_runtime
	initialize_runtime_paths
	mcp_runtime_init_paths "cli"
	mcp_runtime_detect_json_tool
	project_root="${MCPBASH_PROJECT_ROOT}"

	local detect_args=()
	[ -n "${only}" ] && detect_args+=(--only "${only}")
	[ -n "${skip}" ] && detect_args+=(--skip "${skip}")

	local findings applied=0
	findings="$(mcp_migrate_detect_resolved "${project_root}" ${detect_args[@]+"${detect_args[@]}"} || true)"

	# A vendored runtime is what the project's tools actually run against. If
	# it predates the frozen helpers, rewritten code would call functions that
	# don't exist there.
	local vendored_sdk="${project_root}/.mcp-bash/sdk/tool-sdk.sh" vendor_too_old="false"
	if [ -f "${vendored_sdk}" ] && ! grep -qE '^mcp_result_json\(\)' "${vendored_sdk}"; then
		vendor_too_old="true"
	fi

	if [ "${write}" = "true" ] && [ "${vendor_too_old}" = "true" ] && [ "${force}" != "true" ]; then
		printf 'mcp-bash migrate: the vendored runtime in %s/.mcp-bash predates the helpers this migration writes (mcp_result_json, mcp_fail --type).\n' "${project_root}" >&2
		printf 'Run '\''mcp-bash vendor --upgrade'\'' first, then migrate (or use --force).\n' >&2
		exit 3
	fi

	if [ "${write}" = "true" ]; then
		local in_git="false"
		if command -v git >/dev/null 2>&1 && git -C "${project_root}" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
			in_git="true"
			if [ "${force}" != "true" ] && [ -n "$(git -C "${project_root}" status --porcelain -- . 2>/dev/null)" ]; then
				printf 'mcp-bash migrate: %s has uncommitted changes; commit or stash them first (or use --force).\n' "${project_root}" >&2
				exit 3
			fi
		fi

		local dir
		dir="$(mcp_migrate_rules_dir)"
		# Auto findings, by file, bottom-up so earlier line numbers stay valid.
		local f_id f_kind f_file f_line _rest backed_up=" "
		while IFS=$'\t' read -r f_id f_kind f_file f_line _rest; do
			[ -n "${f_id}" ] || continue
			local target="${project_root}/${f_file}"
			case "${f_file}" in /*) target="${f_file}" ;; esac
			if [ "${in_git}" != "true" ]; then
				case "${backed_up}" in
				*" ${target} "*) ;;
				*)
					cp -p "${target}" "${target}.bak"
					backed_up="${backed_up}${target} "
					;;
				esac
			fi
			if mcp_cli_migrate_apply_one "${dir}/${f_id}.sh" "${target}" "${f_line}"; then
				applied=$((applied + 1))
			fi
		done < <(printf '%s\n' "${findings}" | awk -F'\t' '$2 == "auto" && $1 != "2-marker"' | LC_ALL=C sort -t$'\t' -k3,3 -k4,4nr)

		findings="$(mcp_migrate_detect_resolved "${project_root}" ${detect_args[@]+"${detect_args[@]}"} || true)"
		# Record the API version once nothing but the marker is pending.
		local remaining_other
		# Advisory findings (a note, not a change migrate expects) don't block it.
		remaining_other="$(printf '%s\n' "${findings}" | awk -F'\t' '$1 != "" && $1 != "2-marker" && $2 != "advisory"' | wc -l | tr -d ' ')"
		if [ "${remaining_other}" -eq 0 ] && printf '%s\n' "${findings}" | grep -q '^2-marker	'; then
			local meta="${MCPBASH_SERVER_DIR:-${project_root}/server.d}/server.meta.json"
			if [ "${in_git}" != "true" ]; then
				case "${backed_up}" in *" ${meta} "*) ;; *) cp -p "${meta}" "${meta}.bak" ;; esac
			fi
			mcp_cli_migrate_apply_one "${dir}/2-marker.sh" "${meta}" 1 && applied=$((applied + 1))
			findings="$(mcp_migrate_detect_resolved "${project_root}" ${detect_args[@]+"${detect_args[@]}"} || true)"
		fi
	fi

	# A running or restarted server reuses its tools cache while it is younger
	# than the TTL, and would keep checking results against the tool metadata
	# migrate just rewrote. Invalidate it, and the startup scan's record, when
	# anything changed. Only those: the other registry files don't depend on
	# what migrate rewrites. A file the project tracks in git is expired (its
	# mtime set far in the past) rather than deleted, so the migration commit
	# shows no deletion.
	local cache_cleared="false"
	if [ "${write}" = "true" ] && [ "${applied}" -gt 0 ]; then
		local registry_dir="${MCPBASH_REGISTRY_DIR:-${project_root}/.registry}" cache_file target
		for cache_file in tools.json scan/removed-api.findings scan/removed-api.scan scan/removed-api.attempt; do
			target="${registry_dir}/${cache_file}"
			[ -e "${target}" ] || continue
			if [ "${in_git:-false}" = "true" ] && git -C "${project_root}" ls-files --error-unmatch -- "${target}" >/dev/null 2>&1; then
				# A tracked findings file is emptied: its old entries would
				# otherwise still feed the note until the next scan.
				case "${cache_file}" in
				*.findings) : >"${target}" && cache_cleared="true" ;;
				*) touch -t 197001020000 "${target}" && cache_cleared="true" ;;
				esac
			else
				rm -f "${target}" && cache_cleared="true"
			fi
		done
	fi

	local auto=0 manual=0
	manual="$(printf '%s\n' "${findings}" | awk -F'\t' '$2 == "manual"' | wc -l | tr -d ' ')"
	# The marker is only set once nothing else is pending, so while manual
	# work remains it isn't an automatic fix --write can apply.
	if [ "${manual}" -gt 0 ]; then
		auto="$(printf '%s\n' "${findings}" | awk -F'\t' '$2 == "auto" && $1 != "2-marker"' | wc -l | tr -d ' ')"
	else
		auto="$(printf '%s\n' "${findings}" | awk -F'\t' '$2 == "auto"' | wc -l | tr -d ' ')"
	fi

	if [ "${json_mode}" = "true" ]; then
		local items="" f_summary f_fix f_text
		while IFS=$'\t' read -r f_id f_kind f_file f_line f_summary f_fix f_text; do
			[ -n "${f_id}" ] || continue
			[ -n "${items}" ] && items="${items},"
			items="${items}$(printf '{"id":%s,"kind":%s,"file":%s,"line":%s,"summary":%s,"fix":%s,"text":%s}' \
				"$(mcp_json_quote_text "${f_id}")" "$(mcp_json_quote_text "${f_kind}")" \
				"$(mcp_json_quote_text "${f_file}")" "${f_line:-0}" \
				"$(mcp_json_quote_text "${f_summary}")" "$(mcp_json_quote_text "${f_fix}")" \
				"$(mcp_json_quote_text "${f_text}")")"
		done <<<"${findings}"
		printf '{"projectRoot":%s,"written":%s,"applied":%s,"registryCacheCleared":%s,"vendoredRuntimeTooOld":%s,"pending":{"auto":%s,"manual":%s},"findings":[%s]}\n' \
			"$(mcp_json_quote_text "${project_root}")" "${write}" "${applied}" "${cache_cleared}" "${vendor_too_old}" "${auto}" "${manual}" "${items}"
	else
		if [ "${write}" = "true" ]; then
			printf 'Applied %d automatic fix(es).\n' "${applied}"
			if [ "${cache_cleared}" = "true" ]; then
				printf 'Invalidated the tools cache; the server rebuilds it on its next start. Restart running servers to pick up the changes.\n'
			fi
		fi
		if [ -n "${findings}" ]; then
			local f_summary f_fix f_text
			while IFS=$'\t' read -r f_id f_kind f_file f_line f_summary f_fix f_text; do
				[ -n "${f_id}" ] || continue
				printf '  [%s] %s:%s %s [%s]\n      fix: %s\n' "${f_kind}" "${f_file}" "${f_line}" "${f_summary}" "${f_id}" "${f_fix}"
			done <<<"${findings}"
		fi
		if [ "${vendor_too_old}" = "true" ]; then
			printf 'Note: the vendored runtime (.mcp-bash) predates mcp_result_json and mcp_fail --type; run '\''mcp-bash vendor --upgrade'\'' before --write.\n'
		fi
		if [ "${auto}" -eq 0 ] && [ "${manual}" -eq 0 ]; then
			printf 'Nothing to migrate.\n'
		else
			printf '%d automatic, %d manual pending.' "${auto}" "${manual}"
			[ "${auto}" -gt 0 ] && printf ' Run '\''mcp-bash migrate --write'\'' to apply the automatic fixes.'
			printf '\n'
		fi
	fi

	if [ "${manual}" -gt 0 ]; then
		exit 2
	fi
	if [ "${auto}" -gt 0 ]; then
		exit 1
	fi
	exit 0
}
