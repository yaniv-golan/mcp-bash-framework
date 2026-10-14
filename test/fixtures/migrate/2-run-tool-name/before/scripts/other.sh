#!/usr/bin/env bash
# A tools/list item has a name; this is not a tool result.
jq -r '.result.tools[] | select(.name == "hello")' list.json
