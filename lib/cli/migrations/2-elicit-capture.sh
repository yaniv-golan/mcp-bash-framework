#!/usr/bin/env bash
# Migration rule; see lib/migrate_rules.sh for the contract.
# shellcheck disable=SC2034  # MIG_* are read by the engine that sources this file
MIG_ID=2-elicit-capture
MIG_API=2
MIG_KIND=manual
MIG_SCOPE="project-sh"
MIG_SUMMARY='capturing mcp_elicit* output with $(...) and parsing .action changes in 2.0'
MIG_FIX='keep "|| true" and the .action branch for now; 2.0 replaces it with mcp_elicit_* -v VAR'
mig_detect() { mig_grep_regex '[$][(][[:space:]]*mcp_elicit' "$1"; }
