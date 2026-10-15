#!/usr/bin/env bash
# Migration rule; see lib/migrate_rules.sh for the contract.
# shellcheck disable=SC2034  # MIG_* are read by the engine that sources this file
MIG_ID=2-elicit-bare
MIG_API=2
MIG_KIND=manual
MIG_SCOPE="project-sh"
MIG_SUMMARY='an mcp_elicit_* question helper exits 1 for any answer but yes in 2.0; called on its own under set -e, a "no" (or a client that cannot ask) ends the tool'
# shellcheck disable=SC2016  # The fix text shows literal shell code.
MIG_FIX='call it in an if (or before ||): "if mcp_elicit_confirm MESSAGE; then ...; else ...; fi"; the reason for a no is in $MCP_ELICIT_ACTION'
# A question helper run as a command of its own (at the start of a line,
# after ;, in a case arm or a subshell, after then/do/else/{) while errexit
# is on, with no || or && on that command. errexit is followed in file order:
# a -e shebang, set -e (in any option group, such as set -xe or set -e;),
# set -o errexit, and set +e / set +o errexit to turn it off. Lines ending in
# \ are joined first; quoted text never counts.
# shellcheck disable=SC2016  # An awk program.
mig_detect() {
	awk '
		BEGIN {
			h = "^(([A-Za-z_][A-Za-z0-9_]*=[^[:space:]]*|command)[[:space:]]+)*mcp_elicit_(string|confirm|choice|titled_choice|multi_choice|titled_multi_choice|url)([^A-Za-z0-9_]|$)"
		}
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
				if (c == "\047" || c == "\"") q = c
				out = out c
			}
			return out
		}
		function errexit(t,    n, w, i, on) {
			if (t !~ /^[[:space:]]*set[[:space:]]/) return
			n = split(t, w, /[[:space:];]+/)
			for (i = 1; i <= n; i++) {
				if (w[i] ~ /^-[A-Za-z]*e[A-Za-z]*$/) errexit_on = 1
				else if (w[i] ~ /^\+[A-Za-z]*e[A-Za-z]*$/) errexit_on = 0
				else if ((w[i] == "-o" || w[i] == "+o") && w[i + 1] == "errexit") { errexit_on = (w[i] == "-o"); i++ }
			}
		}
		{
			if (NR == 1 && $0 ~ /^#!.*[[:space:]]-[A-Za-z]*e/) errexit_on = 1
			if (logical == "") start = NR
			raw = raw (logical == "" ? "" : "\n") $0
			if ($0 ~ /\\$/) { logical = logical substr($0, 1, length($0) - 1) " "; next }
			logical = logical $0
			text = logical; first = raw; logical = ""; raw = ""
			sub(/\n.*/, "", first)
			trimmed = text
			sub(/^[[:space:]]+/, "", trimmed)
			if (trimmed == "" || substr(trimmed, 1, 1) == "#") next
			m = mask(text)
			sub(/[[:space:]]#.*$/, "", m)
			errexit(m)
			if (!errexit_on) next
			n = split(m, seg, /;/)
			for (i = 1; i <= n; i++) {
				s = seg[i]
				if (s ~ /\|\||&&/) continue
				sub(/^[[:space:]]+/, "", s)
				sub(/^case[[:space:]].*[[:space:]]in[[:space:]]+/, "", s)
				while (s ~ /^((then|do|else|[{(])[[:space:]]+|[(]|[^()[:space:]]*[)][[:space:]]+)/) {
					sub(/^((then|do|else|[{(])[[:space:]]+|[(]|[^()[:space:]]*[)][[:space:]]+)/, "", s)
					sub(/^[[:space:]]+/, "", s)
				}
				if (s ~ h) {
					sub(/^[[:space:]]+/, "", first)
					printf "%d\t-\t%s\n", start, first
					break
				}
			}
		}' "$1" 2>/dev/null
}
