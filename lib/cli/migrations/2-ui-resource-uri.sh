#!/usr/bin/env bash
# Migration rule; see lib/migrate_rules.sh for the contract.
# shellcheck disable=SC2034  # MIG_* are read by the engine that sources this file
MIG_ID=2-ui-resource-uri
MIG_API=2
MIG_REPLACEMENT=none
MIG_KIND=manual
MIG_SCOPE="project-sh"
MIG_SUMMARY="mcp_result_with_ui[_data] lose the unused resource_uri argument in 2.0 (and get a new name)"
MIG_FIX='keep as is for now; the 2.0 migration renames the helper'
mig_detect() { mig_grep_regex '(^|[^A-Za-z0-9_])mcp_result_with_ui(_data)?([^A-Za-z0-9_]|$)' "$1"; }
