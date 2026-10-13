#!/usr/bin/env bash
out="$(mcp-bash run-tool hello --args '{}')"
printf '%s\n' "${out}" | jq -r 'select(.name == "hello") | .structuredContent'
printf '%s\n' "${out}" | jq -r '.content[0].text'
