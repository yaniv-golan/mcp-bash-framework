#!/usr/bin/env bash
# Migration rules engine: finds uses of APIs that change in a later major
# version, for `mcp-bash validate` (warnings) and `mcp-bash migrate`.
#
# Rules live in lib/cli/migrations/<apiVersion>-<id>.sh. Each rule is sourced
# in its own subshell and defines:
#   MIG_ID       stable id (equals the file name without .sh)
#   MIG_API      integer API version the rule moves to
#   MIG_KIND     default kind of its findings: auto | manual | advisory (listed,
#                but neither pending nor blocking the apiVersion marker)
#   MIG_SUMMARY  one line, shown with each finding
#   MIG_FIX      short replacement hint
#   MIG_SCOPE    file classes to scan (see mcp_migrate_files)
#   MIG_VALIDATE 0 to keep the rule out of `validate` (default 1)
#   MIG_SILENT   1 when the old code keeps running in the next major version
#                but does the wrong thing with no error: validate marks
#                its findings and sums them up (mcp_migrate_silent_rules)
#   MIG_REPLACEMENT  frozen (default): the replacement already exists and is
#                frozen; none: it only arrives with the next major version, so
#                there is nothing to change yet (lints report, never fail)
#   MIG_SET      optional set name: findings of one set must be rewritten together
#                (see mcp_migrate_detect_resolved)
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

# The ids of the rules marked MIG_SILENT=1, one per line.
mcp_migrate_silent_rules() {
	local dir
	dir="$(mcp_migrate_rules_dir)"
	[ -d "${dir}" ] || return 0
	grep -l '^MIG_SILENT=1$' "${dir}"/*.sh 2>/dev/null | sed 's#.*/##; s#[.]sh$##'
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
# tool-meta config completion (completion scripts that may not end in .sh:
# *.completion next to prompts and resources, and the paths register.json
# lists under "completions")
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
		completion)
			local sub
			for sub in prompts resources; do
				[ -d "${root}/${sub}" ] && find "${root}/${sub}" "${prune[@]}" -type f -name '*.completion' -print
			done
			# Registered scripts run whatever their name (no extension, .bash,
			# .py). Without a JSON tool (or if it fails), every "path" in the
			# file: a prompt template among them only costs a scan.
			if [ -f "${server}/register.json" ]; then
				local json_bin="${MCPBASH_JSON_TOOL_BIN:-}" rel root_phys cand dir
				root_phys="$(cd "${root}" && pwd -P)" || root_phys="${root}"
				[ -n "${json_bin}" ] || json_bin="$(command -v jq || command -v gojq || printf false)"
				{
					"${json_bin}" -r '.completions[]?.path? // empty | strings' <"${server}/register.json" \
						|| grep -o '"path"[[:space:]]*:[[:space:]]*"[^"]*"' "${server}/register.json" | sed 's/.*"\([^"]*\)"$/\1/'
				} | while IFS= read -r rel; do
					# Resolved as the server does (mcp_completion_resolve_script_path):
					# relative to the project root, or absolute; the directory with
					# pwd -P; kept only inside the project. Printed under ROOT, so
					# two spellings of one file are one finding.
					case "${rel}" in
					'') continue ;;
					/*) cand="${rel}" ;;
					*) cand="${root_phys}/${rel}" ;;
					esac
					dir="$(cd "$(dirname -- "${cand}")" 2>/dev/null && pwd -P)" || continue
					cand="${dir}/$(basename -- "${cand}")"
					case "${cand}" in "${root_phys}/"*) ;; *) continue ;; esac
					[ -f "${cand}" ] && printf '%s\n' "${root}/${cand#"${root_phys}/"}"
				done
			fi
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

# Helper for rules: count the shell words passed to the first call of NAME on
# a line of TEXT (up to the end of that simple command). Handles quotes and
# nested $(...). Prints the count; prints nothing if NAME isn't called.
mig_call_argc() {
	local name="$1" text="$2"
	local rest="" pre="${text%%"${name}"*}"
	[ "${pre}" != "${text}" ] || return 0
	rest="${text#*"${name}"}"
	case "${rest}" in
	'' | [[:space:]]* | ';'* | ')'*) ;;
	*) return 0 ;; # NAME was a prefix of a longer word
	esac
	local i=0 n=${#rest} c count=0 in_word=0 sq=0 dq=0 depth=0 starts=0
	while [ "${i}" -lt "${n}" ]; do
		c="${rest:${i}:1}"
		starts=0
		if [ "${sq}" -eq 1 ]; then
			[ "${c}" = "'" ] && sq=0
		elif [ "${c}" = "\\" ]; then
			i=$((i + 1))
			starts=1
		elif [ "${c}" = '"' ]; then
			starts=1
			if [ "${depth}" -eq 0 ]; then
				dq=$((1 - dq))
			fi
		elif [ "${dq}" -eq 0 ] && [ "${depth}" -eq 0 ] && [ "${c}" = "'" ]; then
			starts=1
			sq=1
		elif [ "${c}" = '$' ] && [ "${rest:$((i + 1)):1}" = '(' ]; then
			starts=1
			depth=$((depth + 1))
			i=$((i + 1))
		elif [ "${depth}" -gt 0 ]; then
			case "${c}" in
			'(') depth=$((depth + 1)) ;;
			')') depth=$((depth - 1)) ;;
			esac
		elif [ "${dq}" -eq 1 ]; then
			:
		else
			case "${c}" in
			' ' | '	') in_word=0 ;;
			';' | '&' | '|' | ')' | '#' | '}') break ;;
			*) starts=1 ;;
			esac
		fi
		if [ "${starts}" -eq 1 ] && [ "${in_word}" -eq 0 ]; then
			in_word=1
			count=$((count + 1))
		fi
		i=$((i + 1))
	done
	printf '%s\n' "${count}"
}

# Helper for rules: true when the call to NAME on this line can't be rewritten
# blindly: its output is captured with $(...) (the caller post-processes the
# result's shape) or it forwards "$@"/$* (unknown arguments).
mig_call_is_opaque() {
	local name="$1" text="$2"
	# Captured only when "$(" or a backtick directly wraps the call (other
	# substitutions earlier on the line, e.g. X=$(a) || NAME, don't count).
	local pre="${text%%"${name}"*}"
	pre="${pre%"${pre##*[![:space:]]}"}"
	case "${pre}" in
	*'$(' | *'`') return 0 ;;
	esac
	local rest="${text#*"${name}"}"
	case "${rest}" in
	*'"$@"'* | *'$@'* | *'"$*"'* | *'$*'* | *'${@}'*) return 0 ;;
	esac
	return 1
}

# Helper for rules: replace line N of FILE with TEXT (in place).
mig_replace_line() {
	local file="$1" n="$2" text="$3" tmp
	tmp="$(mktemp "${file}.mig.XXXXXX")" || return 1
	MIG_NEW_LINE="${text}" awk -v n="${n}" 'NR == n { print ENVIRON["MIG_NEW_LINE"]; next } { print }' "${file}" >"${tmp}" \
		&& cat "${tmp}" >"${file}"
	rm -f "${tmp}"
}

# Helper for rules: print the first non-blank, non-comment line after the
# command that starts on line N of FILE (skipping its "\" continuation lines).
mig_next_statement() {
	awk -v n="$2" '
		NR < n { next }
		NR == n { cont = ($0 ~ /\\[[:space:]]*$/); next }
		cont { cont = ($0 ~ /\\[[:space:]]*$/); next }
		$0 ~ /^[[:space:]]*(#.*)?$/ { next }
		{ print; exit }' "$1"
}

# Helper for rules: print line N of FILE.
mig_line() {
	awk -v n="$2" 'NR == n { print; exit }' "$1"
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

# Ids of the rules in set NAME, comma-separated with leading/trailing commas.
mcp_migrate_set_ids() {
	local name="$1" rule ids=","
	while IFS= read -r rule; do
		local set_name
		set_name="$(
			MIG_SET=""
			# shellcheck disable=SC1090
			. "${rule}" >/dev/null 2>&1
			printf '%s' "${MIG_SET}"
		)"
		if [ "${set_name}" = "${name}" ]; then
			local id="${rule##*/}"
			ids="${ids}${id%.sh},"
		fi
	done < <(mcp_migrate_rule_files)
	printf '%s\n' "${ids}"
}

