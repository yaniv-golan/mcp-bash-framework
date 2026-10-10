#!/usr/bin/env bash
# Migration rule; see lib/migrate_rules.sh for the contract.
# shellcheck disable=SC2034  # MIG_* are read by the engine that sources this file
MIG_ID=2-result-error
MIG_API=2
MIG_KIND=manual
MIG_SCOPE="project-sh"
MIG_SUMMARY="mcp_result_error is removed in 2.0"
MIG_FIX='mcp_fail --type TYPE "MESSAGE" --data JSON'
mig_detect() { mig_grep_word mcp_result_error "$1"; }
