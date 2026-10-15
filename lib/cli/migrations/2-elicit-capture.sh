#!/usr/bin/env bash
# Migration rule; see lib/migrate_rules.sh for the contract.
# shellcheck disable=SC2034  # MIG_* are read by the engine that sources this file
MIG_ID=2-elicit-capture
MIG_API=2
MIG_KIND=manual
MIG_SILENT=1
MIG_SCOPE="project-sh"
MIG_SUMMARY='the mcp_elicit_* question helpers print nothing in 2.0: capturing them with $(...) and parsing .action no longer works'
# shellcheck disable=SC2016  # The fix text shows literal shell code.
MIG_FIX='call them directly: "if mcp_elicit_confirm MESSAGE; then" (or "mcp_elicit_string -v VAR MESSAGE"); the reason for a no is in $MCP_ELICIT_ACTION (decline, cancel, unavailable). For the raw JSON, use mcp_elicit'
# Every way 1.x code read what the question helpers printed: $(...), <(...)
# and backticks (also with a $( on the line before, or a VAR=... or command
# prefix), a pipe into another command, and stdout redirected to a file.
# A pipe or redirect counts only outside quoted strings, so a "|" in the
# question text doesn't. In Markdown, inline code (`...`) is text, not a
# command substitution (also in .txt files such as llms.txt). The raw mcp_elicit and mcp_elicit_url_raw still
# print JSON and are never reported.
# shellcheck disable=SC2016  # An awk program.
mig_detect() {
	local md=0
	case "$1" in *.md | *.markdown | *.txt) md=1 ;; esac
	awk -v md="${md}" '
		BEGIN {
			h = "mcp_elicit_(string|confirm|choice|titled_choice|multi_choice|titled_multi_choice|url)"
			pre = "(([A-Za-z_][A-Za-z0-9_]*=[^[:space:]]*|command)[[:space:]]+)*"
			subst = md ? "[$<][(]" : "([$<][(]|`)"
			capture = subst "[[:space:]]*" pre h "([^A-Za-z0-9_]|$)"
			linestart = "^[[:space:]]*" pre h "([^A-Za-z0-9_]|$)"
			opened = "[$<][(][[:space:]]*\\\\?[[:space:]]*$"
		}
		# Quoted text blanked (the quotes kept), so a | or > in it never counts.
		function mask(t,    out, i, c, q) {
			out = ""; q = ""
			for (i = 1; i <= length(t); i++) {
				c = substr(t, i, 1)
				if (q != "") {
					if (c == q) { q = ""; out = out c }
					else if (c == "\\" && q == "\"") { i++; out = out "  " }
					else out = out " "
					continue
				}
				if (c == "\047" || c == "\"" || (md && c == "`")) q = c
				out = out c
			}
			return out
		}
		function report(n, t) { sub(/^[[:space:]]+/, "", t); printf "%d\t-\t%s\n", n, t }
		{
			line = $0
			trimmed = line
			sub(/^[[:space:]]+/, "", trimmed)
			if (trimmed == "" || substr(trimmed, 1, 1) == "#") { prev = line; next }
			# Only a line with a call can be reported; mask() is slow on a long line.
			if (!index(line, "mcp_elicit_")) { prev = line; next }
			if (line ~ capture || (prev ~ opened && line ~ linestart)) { report(NR, line); prev = line; next }
			m = mask(line)
			if (match(m, "(^|[^A-Za-z0-9_])" h "([^A-Za-z0-9_]|$)")) {
				rest = substr(m, RSTART + RLENGTH)
				if (match(rest, /;|&&|\|\|/)) rest = substr(rest, 1, RSTART - 1)
				if (rest ~ /\|/) { report(NR, line); prev = line; next }
				if (match(rest, /(^|[[:space:]])1?>>?[[:space:]]*[^&[:space:]][^[:space:]]*/)) {
					target = substr(rest, RSTART, RLENGTH)
					sub(/^[[:space:]]*1?>>?[[:space:]]*/, "", target)
					if (target != "/dev/null") { report(NR, line); prev = line; next }
				}
			}
			prev = line
		}' "$1" 2>/dev/null
}
