#!/usr/bin/env bats
# Unit tests for UI template generation

load '../../node_modules/bats-support/load'
load '../../node_modules/bats-assert/load'
load '../common/fixtures'

setup_file() {
	# shellcheck source=lib/runtime.sh
	# shellcheck disable=SC1091
	. "${MCPBASH_HOME}/lib/runtime.sh"
	# shellcheck source=lib/json.sh
	# shellcheck disable=SC1091
	. "${MCPBASH_HOME}/lib/json.sh"

	MCPBASH_FORCE_MINIMAL=false
	mcp_runtime_detect_json_tool
	if [ "${MCPBASH_MODE}" = "minimal" ]; then
		skip "JSON tooling unavailable"
	fi
	export MCPBASH_MODE MCPBASH_JSON_TOOL MCPBASH_JSON_TOOL_BIN
}

setup() {
	# shellcheck source=lib/runtime.sh
	# shellcheck disable=SC1091
	. "${MCPBASH_HOME}/lib/runtime.sh"
	# shellcheck source=lib/json.sh
	# shellcheck disable=SC1091
	. "${MCPBASH_HOME}/lib/json.sh"
	# shellcheck source=lib/ui-templates.sh
	# shellcheck disable=SC1091
	. "${MCPBASH_HOME}/lib/ui-templates.sh"
}

@test "template: form generates valid HTML5 with DOCTYPE" {
	local config='{"title":"Test Form","fields":[{"name":"x","type":"text"}],"submitTool":"test-tool"}'
	output="$(mcp_ui_template_form "${config}")"

	# Check for DOCTYPE
	[[ "${output}" == *'<!DOCTYPE html>'* ]]

	# Check for closing tags
	[[ "${output}" == *'</html>'* ]]
	[[ "${output}" == *'</body>'* ]]
}

@test "template: form includes title" {
	local config='{"title":"My Custom Form","fields":[],"submitTool":"test"}'
	output="$(mcp_ui_template_form "${config}")"

	[[ "${output}" == *'My Custom Form'* ]]
}

@test "template: form generates text input field" {
	local config='{"title":"Test","fields":[{"name":"username","type":"text","label":"Username"}],"submitTool":"test"}'
	output="$(mcp_ui_template_form "${config}")"

	[[ "${output}" == *'type="text"'* ]]
	[[ "${output}" == *'name="username"'* ]]
	[[ "${output}" == *'Username'* ]]
}

@test "template: form generates select field with options" {
	local config='{"title":"Test","fields":[{"name":"type","type":"select","options":["a","b","c"]}],"submitTool":"test"}'
	output="$(mcp_ui_template_form "${config}")"

	[[ "${output}" == *'<select'* ]]
	[[ "${output}" == *'<option'* ]]
	[[ "${output}" == *'>a</option>'* ]]
	[[ "${output}" == *'>b</option>'* ]]
}

@test "template: form generates textarea field" {
	local config='{"title":"Test","fields":[{"name":"notes","type":"textarea"}],"submitTool":"test"}'
	output="$(mcp_ui_template_form "${config}")"

	[[ "${output}" == *'<textarea'* ]]
	[[ "${output}" == *'name="notes"'* ]]
}

@test "template: form avoids inline onclick handlers" {
	local config='{"title":"Test","fields":[{"name":"x","type":"text"}],"submitTool":"test"}'
	output="$(mcp_ui_template_form "${config}")"

	# Should NOT contain inline event handlers (security best practice)
	[[ "${output}" != *'onclick='* ]]
	[[ "${output}" != *'onsubmit='* ]]
	[[ "${output}" != *'onerror='* ]]
}

@test "template: form includes MCP Apps SDK import" {
	local config='{"title":"Test","fields":[],"submitTool":"test"}'
	output="$(mcp_ui_template_form "${config}")"

	[[ "${output}" == *'@modelcontextprotocol/ext-apps'* ]]
}

@test "template: form marks required fields" {
	local config='{"title":"Test","fields":[{"name":"email","type":"email","required":true}],"submitTool":"test"}'
	output="$(mcp_ui_template_form "${config}")"

	[[ "${output}" == *'required'* ]]
}

