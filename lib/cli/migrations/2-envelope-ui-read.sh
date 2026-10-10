#!/usr/bin/env bash
# Migration rule; see lib/migrate_rules.sh for the contract.
# shellcheck disable=SC2034  # MIG_* are read by the engine that sources this file
MIG_ID=2-envelope-ui-read
MIG_API=2
MIG_KIND=manual
MIG_SCOPE="ui-html"
MIG_SUMMARY="UI reads structuredContent.result; with mcp_result_json the data is structuredContent itself"
MIG_FIX='read result.structuredContent directly'
mig_detect() { mig_grep_regex 'structuredContent[?]?[.]result([^A-Za-z0-9_]|$)' "$1"; }
