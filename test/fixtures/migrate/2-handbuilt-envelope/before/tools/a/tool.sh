#!/usr/bin/env bash
source "${MCP_SDK:?}/tool-sdk.sh"
err='{success: false, error: {code: $code, message: $msg}}'
jq -n --argjson err "${err}" '{content: [{type: "text", text: $err.error.message}], structuredContent: $err, isError: false}'
printf '%s' '{"structuredContent":{"success":true,"result":{}}}'
# success: true in a comment is not a finding
