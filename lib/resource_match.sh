#!/usr/bin/env bash
# Match a client-supplied URI against the resource templates registry.
#
# Supported RFC 6570 subset (any other template is skipped for matching only):
#   {v}   one or more codepoints, never "/", "?" or "#"
#   {+v}  one or more codepoints, may contain "/"
#   {#v}  a literal "#", then as {+v}
# Variable names match [A-Za-z0-9_]+ and may not repeat within a template.
# Other operators, comma lists, modifiers and adjacent expressions ({a}{b})
# make a template unsupported.
#
# The matcher is complete (no false negatives) and deterministic: backward
# reachability, then a leftmost-shortest forward walk. It works on exploded
# codepoints only (no regex, no string index: jq 1.6 index returns byte
# offsets on non-ASCII input), so jq, jq 1.6 and gojq agree. Cost is
# O(parts * length) per template.
#
# Matches are ranked by most literal codepoints (an inserted "#" counts), then
# fewest expressions, then template name ascending. Values are returned raw:
# percent-encoding is not decoded.

set -euo pipefail

MCP_RESOURCE_MATCH_MAX_URI=2048

# shellcheck disable=SC2016  # jq program, not shell expansions.
MCP_RESOURCE_MATCH_JQ='
def _is_name_cp: (. >= 48 and . <= 57) or (. >= 65 and . <= 90) or (. >= 97 and . <= 122) or . == 95;

# C0/C1 controls, DEL and Unicode whitespace.
def _is_space_or_control:
  . <= 32 or (. >= 127 and . <= 160) or . == 5760 or (. >= 8192 and . <= 8202)
  or . == 8232 or . == 8233 or . == 8239 or . == 8287 or . == 12288 or . == 65279;

# template string -> [ {lit:[cp]} | {op:"" | "+", name:string} ], or null when unsupported
def _tparse:
  reduce (explode[]) as $ch ({parts: [], lit: [], expr: null, bad: false};
    if .bad then .
    elif .expr != null then
      if $ch == 125 then .parts += [{expr: .expr}] | .expr = null
      elif $ch == 123 then .bad = true
      else .expr += [$ch] end
    elif $ch == 123 then
      (if (.lit | length) > 0 then .parts += [{lit: .lit}] else . end) | .lit = [] | .expr = []
    elif $ch == 125 then .bad = true
    else .lit += [$ch] end)
  | if .bad or .expr != null then null
    else (if (.lit | length) > 0 then .parts += [{lit: .lit}] else . end) | .parts end
  | if . == null then null else
      [ .[] | if has("lit") then . else
          .expr as $e
          | (if ($e | length) > 0 and ($e[0] == 43 or $e[0] == 35) then $e[0] else null end) as $op
          | (if $op == null then $e else $e[1:] end) as $nm
          | if ($nm | length) == 0 or (all($nm[]; _is_name_cp) | not) then {bad: true}
            elif $op == 35 then {lit: [35]}, {op: "+", name: ($nm | implode)}
            elif $op == 43 then {op: "+", name: ($nm | implode)}
            else {op: "", name: ($nm | implode)} end
        end ]
      # Merge adjacent literals (from {#v}); reject bad expressions, adjacent
      # expressions and repeated names.
      | reduce .[] as $p ([];
          if (length > 0) and (.[-1] | has("lit")) and ($p | has("lit")) then .[-1].lit += $p.lit
          else . + [$p] end)
      | if any(.[]; has("bad")) then null
        elif any(range(1; length) as $i | [.[$i - 1], .[$i]]; (.[0] | has("op")) and (.[1] | has("op"))) then null
        elif ([.[] | select(has("op")) | .name] | length) != ([.[] | select(has("op")) | .name] | unique | length) then null
        else . end
    end;

# A simple {v} stops at "/", "?" and "#" (simple expansion percent-encodes them).
def _stop: . == 47 or . == 63 or . == 35;

# u: [cp], parts -> {vars} or null
def _tmatch($u; $parts):
  ($u | length) as $n
  | ($parts | length) as $k
  # nextstop[p] = smallest index >= p holding a stop codepoint, else n
  | (reduce range($n - 1; -1; -1) as $p ([range(0; $n + 1) | $n];
       if ($u[$p] | _stop) then .[$p] = $p else .[$p] = .[$p + 1] end)) as $nextstop
  # B[i][p] is true when parts[i:] can match u[p:] exactly
  | (reduce range($k - 1; -1; -1) as $i ({($k | tostring): [range(0; $n + 1) | (. == $n)]};
      .[($i + 1) | tostring] as $next
      | $parts[$i] as $pt
      | .[$i | tostring] =
          (if $pt | has("lit") then
             ($pt.lit | length) as $m
             | [range(0; $n + 1) as $p | ($p + $m <= $n) and $next[$p + $m] and ($u[$p:$p + $m] == $pt.lit)]
           else
             # nq[p] = smallest q > p with next[q], or n+1
             (reduce range($n; -1; -1) as $q ({nq: [range(0; $n + 2) | $n + 1], best: ($n + 1)};
                .nq[$q] = .best | if $next[$q] then .best = $q else . end) | .nq) as $nq
             | if $pt.op == "+" then [range(0; $n + 1) as $p | $nq[$p] <= $n]
               else [range(0; $n + 1) as $p | $nq[$p] <= $nextstop[$p]] end
           end))) as $B
  | if ($B["0"][0] | not) then null else
      reduce range(0; $k) as $i ({p: 0, vars: {}};
        $parts[$i] as $pt
        | if $pt | has("lit") then .p += ($pt.lit | length)
          else .p as $p
            | $B[($i + 1) | tostring] as $next
            | first(range($p + 1; $n + 1) | select($next[.])
                    | select($pt.op == "+" or . <= $nextstop[$p])) as $q
            | .vars[$pt.name] = ($u[$p:$q] | implode) | .p = $q
          end)
      | .vars
    end;

($uri | explode) as $u
| if ($u | length) > ($max | tonumber) or any($u[]; _is_space_or_control) then empty else
    [ (.items // [])[]?
      | select(type == "object" and (.name | type) == "string" and (.uriTemplate | type) == "string")
      | . as $t
      | (try (.uriTemplate | _tparse) catch null) as $parts
      | select($parts != null)
      | (try _tmatch($u; $parts) catch null) as $vars
      | select($vars != null)
      # Sorted keys, so jq and gojq print VARS identically.
      | {name: $t.name, vars: ($vars | to_entries | sort_by(.key) | from_entries),
         literalCount: ([$parts[] | select(has("lit")) | .lit | length] | add // 0),
         exprCount: ([$parts[] | select(has("op"))] | length)}
      + (if ($t.mimeType | type) == "string" and $t.mimeType != "" then {mimeType: $t.mimeType} else {} end) ]
    | sort_by(-.literalCount, .exprCount, .name)
    | if length > 0 then .[0] else empty end
  end
'

# mcp_resource_template_match URI
# Reads a templates registry ({items: [...]}) on stdin. Prints the best match
# as compact JSON {name, vars, literalCount, exprCount[, mimeType]}, or nothing
# when no supported template matches. Never fails the caller: a matcher error
# counts as no match.
mcp_resource_template_match() {
	local uri="$1"
	local tool="${MCPBASH_JSON_TOOL_BIN:-jq}"
	"${tool}" -c --arg uri "${uri}" --arg max "${MCP_RESOURCE_MATCH_MAX_URI}" \
		"${MCP_RESOURCE_MATCH_JQ}" 2>/dev/null || true
}