# Like mcp_migrate_detect, but findings of the "envelope" set (result calls,
# outputSchema, UI reads of .result) are auto only when they can all be
# rewritten together:
# - per tool (tools/<name>/): if any of the tool's envelope findings is
#   manual, all of them are;
# - envelope findings in shared scripts outside tools/<name>/ change every
#   tool that uses them, so if there are any, all envelope findings are auto
#   only when every one of them is auto and no outputSchema or UI read needs
#   changing anywhere; otherwise all are manual.
mcp_migrate_detect_resolved() {
	local sets
	sets="$(mcp_migrate_set_ids envelope)"
	mcp_migrate_detect "$@" | awk -F'\t' -v OFS='\t' -v sets="${sets}" '
		function key(file,   m) {
			if (match(file, /^tools\/[^\/]+\//)) return substr(file, 1, RLENGTH)
			return "shared"
		}
		{ line[NR] = $0; id[NR] = $1; kind[NR] = $2; file[NR] = $3 }
		index(sets, "," $1 ",") > 0 {
			inset[NR] = 1
			k = key($3)
			if ($2 == "manual") bad[k] = 1
			if (k == "shared") shared = 1
			else if ($1 != "2-result-success") structural = 1
			if ($2 == "manual") anybad = 1
		}
		END {
			for (i = 1; i <= NR; i++) {
				if (inset[i]) {
					k = key(file[i])
					demote = 0
					if (shared && (anybad || structural)) demote = 1
					else if (!shared && bad[k]) demote = 1
					if (demote && kind[i] == "auto") {
						n = split(line[i], f, "\t")
						f[2] = "manual"
						f[7] = f[7] " (moves together with this tool'"'"'s other envelope changes)"
						out = f[1]
						for (j = 2; j <= n; j++) out = out OFS f[j]
						print out
						continue
					}
				}
				print line[i]
			}
		}'
}
