#!/usr/bin/env bats
# Unit layer: resources/read template matcher (lib/resource_match.sh).
#
# Every case runs under each JSON engine found: jq and gojq on PATH, plus any
# extra binaries listed in MCPBASH_TEST_MATCH_ENGINES (space-separated paths,
# e.g. a jq 1.6 build).

load '../../node_modules/bats-support/load'
load '../../node_modules/bats-assert/load'
load '../common/fixtures'

setup() {
	# shellcheck source=lib/resource_match.sh
	# shellcheck disable=SC1091
	. "${MCPBASH_HOME}/lib/resource_match.sh"
	ENGINES=()
	local candidate path
	for candidate in jq gojq; do
		if path="$(command -v "${candidate}" 2>/dev/null)" && [ -n "${path}" ]; then
			ENGINES+=("${path}")
		fi
	done
	for candidate in ${MCPBASH_TEST_MATCH_ENGINES:-}; do
		if [ -x "${candidate}" ]; then
			ENGINES+=("${candidate}")
		fi
	done
	[ "${#ENGINES[@]}" -gt 0 ] || skip "no jq or gojq available"
}

# registry <name> <uriTemplate> [<name> <uriTemplate> ...] -> {items:[...]}
registry() {
	local items="[]"
	while [ "$#" -ge 2 ]; do
		items="$(jq -cn --argjson items "${items}" --arg n "$1" --arg t "$2" '$items + [{name: $n, uriTemplate: $t}]')"
		shift 2
	done
	jq -cn --argjson items "${items}" '{items: $items}'
}

# match_with <engine> <registry-json> <uri> -> "name vars" or ""
match_with() {
	local engine="$1" reg="$2" uri="$3"
	printf '%s' "${reg}" | MCPBASH_JSON_TOOL_BIN="${engine}" mcp_resource_template_match "${uri}" \
		| jq -r 'select(. != null) | "\(.name) \(.vars | tojson)"'
}

# expect <registry-json> <uri> <expected "name vars" or "">
expect() {
	local reg="$1" uri="$2" want="$3" engine got
	for engine in "${ENGINES[@]}"; do
		got="$(match_with "${engine}" "${reg}" "${uri}")"
		if [ "${got}" != "${want}" ]; then
			fail "engine ${engine}: uri '${uri}' gave '${got}', want '${want}'"
		fi
	done
}

@test "resource_match: simple {v} matches one segment" {
	expect "$(registry user 'x://u/{id}')" 'x://u/42' 'user {"id":"42"}'
}

@test "resource_match: {v} does not cross '/', {+v} does" {
	expect "$(registry seg 'x://f/{p}')" 'x://f/a/b' ''
	expect "$(registry seg 'x://f/{p}')" 'x://u/42/' ''
	expect "$(registry path 'x://f/{+p}')" 'x://f/a/b' 'path {"p":"a/b"}'
}

@test "resource_match: {v} stops at '?' and '#'" {
	expect "$(registry user 'x://u/{id}')" 'x://u/42?fields=a' ''
	expect "$(registry user 'x://u/{id}')" 'x://u/42#top' ''
	expect "$(registry user 'x://u/{id}?q={q}')" 'x://u/42?q=1' 'user {"id":"42","q":"1"}'
	expect "$(registry user 'x://u/{id}#top')" 'x://u/42#top' 'user {"id":"42"}'
}

@test "resource_match: {#v} consumes the '#' then behaves like {+v}" {
	expect "$(registry doc 'x://doc{#sec}')" 'x://doc#intro' 'doc {"sec":"intro"}'
	expect "$(registry doc 'x://doc{#sec}')" 'x://doc#a/b' 'doc {"sec":"a/b"}'
	expect "$(registry doc 'x://doc{#sec}')" 'x://docintro' ''
}

@test "resource_match: empty values never match" {
	expect "$(registry user 'x://u/{id}')" 'x://u/' ''
	expect "$(registry path 'x://f/{+p}')" 'x://f/' ''
}

