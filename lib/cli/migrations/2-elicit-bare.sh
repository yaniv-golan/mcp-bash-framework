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
# A file that turns on errexit (set -e, set -euo ..., set -o errexit, or a
# -e shebang), and a line that starts with a question helper, not after
# if/elif/while/until/!, with no || or && on it. Comments and strings don't
# start a line with the helper's name, so they never count.
mig_detect() {
	awk '
		NR == 1 && /^#!.*[[:space:]]-[a-zA-Z]*e/ { errexit = 1 }
		/^[[:space:]]*set[[:space:]]+(-[a-zA-Z]*e[a-zA-Z]*|-o[[:space:]]+errexit)([[:space:]]|$)/ { errexit = 1 }
		{ lines[NR] = $0 }
		END {
			if (!errexit) exit
			for (i = 1; i <= NR; i++) {
				t = lines[i]
				if (t ~ /\|\||&&/) continue
				if (t ~ /^[[:space:]]*((then|do|else|[{])[[:space:]]+)?mcp_elicit_(string|confirm|choice|titled_choice|multi_choice|titled_multi_choice|url)([[:space:]]|$)/) {
					sub(/^[[:space:]]+/, "", t)
					printf "%d\t-\t%s\n", i, t
				}
			}
		}' "$1" 2>/dev/null
}
