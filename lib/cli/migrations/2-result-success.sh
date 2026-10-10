#!/usr/bin/env bash
# Migration rule; see lib/migrate_rules.sh for the contract.
# shellcheck disable=SC2034  # MIG_* are read by the engine that sources this file
MIG_ID=2-result-success
MIG_API=2
MIG_KIND=auto
MIG_SCOPE="project-sh"
MIG_SUMMARY="mcp_result_success (wraps results in {success, result}) is removed in 2.0"
MIG_FIX='mcp_result_json JSON (no envelope; update outputSchema and UI reads of .result with it)'
mig_detect() { mig_grep_word mcp_result_success "$1"; }
