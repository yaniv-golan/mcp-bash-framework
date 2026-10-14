#!/usr/bin/env bash
id="$(printf '%s' "${MCP_RESOURCE_TEMPLATE_VARS}" | jq -r .id)"
new="$(jq -r .id <"${MCP_RESOURCE_TEMPLATE_VARS_FILE}")"
printf '%s %s' "${id}" "${new}"
