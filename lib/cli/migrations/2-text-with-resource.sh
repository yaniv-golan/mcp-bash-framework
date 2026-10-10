#!/usr/bin/env bash
# Migration rule; see lib/migrate_rules.sh for the contract.
# shellcheck disable=SC2034  # MIG_* are read by the engine that sources this file
MIG_ID=2-text-with-resource
MIG_API=2
MIG_REPLACEMENT=none
MIG_KIND=manual
MIG_SCOPE="project-sh"
MIG_SET=envelope
MIG_SUMMARY="mcp_result_text_with_resource (sends the {success, result} envelope) is removed in 2.0"
MIG_FIX='keep as is for now; 2.0 adds embedded resources to mcp_result_json/mcp_result_text'
# Part of the "envelope" set: it delegates to mcp_result_success, so the tool's
# outputSchema and UI reads must stay envelope-shaped until it is replaced.
mig_detect() { mig_grep_word mcp_result_text_with_resource "$1"; }
