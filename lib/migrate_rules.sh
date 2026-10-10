#!/usr/bin/env bash
# Migration rules engine: finds uses of APIs that change in a later major
# version, for `mcp-bash validate` (warnings) and `mcp-bash migrate`.
#
# Rules live in lib/cli/migrations/<apiVersion>-<id>.sh. Each rule is sourced
# in its own subshell and defines:
#   MIG_ID       stable id (equals the file name without .sh)
#   MIG_API      integer API version the rule moves to
#   MIG_KIND     default kind of its findings: auto | manual
#   MIG_SUMMARY  one line, shown with each finding
#   MIG_FIX      short replacement hint
#   MIG_SCOPE    file classes to scan (see mcp_migrate_files)
#   MIG_VALIDATE 0 to keep the rule out of `validate` (default 1)
#   mig_detect FILE   prints one finding per line: LINE<TAB>KIND<TAB>TEXT
#                     (KIND "-" = MIG_KIND; never empty: bash's read
#                     collapses consecutive tabs)
#   mig_apply FILE    optional; rewrites FILE in place (used by migrate --write)
#
# Detection is grep-based. It is not a parser: check mode may report false
# positives; rewrites are limited to unambiguous shapes.

# Rules directory.
mcp_migrate_rules_dir() {
	printf '%s/lib/cli/migrations' "${MCPBASH_HOME}"
}

# List rule files, ordered by API version, then id.
mcp_migrate_rule_files() {
	local dir
	dir="$(mcp_migrate_rules_dir)"
	[ -d "${dir}" ] || return 0
	local f
	for f in "${dir}"/*.sh; do
		[ -f "${f}" ] || continue
		printf '%s\n' "${f##*/}"
	done | LC_ALL=C sort -t- -k1,1n -k2 | while IFS= read -r f; do
		printf '%s/%s\n' "${dir}" "${f}"
	done
}

# Print the files of one class under ROOT, one relative path per line.
# Classes: project-sh (every .sh in the project) tool-sh server-sh ui-html
# tool-meta config
# Vendored runtimes, node_modules, .git and .registry are never scanned.
mcp_migrate_files() {
	local class="$1" root="$2"
	local tools="${MCPBASH_TOOLS_DIR:-${root}/tools}"
	local server="${MCPBASH_SERVER_DIR:-${root}/server.d}"
	local prune=('(' -name .mcp-bash -o -name node_modules -o -name .git -o -name .registry ')' -prune -o)
	{
		case "${class}" in
		project-sh)
			# Tools often share helper scripts (lib/, scripts/); scan them all.
			find "${root}" "${prune[@]}" -type f -name '*.sh' -print
			[ -d "${tools}" ] && find "${tools}" "${prune[@]}" -type f -name '*.sh' -print
			;;
		tool-sh)
			[ -d "${tools}" ] && find "${tools}" "${prune[@]}" -type f -name '*.sh' -print
			;;
		server-sh)
			[ -d "${server}" ] && find "${server}" "${prune[@]}" -type f -name '*.sh' -print
			local sub
			for sub in providers prompts resources completions; do
				[ -d "${root}/${sub}" ] && find "${root}/${sub}" "${prune[@]}" -type f -name '*.sh' -print
			done
			;;
		ui-html)
			[ -d "${tools}" ] && find "${tools}" "${prune[@]}" -type f -path '*/ui/*' -name '*.html' -print
			[ -d "${root}/ui" ] && find "${root}/ui" "${prune[@]}" -type f -name '*.html' -print
			;;
		tool-meta)
			[ -d "${tools}" ] && find "${tools}" "${prune[@]}" -type f -name 'tool.meta.json' -print
			;;
		config)
			[ -f "${server}/server.meta.json" ] && printf '%s\n' "${server}/server.meta.json"
			[ -f "${server}/env.sh" ] && printf '%s\n' "${server}/env.sh"
			[ -f "${root}/mcpb.conf" ] && printf '%s\n' "${root}/mcpb.conf"
			;;
		esac
	} 2>/dev/null | LC_ALL=C sort -u | while IFS= read -r f; do
		case "${f}" in
		"${root}/"*) printf '%s\n' "${f#"${root}/"}" ;;
		*) printf '%s\n' "${f}" ;;
		esac
	done
}

# Helper for rules: print LINE<TAB>-<TAB>TEXT for each non-comment line of FILE
# that uses NAME as a whole word.
mig_grep_word() {
	local name="$1" file="$2"
	mig_grep_regex "(^|[^A-Za-z0-9_])${name}([^A-Za-z0-9_]|\$)" "${file}"
}

# Helper for rules: same, for an extended regex.
mig_grep_regex() {
	local regex="$1" file="$2"
	grep -nE -- "${regex}" "${file}" 2>/dev/null | while IFS= read -r hit; do
		local line="${hit%%:*}"
		local text="${hit#*:}"
		case "${text}" in
		*[![:space:]]*) ;;
		*) continue ;;
		esac
		local lead="${text#"${text%%[![:space:]]*}"}"
		case "${lead}" in
		'#'* | '//'*) continue ;;
		esac
		printf '%s\t-\t%s\n' "${line}" "${lead}"
	done
}

# Run every rule over ROOT. Prints findings, one per line:
#   ID<TAB>KIND<TAB>FILE<TAB>LINE<TAB>SUMMARY<TAB>FIX<TAB>TEXT
# Options: --validate (only rules with MIG_VALIDATE != 0), --only IDS, --skip IDS
# (comma-separated).
mcp_migrate_detect() {
	local root="$1"
	shift
	local validate_only=0 only="" skip=""
	while [ $# -gt 0 ]; do
		case "$1" in
		--validate) validate_only=1 ;;
		--only)
			only="${2-}"
			shift
			;;
		--skip)
			skip="${2-}"
			shift
			;;
		esac
		shift
	done
	local rule
	mcp_migrate_rule_files | while IFS= read -r rule; do
		local id="${rule##*/}"
		id="${id%.sh}"
		if [ -n "${only}" ]; then
			case ",${only}," in *",${id},"*) ;; *) continue ;; esac
		fi
		case ",${skip}," in *",${id},"*) continue ;; esac
		(
			MIG_VALIDATE=1
			MIG_KIND=manual
			MIG_SCOPE=""
			MIG_SUMMARY=""
			MIG_FIX=""
			# shellcheck disable=SC1090
			. "${rule}" || exit 0
			[ "${validate_only}" -eq 1 ] && [ "${MIG_VALIDATE}" = "0" ] && exit 0
			declare -F mig_detect >/dev/null 2>&1 || exit 0
			local class rel
			# A file can belong to several classes; scan it once.
			for class in ${MIG_SCOPE}; do
				mcp_migrate_files "${class}" "${root}"
			done | LC_ALL=C sort -u | while IFS= read -r rel; do
				case "${rel}" in *$'\t'* | *$'\n'*) continue ;; esac
				local abs="${root}/${rel}"
				case "${rel}" in /*) abs="${rel}" ;; esac
				mig_detect "${abs}" | while IFS=$'\t' read -r line kind text; do
					[ -n "${line}" ] || continue
					case "${kind}" in '' | -) kind="${MIG_KIND}" ;; esac
					text="${text//$'\t'/ }"
					printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
						"${id}" "${kind}" "${rel}" "${line}" "${MIG_SUMMARY}" "${MIG_FIX}" "${text}"
				done
			done
		)
	done
}
