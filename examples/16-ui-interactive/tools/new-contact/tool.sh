#!/usr/bin/env bash
set -euo pipefail

# shellcheck disable=SC1091
source "${MCP_SDK:?MCP_SDK environment variable not set}/tool-sdk.sh"

# This tool's job is just to surface its linked UI (the form). The form HTML is
# generated from tools/new-contact/ui/ui.meta.json (template: "form"). When the
# user submits, the form's JS calls app.callServerTool({ name: "save-contact", ... }).
mcp_result_success "$(mcp_json_obj ready true hint "Fill in the form and press Submit")"
