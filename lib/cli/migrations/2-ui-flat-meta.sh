#!/usr/bin/env bash
# Migration rule; see lib/migrate_rules.sh for the contract.
# shellcheck disable=SC2034  # MIG_* are read by the engine that sources this file
MIG_ID=2-ui-flat-meta
MIG_API=2
MIG_KIND=manual
MIG_SCOPE="project-sh"
MIG_SUMMARY="a result's flat _meta[\"ui/resourceUri\"] is no longer rewritten to _meta.ui.resourceUri in 2.0"
MIG_FIX='put the URI in _meta.ui.resourceUri (or use mcp_result_ui)'
mig_detect() { mig_grep_regex 'ui/resourceUri' "$1"; }
