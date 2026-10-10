#!/usr/bin/env bash
# Lint: keep the skill, scaffold and docs off APIs that change in the next
# major version, using the same rules as `mcp-bash validate` and
# `mcp-bash migrate` (lib/cli/migrations/).
#
# - Strict (fail): plugins/**/SKILL.md and scaffold/**. Agents and users copy
#   these, so they must teach only forms that survive the next major version.
# - Report only: docs/, examples/, README.md.in, llms*.txt. Pass --strict-all
#   to make these fail too.
# - SKILL.md: every ```bash block must parse, and every mcp_* name it mentions
#   must be a function in sdk/, lib/ or examples/ (or a documented hook).
#
# A line containing "lint-api-usage: allow" is skipped (e.g. prose that names
# an old API on purpose).
#
# Usage: test/lint-api-usage.sh [--root DIR] [--strict-all]

set -uo pipefail

MCPBASH_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export MCPBASH_HOME
ROOT="${MCPBASH_HOME}"
STRICT_ALL=0
while [ $# -gt 0 ]; do
	case "$1" in
	--root)
		ROOT="${2:?--root needs a directory}"
		shift
		;;
	--strict-all) STRICT_ALL=1 ;;
	*)
		printf 'usage: %s [--root DIR] [--strict-all]\n' "$0" >&2
		exit 2
		;;
	esac
	shift
done

# shellcheck source=../lib/migrate_rules.sh disable=SC1091
. "${MCPBASH_HOME}/lib/migrate_rules.sh"

# Rules that apply to prose and code samples. The others need project
# structure (tool.meta.json, policy.sh, server.meta.json).
TEXT_RULES_SKIP=",2-envelope-schema,2-marker,2-policy-replace,"
# Hooks a project defines; they are not framework functions.
HOOK_NAMES=" mcp_tools_policy_check mcp_tools_policy_project "

failures=0
reports=0

list_files() {
	local strictness="$1"
	(
		cd "${ROOT}" || exit 0
		if [ "${strictness}" = "strict" ]; then
			[ -d plugins ] && find plugins -type f -name 'SKILL.md'
			[ -d scaffold ] && find scaffold -type f \( -name '*.sh' -o -name '*.md' -o -name '*.json' -o -name '*.html' -o -name '*.txt' \)
		else
			[ -d docs ] && find docs -type f -name '*.md' -not -path 'docs/internal/*'
			[ -d examples ] && find examples -type f \( -name '*.sh' -o -name '*.md' -o -name '*.html' \)
			local f
			for f in README.md.in llms.txt llms-full.txt; do
				[ -f "${f}" ] && printf '%s\n' "${f}"
			done
		fi
	) 2>/dev/null | LC_ALL=C sort
}

# Print "REL:LINE RULE SUMMARY" for each finding in one file.
scan_file() {
	local rel="$1" rule
	mcp_migrate_rule_files | while IFS= read -r rule; do
		local id="${rule##*/}"
		id="${id%.sh}"
		case "${TEXT_RULES_SKIP}" in *",${id},"*) continue ;; esac
		(
			MIG_SUMMARY=""
			MIG_REPLACEMENT=frozen
			# shellcheck disable=SC1090
			. "${rule}" || exit 0
			mig_detect "${ROOT}/${rel}" | while IFS=$'\t' read -r line _kind text; do
				[ -n "${line}" ] || continue
				case "${text}" in *'lint-api-usage: allow'*) continue ;; esac
				printf '%s\t%s:%s %s %s\n' "${MIG_REPLACEMENT}" "${rel}" "${line}" "${id}" "${MIG_SUMMARY}"
			done
		)
	done
}

for strictness in strict report; do
	while IFS= read -r rel; do
		[ -n "${rel}" ] || continue
		out="$(scan_file "${rel}")"
		[ -n "${out}" ] || continue
		while IFS=$'\t' read -r replacement finding; do
			[ -n "${finding}" ] || continue
			# A rule whose replacement only arrives in the next major version
			# can't be acted on yet: report it, never fail on it.
			if { [ "${strictness}" = "strict" ] || [ "${STRICT_ALL}" -eq 1 ]; } && [ "${replacement}" != "none" ]; then
				printf '✗ %s\n' "${finding}"
				failures=$((failures + 1))
			else
				printf '⚠ %s\n' "${finding}"
				reports=$((reports + 1))
			fi
		done <<<"${out}"
	done < <(list_files "${strictness}")
done

# SKILL.md: bash blocks parse; mcp_* names exist.
function_exists() {
	local name="$1" pattern
	if [ "${name%_}" != "${name}" ]; then
		# A prefix such as mcp_elicit_ (written mcp_elicit_* in prose).
		pattern="^[[:space:]]*(function[[:space:]]+)?${name}[A-Za-z0-9_]*[[:space:]]*\\(\\)"
	else
		pattern="^[[:space:]]*(function[[:space:]]+)?${name}[[:space:]]*\\(\\)"
	fi
	# sdk/ and lib/ hold framework functions; examples/ holds documented
	# copy-paste recipes (e.g. mcp_detect_cli in examples/15-cli-wrapper).
	local d
	for d in sdk lib examples; do
		[ -d "${ROOT}/${d}" ] || continue
		find "${ROOT}/${d}" -type f -name '*.sh' -exec grep -lE "${pattern}" {} + 2>/dev/null | grep -q . && return 0
	done
	return 1
}

while IFS= read -r skill; do
	[ -n "${skill}" ] || continue
	# Each ```bash block must parse.
	block="" in_block=0 start=0 lineno=0
	while IFS= read -r l || [ -n "${l}" ]; do
		lineno=$((lineno + 1))
		if [ "${in_block}" -eq 0 ]; then
			case "${l}" in '```bash'*)
				in_block=1
				start="${lineno}"
				block=""
				;;
			esac
		else
			case "${l}" in
			'```'*)
				in_block=0
				if ! printf '%s\n' "${block}" | bash -n 2>/dev/null; then
					printf '✗ %s:%s bash block does not parse\n' "${skill}" "${start}"
					failures=$((failures + 1))
				fi
				;;
			*) block="${block}${l}"$'\n' ;;
			esac
		fi
	done <"${ROOT}/${skill}"
	# Every mcp_* name must exist (or be a documented hook).
	names="$(grep -v 'lint-api-usage: allow' "${ROOT}/${skill}" | grep -oE '(^|[^A-Za-z0-9_])mcp_[a-z0-9_]+' | sed -E 's/^[^m]//' | LC_ALL=C sort -u)"
	for name in ${names}; do
		case "${HOOK_NAMES}" in *" ${name} "*) continue ;; esac
		if ! function_exists "${name}"; then
			printf '✗ %s: %s is not a function in sdk/, lib/ or examples/\n' "${skill}" "${name}"
			failures=$((failures + 1))
		fi
	done
done < <(cd "${ROOT}" && [ -d plugins ] && find plugins -type f -name 'SKILL.md' | LC_ALL=C sort)

if [ "${failures}" -gt 0 ]; then
	printf '\nlint-api-usage: %d failure(s), %d report(s).\n' "${failures}" "${reports}"
	exit 1
fi
printf 'lint-api-usage: OK (%d report(s) in docs/examples).\n' "${reports}"
exit 0