@test "resource_match: matching is case-sensitive" {
	expect "$(registry user 'X://u/{id}')" 'x://u/42' ''
}

@test "resource_match: adjacent expressions make a template unsupported" {
	expect "$(registry adj 'x://{a}{b}')" 'x://ab' ''
	expect "$(registry adj 'x://{a}{+b}')" 'x://ab' ''
}

@test "resource_match: unsupported operators, lists and modifiers are skipped" {
	local tpl
	for tpl in 'x://u/{id,x}' 'x://u/{id*}' 'x://u/{id:3}' 'x://u/{.ext}' 'x://u{/p}' \
		'x://u{?q}' 'x://u{&q}' 'x://u{;p}' 'x://u/{=v}' 'x://u/{}' 'x://u/{a.b}' \
		'x://u/{a-b}' 'x://u/{id' 'x://u/id}' 'x://u/{a{b}}' 'x://{a}/{a}'; do
		expect "$(registry bad "${tpl}")" 'x://u/1,2' ''
		expect "$(registry bad "${tpl}")" 'x://u/1' ''
		expect "$(registry bad "${tpl}")" 'x://u/.md' ''
	done
}

@test "resource_match: an unsupported template does not hide a supported one" {
	expect "$(registry aaa 'x://u/{id*}' zzz 'x://u/{id}')" 'x://u/7' 'zzz {"id":"7"}'
}

@test "resource_match: no false negatives where a greedy walk fails" {
	expect "$(registry t 'x://{+a}/end')" 'x://p/end/q/end' 't {"a":"p/end/q"}'
	expect "$(registry t 'x://{+a}/mid/{b}')" 'x://p/mid/q/mid/r' 't {"a":"p/mid/q","b":"r"}'
	expect "$(registry t 'x://f/{a}.txt')" 'x://f/x.txt.txt' 't {"a":"x.txt"}'
}

@test "resource_match: leftmost-shortest when several splits fit" {
	expect "$(registry t 'x://{+a}/{+b}')" 'x://p/q/r' 't {"a":"p","b":"q/r"}'
	expect "$(registry t 'x://{a}-{b}')" 'x://p-q-r' 't {"a":"p","b":"q-r"}'
}

@test "resource_match: tie-break by most literal codepoints" {
	expect "$(registry short 'x://u/{id}' long 'x://u/{id}.json')" 'x://u/a.json' 'long {"id":"a"}'
}

@test "resource_match: an inserted '#' counts as a literal" {
	expect "$(registry plus 'x://doc{+rest}' frag 'x://doc{#sec}')" 'x://doc#intro' 'frag {"sec":"intro"}'
}

@test "resource_match: tie-break by fewest expressions" {
	expect "$(registry two '{s}://{+rest}' one 'x:/{+r}')" 'x://abc' 'one {"r":"/abc"}'
}

@test "resource_match: tie-break by template name ascending" {
	expect "$(registry zeta 'x://{a}' alpha 'x://{b}')" 'x://v' 'alpha {"b":"v"}'
}

@test "resource_match: non-ASCII URIs match by codepoint" {
	expect "$(registry user 'x://u/{id}')" 'x://u/café' 'user {"id":"café"}'
	expect "$(registry t 'x://{a}é/{b}')" 'x://zzé/q' 't {"a":"zz","b":"q"}'
	expect "$(registry t 'x://日/{a}')" 'x://日/本' 't {"a":"本"}'
}

@test "resource_match: percent-encoding stays raw" {
	expect "$(registry user 'x://u/{id}')" 'x://u/a%2Fb' 'user {"id":"a%2Fb"}'
	expect "$(registry user 'x://u/{id}')" 'x://u/%2E%2E' 'user {"id":"%2E%2E"}'
}

