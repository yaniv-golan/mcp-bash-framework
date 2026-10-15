#!/usr/bin/env bash
query="$(printf '%s' "${MCP_COMPLETION_ARGS_JSON}" | jq -r '.query')"
# MCP_COMPLETION_ARGS_JSON in a comment is not a read
printf '["%s"]' "${query}"