@test "template: data-table generates table structure" {
	local config='{"title":"Results","columns":[{"key":"name","label":"Name"},{"key":"value","label":"Value"}]}'
	output="$(mcp_ui_template_data_table "${config}")"

	[[ "${output}" == *'<table'* ]]
	[[ "${output}" == *'<thead>'* ]]
	[[ "${output}" == *'<tbody'* ]]
	[[ "${output}" == *'Name'* ]]
	[[ "${output}" == *'Value'* ]]
}

@test "template: progress generates progress bar" {
	local config='{"title":"Operation Progress","showPercentage":true}'
	output="$(mcp_ui_template_progress "${config}")"

	[[ "${output}" == *'progress-bar'* ]]
	[[ "${output}" == *'progress-fill'* ]]
	[[ "${output}" == *'Operation Progress'* ]]
}

@test "template: progress includes cancel button when configured" {
	local config='{"title":"Progress","cancelTool":"abort-operation","cancelConfirm":"Are you sure?"}'
	output="$(mcp_ui_template_progress "${config}")"

	[[ "${output}" == *'cancelBtn'* ]]
	[[ "${output}" == *'Cancel'* ]]
}

@test "template: uses MCP Apps CSS variables" {
	local config='{"title":"Test","fields":[],"submitTool":"test"}'
	output="$(mcp_ui_template_form "${config}")"

	# Check for MCP Apps CSS variables
	[[ "${output}" == *'--font-sans'* ]] || [[ "${output}" == *'--color-text-primary'* ]] || [[ "${output}" == *'--color-background-primary'* ]]
}

@test "template: generate_from_template dispatches correctly" {
	local config='{"title":"Form Test","fields":[],"submitTool":"test"}'
	output="$(mcp_ui_generate_from_template "form" "${config}")"

	[[ "${output}" == *'<!DOCTYPE html>'* ]]
	[[ "${output}" == *'Form Test'* ]]
}

@test "template: generate_from_template fails for unknown template" {
	run mcp_ui_generate_from_template "nonexistent" "{}"
	assert_failure
}

@test "template: diff-viewer generates valid HTML with panels" {
	local config='{"title":"Code Changes","viewMode":"split","showLineNumbers":true}'
	output="$(mcp_ui_template_diff_viewer "${config}")"

	[[ "${output}" == *'<!DOCTYPE html>'* ]]
	[[ "${output}" == *'Code Changes'* ]]
	[[ "${output}" == *'diff-panels'* ]]
	[[ "${output}" == *'diff-panel'* ]]
}

@test "template: diff-viewer includes view mode buttons" {
	local config='{"title":"Diff","viewMode":"unified"}'
	output="$(mcp_ui_template_diff_viewer "${config}")"

	[[ "${output}" == *'splitBtn'* ]]
	[[ "${output}" == *'unifiedBtn'* ]]
}

@test "template: tree-view generates valid HTML with tree structure" {
	local config='{"title":"Files","showIcons":true,"expandLevel":2}'
	output="$(mcp_ui_template_tree_view "${config}")"

	[[ "${output}" == *'<!DOCTYPE html>'* ]]
	[[ "${output}" == *'Files'* ]]
	[[ "${output}" == *'tree-container'* ]]
	[[ "${output}" == *'searchInput'* ]]
}

@test "template: tree-view includes selectable option" {
	local config='{"title":"Tree","selectable":true,"onSelectTool":"select-node"}'
	output="$(mcp_ui_template_tree_view "${config}")"

	[[ "${output}" == *'selectable = true'* ]]
	[[ "${output}" == *'select-node'* ]]
}

@test "template: kanban generates valid HTML with columns" {
	local config='{"title":"Board","columns":[{"id":"todo","title":"To Do"},{"id":"done","title":"Done"}]}'
	output="$(mcp_ui_template_kanban "${config}")"

	[[ "${output}" == *'<!DOCTYPE html>'* ]]
	[[ "${output}" == *'Board'* ]]
	[[ "${output}" == *'kanban-container'* ]]
	[[ "${output}" == *'kanban-column'* ]]
}

@test "template: kanban includes drag-drop when enabled" {
	local config='{"title":"Kanban","draggable":true,"onMoveTool":"move-card"}'
	output="$(mcp_ui_template_kanban "${config}")"

	[[ "${output}" == *'draggable = true'* ]]
	[[ "${output}" == *'move-card'* ]]
}