@test "resource_match: URIs longer than 2048 codepoints are skipped" {
	local body uri
	body="$(printf '%*s' 2044 '' | tr ' ' 'a')"
	uri="x://${body}"
	expect "$(registry all 'x://{+a}')" "${uri}" "all {\"a\":\"${body}\"}"
	expect "$(registry all 'x://{+a}')" "${uri}b" ''
	# The cap counts codepoints, not bytes.
	body="$(printf '%*s' 2044 '' | sed 's/ /é/g')"
	expect "$(registry all 'x://{+a}')" "x://${body}" "all {\"a\":\"${body}\"}"
}

@test "resource_match: URIs with control characters or whitespace are skipped" {
	expect "$(registry all 'x://{+a}')" 'x://a b' ''
	expect "$(registry all 'x://{+a}')" "x://a$(printf '\t')b" ''
	expect "$(registry all 'x://{+a}')" "x://a$(printf '\001')b" ''
	expect "$(registry all 'x://{+a}')" "x://a$(printf '\302\240')b" ''
	expect "$(registry all 'x://{+a}')" "x://a$(printf '\177')b" ''
}

@test "resource_match: invalid registry entries are skipped" {
	local reg='{"items":[{"name":"n1","uriTemplate":7},{"uriTemplate":"x://{a}"},"str",{"name":"ok","uriTemplate":"x://{a}"}]}'
	expect "${reg}" 'x://v' 'ok {"a":"v"}'
	expect '{}' 'x://v' ''
	expect '{"items":null}' 'x://v' ''
}

@test "resource_match: the template mimeType is returned when set" {
	local reg='{"items":[{"name":"md","uriTemplate":"x://d/{a}","mimeType":"text/markdown"},{"name":"plain","uriTemplate":"x://p/{a}"}]}'
	local engine got
	for engine in "${ENGINES[@]}"; do
		got="$(printf '%s' "${reg}" | MCPBASH_JSON_TOOL_BIN="${engine}" mcp_resource_template_match x://d/1 | jq -r .mimeType)"
		[ "${got}" = "text/markdown" ] || fail "engine ${engine}: mimeType '${got}'"
		got="$(printf '%s' "${reg}" | MCPBASH_JSON_TOOL_BIN="${engine}" mcp_resource_template_match x://p/1 | jq -r 'has("mimeType")')"
		[ "${got}" = "false" ] || fail "engine ${engine}: unexpected mimeType"
	done
}

@test "resource_match: a pathological URI returns quickly with no match" {
	local uri reg engine start elapsed
	uri="x://$(printf 's/%.0s' $(seq 1 100))tail"
	reg="$(registry p 'x://{+a}/{b}/{+c}/{d}/{+e}/end' q 'x://{a}/{+b}/{c}/{+d}/{e}/end')"
	for engine in "${ENGINES[@]}"; do
		start="$(date +%s)"
		[ -z "$(match_with "${engine}" "${reg}" "${uri}")" ] || fail "engine ${engine}: unexpected match"
		elapsed=$(($(date +%s) - start))
		[ "${elapsed}" -le 5 ] || fail "engine ${engine}: took ${elapsed}s"
	done
	# The same templates still match when the tail fits: leftmost-shortest
	# gives a..d one segment each and e the remaining 96.
	local rest
	rest="$(printf 's/%.0s' $(seq 1 95))s"
	expect "${reg}" "x://$(printf 's/%.0s' $(seq 1 100))end" "p {\"a\":\"s\",\"b\":\"s\",\"c\":\"s\",\"d\":\"s\",\"e\":\"${rest}\"}"
}

@test "resource_match: works under /bin/bash (3.2 on macOS)" {
	[ -x /bin/bash ] || skip "/bin/bash not available"
	run /bin/bash -c '. "$1/lib/resource_match.sh"; printf "%s" "$2" | mcp_resource_template_match x://u/42' _ \
		"${MCPBASH_HOME}" "$(registry user 'x://u/{id}')"
	assert_success
	assert_output --partial '"vars":{"id":"42"}'
}
