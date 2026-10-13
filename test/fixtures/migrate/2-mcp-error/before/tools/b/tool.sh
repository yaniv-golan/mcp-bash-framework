#!/usr/bin/env bash
source "${MCP_SDK:?}/tool-sdk.sh"
mcp_error a "conditional exit"
if [ "${strict}" = 1 ]; then exit 1; fi
do_more_work
mcp_error b "a string that says exit"
echo "we do not exit here"
mcp_error c "exit after &&"
[ -n "${x}" ] && exit 0
mcp_error d "same line"; exit 0
case "${mode}" in
x) mcp_error e "case arm"; exit 0 ;;
esac
mcp_error f "exit with a comment"
exit 1 # done
mcp_error g "exit or not"
exit 0 || true
mcp_error h "quoted; exit 0"
echo next
mcp_error i "cleanup between"; cleanup; exit 0
f() { mcp_error j "one-line function"; }
exit 0
mcp_error k "background" &
exit 0
mcp_error l "pipe" | tee x
exit 0
