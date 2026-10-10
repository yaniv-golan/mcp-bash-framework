#!/usr/bin/env bash
# Migration rule; see lib/migrate_rules.sh for the contract.
# shellcheck disable=SC2034  # MIG_* are read by the engine that sources this file
MIG_ID=2-compat-batches
MIG_API=2
MIG_KIND=manual
MIG_SCOPE="config server-sh"
MIG_SUMMARY="MCPBASH_COMPAT_BATCHES is removed in 2.0 (batches stay automatic for protocol 2025-03-26)"
MIG_FIX='remove it'
mig_detect() { mig_grep_word MCPBASH_COMPAT_BATCHES "$1"; }
