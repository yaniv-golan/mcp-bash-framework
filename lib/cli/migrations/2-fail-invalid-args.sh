#!/usr/bin/env bash
# Migration rule; see lib/migrate_rules.sh for the contract.
# shellcheck disable=SC2034  # MIG_* are read by the engine that sources this file
MIG_ID=2-fail-invalid-args
MIG_API=2
MIG_KIND=auto
MIG_SCOPE="project-sh"
MIG_SUMMARY="mcp_fail_invalid_args is removed in 2.0"
MIG_FIX='mcp_fail --type invalid_args "MESSAGE"'
mig_detect() { mig_grep_word mcp_fail_invalid_args "$1"; }
