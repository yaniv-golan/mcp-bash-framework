#!/usr/bin/env bash
set -o nounset -o errexit
mcp_elicit_confirm "A?"
x=1; mcp_elicit_confirm "B?"
case "$x" in 1) mcp_elicit_confirm "C?" ;; esac
( mcp_elicit_confirm "D?" )
mcp_elicit_confirm "E? (a;b)" \
	|| exit 0
set +e
mcp_elicit_confirm "F?"
set -e
mcp_elicit_confirm "G?"
x=1; if mcp_elicit_confirm "H?"; then :; fi
