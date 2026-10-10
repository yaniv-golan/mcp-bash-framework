#!/usr/bin/env bash
mcp_tools_policy_check() {
	mcp_tools_policy_check_default "$@" || return 1
	return 0
}
