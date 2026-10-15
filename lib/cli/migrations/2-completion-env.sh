#!/usr/bin/env bash
# Migration rule; see lib/migrate_rules.sh for the contract.
# shellcheck disable=SC2034  # MIG_* are read by the engine that sources this file
MIG_ID=2-completion-env
MIG_API=2
MIG_KIND=manual
MIG_SILENT=1
MIG_SCOPE="project-sh completion"
MIG_SUMMARY="completion scripts and providers get user-sized values in files in 2.0: MCP_COMPLETION_ARGS_JSON, MCP_PROMPT_METADATA, MCP_RESOURCE_METADATA and MCP_RESOURCE_TEMPLATE_VARS are no longer set"
# shellcheck disable=SC2016  # The fix text shows literal shell code.
MIG_FIX='read the JSON from the matching *_FILE variable, on stdin: jq -r .query <"$MCP_COMPLETION_ARGS_FILE" (likewise MCP_PROMPT_METADATA_FILE, MCP_RESOURCE_METADATA_FILE, MCP_RESOURCE_TEMPLATE_VARS_FILE)'
mig_detect() { mig_grep_regex '(^|[^A-Za-z0-9_])MCP_(COMPLETION_ARGS_JSON|PROMPT_METADATA|RESOURCE_METADATA|RESOURCE_TEMPLATE_VARS)([^A-Za-z0-9_]|$)' "$1"; }
