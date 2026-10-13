#!/usr/bin/env bash
# A success field in the tool's own data is not an envelope.
mcp_result_json '{"success": true, "count": 2}'
