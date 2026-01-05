#!/usr/bin/env bash
# Template: operators extend env defaults via this optional hook.
#
# This file is sourced by the MCP server before handling requests.
# Use it to configure environment for all tools in this project.
#
# For CLI testing with the same environment:
#   mcp-bash run-tool my-tool --with-server-env --args '{}'
# Or set MCPBASH_RUN_TOOL_SOURCE_SERVER_ENV=1 to always source this file.

# Placeholder variables; full configuration scaffolding arrives in later phases.
# Example (commented): export MCPBASH_LOG_LEVEL="info"
#
# Tool environment modes:
# - minimal   (default): PATH/HOME/TMPDIR/LANG plus MCP*/MCPBASH* only.
# - allowlist: minimal env plus variables listed in MCPBASH_TOOL_ENV_ALLOWLIST.
# - inherit  : full host environment; only use when all tools are trusted.
# Example (commented):
# export MCPBASH_TOOL_ENV_MODE="minimal"
# export MCPBASH_TOOL_ENV_ALLOWLIST="AWS_ACCESS_KEY_ID,AWS_SECRET_ACCESS_KEY"
