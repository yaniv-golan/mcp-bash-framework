#!/usr/bin/env bash
name="$(jq -r .name <<<"${MCP_PROMPT_METADATA:-{}}")"
args="$(cat "${MCP_COMPLETION_ARGS_FILE}")"
printf '["%s"]' "${name}${args}"
