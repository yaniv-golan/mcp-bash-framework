#!/usr/bin/env bash
# UI Template Generation System
# Generates HTML from declarative JSON configurations per MCP Apps spec (SEP-1865)

set -euo pipefail

# Available templates
# Guard against re-sourcing: only initialize if not already declared
if ! declare -p MCP_UI_TEMPLATES &>/dev/null; then
	declare -gA MCP_UI_TEMPLATES
	MCP_UI_TEMPLATES=(
		["form"]="mcp_ui_template_form"
		["data-table"]="mcp_ui_template_data_table"
		["progress"]="mcp_ui_template_progress"
		["diff-viewer"]="mcp_ui_template_diff_viewer"
		["tree-view"]="mcp_ui_template_tree_view"
		["kanban"]="mcp_ui_template_kanban"
	)
fi

MCP_UI_TEMPLATES_LOGGER="${MCP_UI_TEMPLATES_LOGGER:-mcp.ui.templates}"

# --- Main generator ---

# Generate HTML from template configuration
# Usage: mcp_ui_generate_from_template <template_name> <config_json>
mcp_ui_generate_from_template() {
	local template_name="$1"
	local config="$2"

	local generator="${MCP_UI_TEMPLATES[${template_name}]:-}"
	if [ -z "${generator}" ]; then
		printf '%s\n' "Unknown template: ${template_name}" >&2
		return 1
	fi

	"${generator}" "${config}"
}

# --- Common HTML helpers ---

# Generate HTML document header with MCP Apps theming support
_mcp_ui_html_header() {
	local title="$1"
	cat <<'HTML_HEADER'
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <style>
    /* Reset and base styles using MCP Apps CSS variables */
    *, *::before, *::after { box-sizing: border-box; margin: 0; padding: 0; }

    body {
      font-family: var(--font-sans, system-ui, -apple-system, sans-serif);
      font-size: var(--font-text-md-size, 14px);
      line-height: var(--font-text-md-line-height, 1.5);
      color: var(--color-text-primary, #1a1a1a);
      background: var(--color-background-primary, #ffffff);
      padding: 16px;
    }

    h1, h2, h3 {
      font-weight: var(--font-weight-semibold, 600);
      color: var(--color-text-primary, #1a1a1a);
      margin-bottom: 16px;
    }

    h2 { font-size: var(--font-heading-md-size, 18px); }

    /* Form styles */
    .form-group {
      margin-bottom: 16px;
    }

    label {
      display: block;
      margin-bottom: 4px;
      font-weight: var(--font-weight-medium, 500);
      color: var(--color-text-secondary, #666);
      font-size: var(--font-text-sm-size, 12px);
    }

    input, select, textarea {
      width: 100%;
      padding: 8px 12px;
      border: var(--border-width-regular, 1px) solid var(--color-border-primary, #ccc);
      border-radius: var(--border-radius-md, 6px);
      font-family: inherit;
      font-size: var(--font-text-md-size, 14px);
      background: var(--color-background-primary, #fff);
      color: var(--color-text-primary, #1a1a1a);
      transition: border-color 0.15s, box-shadow 0.15s;
    }

    input:focus, select:focus, textarea:focus {
      outline: none;
      border-color: var(--color-border-info, #0066cc);
      box-shadow: 0 0 0 3px var(--color-ring-info, rgba(0, 102, 204, 0.15));
    }

    textarea {
      min-height: 100px;
      resize: vertical;
    }

    /* Button styles */
    button, .btn {
      display: inline-flex;
      align-items: center;
      justify-content: center;
      padding: 8px 16px;
      font-family: inherit;
      font-size: var(--font-text-md-size, 14px);
      font-weight: var(--font-weight-medium, 500);
      border-radius: var(--border-radius-md, 6px);
      border: none;
      cursor: pointer;
      transition: background-color 0.15s, transform 0.1s;
    }

    button[type="submit"], .btn-primary {
      background: var(--color-background-info, #0066cc);
      color: var(--color-text-inverse, #fff);
    }

    button[type="submit"]:hover, .btn-primary:hover {
      background: var(--color-background-info, #0052a3);
    }

    button[type="button"], .btn-secondary {
      background: var(--color-background-secondary, #f0f0f0);
      color: var(--color-text-primary, #1a1a1a);
      border: var(--border-width-regular, 1px) solid var(--color-border-primary, #ccc);
    }

    button:disabled {
      background: var(--color-background-disabled, #e0e0e0);
      color: var(--color-text-disabled, #999);
      cursor: not-allowed;
    }

    /* Table styles */
    table {
      width: 100%;
      border-collapse: collapse;
      font-size: var(--font-text-sm-size, 13px);
    }

    th, td {
      padding: 10px 12px;
      text-align: left;
      border-bottom: var(--border-width-regular, 1px) solid var(--color-border-secondary, #eee);
    }

    th {
      font-weight: var(--font-weight-semibold, 600);
      color: var(--color-text-secondary, #666);
      background: var(--color-background-secondary, #f8f8f8);
    }

    tr:hover td {
      background: var(--color-background-ghost, rgba(0,0,0,0.02));
    }

    /* Progress styles */
    .progress-container {
      margin: 16px 0;
    }

    .progress-bar {
      height: 8px;
      background: var(--color-background-secondary, #e0e0e0);
      border-radius: var(--border-radius-full, 9999px);
      overflow: hidden;
    }

    .progress-fill {
      height: 100%;
      background: var(--color-background-success, #22c55e);
      transition: width 0.3s ease;
    }

    .progress-text {
      margin-top: 8px;
      font-size: var(--font-text-sm-size, 12px);
      color: var(--color-text-secondary, #666);
    }

    /* Status indicators */
    .status-success { color: var(--color-text-success, #16a34a); }
    .status-warning { color: var(--color-text-warning, #ca8a04); }
    .status-danger { color: var(--color-text-danger, #dc2626); }
    .status-info { color: var(--color-text-info, #0066cc); }

    /* Message/alert styles */
    .message {
      padding: 12px 16px;
      border-radius: var(--border-radius-md, 6px);
      margin-bottom: 16px;
    }

    .message-success {
      background: var(--color-background-success, #dcfce7);
      color: var(--color-text-success, #166534);
    }

    .message-error {
      background: var(--color-background-danger, #fef2f2);
      color: var(--color-text-danger, #991b1b);
    }

    /* Loading spinner */
    .spinner {
      display: inline-block;
      width: 16px;
      height: 16px;
      border: 2px solid var(--color-border-secondary, #e0e0e0);
      border-top-color: var(--color-border-info, #0066cc);
      border-radius: 50%;
      animation: spin 0.8s linear infinite;
    }

    @keyframes spin {
      to { transform: rotate(360deg); }
    }

    /* Utility classes */
    .hidden { display: none !important; }
    .text-center { text-align: center; }
    .mt-4 { margin-top: 16px; }
    .mb-4 { margin-bottom: 16px; }
    .flex { display: flex; }
    .gap-2 { gap: 8px; }
    .justify-end { justify-content: flex-end; }
  </style>
HTML_HEADER
	printf '  <title>%s</title>\n' "${title}"
	printf '</head>\n<body>\n'
}

# Generate HTML document footer with MCP Apps SDK
_mcp_ui_html_footer() {
	cat <<'HTML_FOOTER'
</body>
</html>
HTML_FOOTER
}

# Escape HTML entities
_mcp_ui_escape_html() {
	local text="$1"
	text="${text//&/&amp;}"
	text="${text//</&lt;}"
	text="${text//>/&gt;}"
	text="${text//\"/&quot;}"
	printf '%s' "${text}"
}

# --- Form Template ---

mcp_ui_template_form() {
	local config="$1"

	local title
	title="$("${MCPBASH_JSON_TOOL_BIN}" -r '.title // "Form"' <<<"${config}")"
	local description
	description="$("${MCPBASH_JSON_TOOL_BIN}" -r '.description // ""' <<<"${config}")"
	local submit_tool
	submit_tool="$("${MCPBASH_JSON_TOOL_BIN}" -r '.submitTool // ""' <<<"${config}")"
	local submit_args
	submit_args="$("${MCPBASH_JSON_TOOL_BIN}" -c '.submitArgs // {}' <<<"${config}")"
	local cancelable
	cancelable="$("${MCPBASH_JSON_TOOL_BIN}" -r '.cancelable // false' <<<"${config}")"

	_mcp_ui_html_header "${title}"

	printf '  <h2>%s</h2>\n' "$(_mcp_ui_escape_html "${title}")"
	if [ -n "${description}" ]; then
		printf '  <p class="mb-4" style="color: var(--color-text-secondary);">%s</p>\n' "$(_mcp_ui_escape_html "${description}")"
	fi

	printf '  <div id="message" class="message hidden"></div>\n'
	printf '  <form id="form">\n'

	# Generate form fields
	"${MCPBASH_JSON_TOOL_BIN}" -c '.fields // []' <<<"${config}" | "${MCPBASH_JSON_TOOL_BIN}" -c '.[]' 2>/dev/null | while IFS= read -r field; do
		local name type label required placeholder default_val
		name="$("${MCPBASH_JSON_TOOL_BIN}" -r '.name' <<<"${field}")"
		type="$("${MCPBASH_JSON_TOOL_BIN}" -r '.type // "text"' <<<"${field}")"
		label="$("${MCPBASH_JSON_TOOL_BIN}" -r '.label // .name' <<<"${field}")"
		required="$("${MCPBASH_JSON_TOOL_BIN}" -r '.required // false' <<<"${field}")"
		placeholder="$("${MCPBASH_JSON_TOOL_BIN}" -r '.placeholder // ""' <<<"${field}")"
		default_val="$("${MCPBASH_JSON_TOOL_BIN}" -r '.default // ""' <<<"${field}")"

		local required_attr=""
		[ "${required}" = "true" ] && required_attr="required"

		printf '    <div class="form-group">\n'
		printf '      <label for="%s">%s%s</label>\n' \
			"$(_mcp_ui_escape_html "${name}")" \
			"$(_mcp_ui_escape_html "${label}")" \
			"$([ "${required}" = "true" ] && printf ' <span style="color: var(--color-text-danger);">*</span>')"

		case "${type}" in
		select)
			printf '      <select id="%s" name="%s" %s>\n' \
				"$(_mcp_ui_escape_html "${name}")" \
				"$(_mcp_ui_escape_html "${name}")" \
				"${required_attr}"
			"${MCPBASH_JSON_TOOL_BIN}" -r '.options[]' <<<"${field}" 2>/dev/null | while IFS= read -r opt; do
				local selected=""
				[ "${opt}" = "${default_val}" ] && selected="selected"
				printf '        <option value="%s" %s>%s</option>\n' \
					"$(_mcp_ui_escape_html "${opt}")" \
					"${selected}" \
					"$(_mcp_ui_escape_html "${opt}")"
			done
			printf '      </select>\n'
			;;
		textarea)
			printf '      <textarea id="%s" name="%s" placeholder="%s" %s>%s</textarea>\n' \
				"$(_mcp_ui_escape_html "${name}")" \
				"$(_mcp_ui_escape_html "${name}")" \
				"$(_mcp_ui_escape_html "${placeholder}")" \
				"${required_attr}" \
				"$(_mcp_ui_escape_html "${default_val}")"
			;;
		checkbox)
			local checked=""
			[ "${default_val}" = "true" ] && checked="checked"
			printf '      <input type="checkbox" id="%s" name="%s" %s style="width: auto;">\n' \
				"$(_mcp_ui_escape_html "${name}")" \
				"$(_mcp_ui_escape_html "${name}")" \
				"${checked}"
			;;
		*)
			printf '      <input type="%s" id="%s" name="%s" placeholder="%s" value="%s" %s>\n' \
				"$(_mcp_ui_escape_html "${type}")" \
				"$(_mcp_ui_escape_html "${name}")" \
				"$(_mcp_ui_escape_html "${name}")" \
				"$(_mcp_ui_escape_html "${placeholder}")" \
				"$(_mcp_ui_escape_html "${default_val}")" \
				"${required_attr}"
			;;
		esac

		printf '    </div>\n'
	done

	printf '    <div class="flex gap-2 justify-end mt-4">\n'
	if [ "${cancelable}" = "true" ]; then
		printf '      <button type="button" id="cancelBtn">Cancel</button>\n'
	fi
	printf '      <button type="submit" id="submitBtn">Submit</button>\n'
	printf '    </div>\n'
	printf '  </form>\n'

	# JavaScript for form handling with MCP Apps SDK
	cat <<SCRIPT
  <script type="module">
    import { App } from 'https://cdn.jsdelivr.net/npm/@modelcontextprotocol/ext-apps/+esm';

    const form = document.getElementById('form');
    const app = new App({ name: "Form App", version: "1.0.0" });
    await app.connect();
    const message = document.getElementById('message');
    const submitBtn = document.getElementById('submitBtn');
    const cancelBtn = document.getElementById('cancelBtn');

    function showMessage(text, isError = false) {
      message.textContent = text;
      message.className = 'message ' + (isError ? 'message-error' : 'message-success');
      message.classList.remove('hidden');
    }

    form.addEventListener('submit', async (e) => {
      e.preventDefault();
      submitBtn.disabled = true;
      submitBtn.innerHTML = '<span class="spinner"></span> Submitting...';
      message.classList.add('hidden');

      const formData = new FormData(form);
      const data = Object.fromEntries(formData);

      // Merge with configured submit args
      const submitArgs = ${submit_args};
      const finalArgs = { ...submitArgs, ...data };

      try {
        const result = await app.callTool('${submit_tool}', finalArgs);
        showMessage('Form submitted successfully');
        app.sendMessage('Form submitted: ' + JSON.stringify(data));
      } catch (err) {
        showMessage('Error: ' + (err.message || 'Unknown error'), true);
      } finally {
        submitBtn.disabled = false;
        submitBtn.textContent = 'Submit';
      }
    });

    if (cancelBtn) {
      cancelBtn.addEventListener('click', () => {
        app.sendMessage('Form cancelled');
      });
    }
  </script>
SCRIPT

	_mcp_ui_html_footer
}

# --- Data Table Template ---

mcp_ui_template_data_table() {
	local config="$1"

	local title
	title="$("${MCPBASH_JSON_TOOL_BIN}" -r '.title // "Data"' <<<"${config}")"
	local columns
	columns="$("${MCPBASH_JSON_TOOL_BIN}" -c '.columns // []' <<<"${config}")"

	_mcp_ui_html_header "${title}"

	printf '  <h2>%s</h2>\n' "$(_mcp_ui_escape_html "${title}")"
	printf '  <div id="tableContainer">\n'
	printf '    <table id="dataTable">\n'
	printf '      <thead><tr>\n'

	# Generate column headers
	"${MCPBASH_JSON_TOOL_BIN}" -c '.[]' <<<"${columns}" 2>/dev/null | while IFS= read -r col; do
		local col_label sortable
		col_label="$("${MCPBASH_JSON_TOOL_BIN}" -r '.label // .key' <<<"${col}")"
		sortable="$("${MCPBASH_JSON_TOOL_BIN}" -r '.sortable // false' <<<"${col}")"
		local sort_attr=""
		[ "${sortable}" = "true" ] && sort_attr='style="cursor: pointer;" data-sortable="true"'
		printf '        <th %s>%s</th>\n' "${sort_attr}" "$(_mcp_ui_escape_html "${col_label}")"
	done

	printf '      </tr></thead>\n'
	printf '      <tbody id="tableBody">\n'
	printf '        <tr><td colspan="100" class="text-center" style="color: var(--color-text-tertiary);">Loading data...</td></tr>\n'
	printf '      </tbody>\n'
	printf '    </table>\n'
	printf '  </div>\n'

	# JavaScript for data table
	cat <<SCRIPT
  <script type="module">
    import { App } from 'https://cdn.jsdelivr.net/npm/@modelcontextprotocol/ext-apps/+esm';

    const columns = ${columns};
    const tbody = document.getElementById('tableBody');

    function renderTable(data) {
      if (!data || data.length === 0) {
        tbody.innerHTML = '<tr><td colspan="100" class="text-center">No data</td></tr>';
        return;
      }

      tbody.innerHTML = data.map(row => {
        return '<tr>' + columns.map(col => {
          const value = row[col.key] ?? '';
          return '<td>' + escapeHtml(String(value)) + '</td>';
        }).join('') + '</tr>';
      }).join('');
    }

    function escapeHtml(text) {
      const div = document.createElement('div');
      div.textContent = text;
      return div.innerHTML;
    }

    // Create app and set handler BEFORE connect
    const app = new App({ name: "Data Table", version: "1.0.0" });
    app.ontoolresult = (result) => {
      let data = result?.structuredContent;
      if (!data && result?.content) {
        const textContent = result.content.find(c => c.type === 'text');
        if (textContent) {
          try { data = JSON.parse(textContent.text); } catch (e) {
            tbody.innerHTML = '<tr><td colspan="100">Error parsing data</td></tr>';
            return;
          }
        }
      }
      if (data) {
        const items = data.items || (Array.isArray(data) ? data : [data]);
        renderTable(items);
      }
    };
    await app.connect();

    // Initial message
    tbody.innerHTML = '<tr><td colspan="100" class="text-center" style="color: var(--color-text-tertiary);">Waiting for data...</td></tr>';
  </script>
SCRIPT

	_mcp_ui_html_footer
}

# --- Progress Template ---

mcp_ui_template_progress() {
	local config="$1"

	local title
	title="$("${MCPBASH_JSON_TOOL_BIN}" -r '.title // "Progress"' <<<"${config}")"
	local show_percentage
	show_percentage="$("${MCPBASH_JSON_TOOL_BIN}" -r '.showPercentage // true' <<<"${config}")"
	local show_step
	show_step="$("${MCPBASH_JSON_TOOL_BIN}" -r '.showCurrentStep // true' <<<"${config}")"
	local cancel_tool
	cancel_tool="$("${MCPBASH_JSON_TOOL_BIN}" -r '.cancelTool // ""' <<<"${config}")"
	local cancel_confirm
	cancel_confirm="$("${MCPBASH_JSON_TOOL_BIN}" -r '.cancelConfirm // "Are you sure you want to cancel?"' <<<"${config}")"

	_mcp_ui_html_header "${title}"

	printf '  <h2>%s</h2>\n' "$(_mcp_ui_escape_html "${title}")"

	printf '  <div class="progress-container">\n'
	printf '    <div class="progress-bar"><div class="progress-fill" id="progressFill" style="width: 0%%"></div></div>\n'
	if [ "${show_percentage}" = "true" ]; then
		printf '    <div class="progress-text"><span id="progressPercent">0</span>%% complete</div>\n'
	fi
	printf '  </div>\n'

	if [ "${show_step}" = "true" ]; then
		printf '  <div id="currentStep" class="mt-4" style="color: var(--color-text-secondary);"></div>\n'
	fi

	printf '  <div id="stepList" class="mt-4"></div>\n'

	if [ -n "${cancel_tool}" ]; then
		printf '  <div class="mt-4">\n'
		printf '    <button type="button" id="cancelBtn" class="btn-secondary">Cancel</button>\n'
		printf '  </div>\n'
	fi

	# JavaScript for progress tracking
	cat <<SCRIPT
  <script type="module">
    import { App } from 'https://cdn.jsdelivr.net/npm/@modelcontextprotocol/ext-apps/+esm';

    const progressFill = document.getElementById('progressFill');
    const progressPercent = document.getElementById('progressPercent');
    const currentStep = document.getElementById('currentStep');
    const stepList = document.getElementById('stepList');
    const cancelBtn = document.getElementById('cancelBtn');

    let completedSteps = [];

    function updateProgress(percent, message) {
      progressFill.style.width = percent + '%';
      if (progressPercent) progressPercent.textContent = Math.round(percent);
      if (currentStep && message) currentStep.textContent = message;
    }

    function renderSteps() {
      if (stepList) {
        stepList.innerHTML = completedSteps.map((step, i) =>
          '<div style="padding: 4px 0;"><span class="status-success">✓</span> ' + escapeHtml(step) + '</div>'
        ).join('');
      }
    }

    function escapeHtml(text) {
      const div = document.createElement('div');
      div.textContent = text;
      return div.innerHTML;
    }

    // Create app and set handler BEFORE connect
    const app = new App({ name: "Progress Tracker", version: "1.0.0" });
    app.ontoolresult = (result) => {
      if (result?.structuredContent) {
        const data = result.structuredContent;
        completedSteps.push(data.message || data.step || JSON.stringify(data));
        renderSteps();
      } else if (result?.content) {
        const textContent = result.content.find(c => c.type === 'text');
        if (textContent) {
          completedSteps.push(textContent.text);
          renderSteps();
        }
      }
    };
    await app.connect();

    if (cancelBtn) {
      cancelBtn.addEventListener('click', async () => {
        const confirmMsg = '${cancel_confirm}';
        if (confirm(confirmMsg)) {
          try {
            await app.callTool('${cancel_tool}', {});
            app.sendMessage('Operation cancelled');
          } catch (err) {
            console.error('Cancel failed:', err);
          }
        }
      });
    }
  </script>
SCRIPT

	_mcp_ui_html_footer
}

# --- Diff Viewer Template ---

mcp_ui_template_diff_viewer() {
	local config="$1"

	local title
	title="$("${MCPBASH_JSON_TOOL_BIN}" -r '.title // "Diff Viewer"' <<<"${config}")"
	local view_mode
	view_mode="$("${MCPBASH_JSON_TOOL_BIN}" -r '.viewMode // "split"' <<<"${config}")"
	local show_line_numbers
	show_line_numbers="$("${MCPBASH_JSON_TOOL_BIN}" -r '.showLineNumbers // true' <<<"${config}")"
	local syntax_highlight
	syntax_highlight="$("${MCPBASH_JSON_TOOL_BIN}" -r '.syntaxHighlight // true' <<<"${config}")"
	local left_title
	left_title="$("${MCPBASH_JSON_TOOL_BIN}" -r '.leftTitle // "Original"' <<<"${config}")"
	local right_title
	right_title="$("${MCPBASH_JSON_TOOL_BIN}" -r '.rightTitle // "Modified"' <<<"${config}")"

	_mcp_ui_html_header "${title}"

	# Additional diff-specific styles
	cat <<'DIFF_STYLES'
  <style>
    .diff-container {
      display: flex;
      flex-direction: column;
      gap: 16px;
      font-family: var(--font-mono, monospace);
    }

    .diff-header {
      display: flex;
      justify-content: space-between;
      align-items: center;
      margin-bottom: 8px;
    }

    .diff-controls {
      display: flex;
      gap: 8px;
    }

    .diff-controls button {
      padding: 4px 12px;
      font-size: var(--font-text-sm-size, 12px);
    }

    .diff-controls button.active {
      background: var(--color-background-info, #0066cc);
      color: var(--color-text-inverse, #fff);
    }

    .diff-panels {
      display: flex;
      gap: 8px;
      overflow-x: auto;
    }

    .diff-panels.unified {
      flex-direction: column;
    }

    .diff-panel {
      flex: 1;
      min-width: 300px;
      border: var(--border-width-regular, 1px) solid var(--color-border-primary, #ccc);
      border-radius: var(--border-radius-md, 6px);
      overflow: hidden;
    }

    .diff-panels.unified .diff-panel {
      min-width: auto;
    }

    .diff-panel-header {
      padding: 8px 12px;
      background: var(--color-background-secondary, #f8f8f8);
      border-bottom: var(--border-width-regular, 1px) solid var(--color-border-secondary, #eee);
      font-weight: var(--font-weight-medium, 500);
      font-size: var(--font-text-sm-size, 12px);
      color: var(--color-text-secondary, #666);
    }

    .diff-content {
      overflow: auto;
      max-height: 500px;
    }

    .diff-line {
      display: flex;
      font-size: var(--font-text-sm-size, 13px);
      line-height: 1.5;
    }

    .diff-line-number {
      min-width: 40px;
      padding: 0 8px;
      text-align: right;
      color: var(--color-text-tertiary, #999);
      background: var(--color-background-secondary, #f8f8f8);
      border-right: var(--border-width-regular, 1px) solid var(--color-border-secondary, #eee);
      user-select: none;
    }

    .diff-line-content {
      flex: 1;
      padding: 0 8px;
      white-space: pre;
      overflow-x: auto;
    }

    .diff-line.added {
      background: var(--color-background-success, rgba(34, 197, 94, 0.15));
    }

    .diff-line.added .diff-line-content::before {
      content: '+';
      color: var(--color-text-success, #16a34a);
      margin-right: 4px;
    }

    .diff-line.removed {
      background: var(--color-background-danger, rgba(239, 68, 68, 0.15));
    }

    .diff-line.removed .diff-line-content::before {
      content: '-';
      color: var(--color-text-danger, #dc2626);
      margin-right: 4px;
    }

    .diff-line.modified {
      background: var(--color-background-warning, rgba(234, 179, 8, 0.15));
    }

    .diff-line.context {
      background: transparent;
    }

    .diff-empty {
      padding: 20px;
      text-align: center;
      color: var(--color-text-tertiary, #999);
    }

    /* Syntax highlighting tokens */
    .token-keyword { color: #d73a49; }
    .token-string { color: #22863a; }
    .token-number { color: #005cc5; }
    .token-comment { color: #6a737d; font-style: italic; }
    .token-function { color: #6f42c1; }
  </style>
DIFF_STYLES

	printf '  <h2>%s</h2>\n' "$(_mcp_ui_escape_html "${title}")"

	printf '  <div class="diff-container">\n'
	printf '    <div class="diff-header">\n'
	printf '      <span id="diffStats"></span>\n'
	printf '      <div class="diff-controls">\n'
	printf '        <button type="button" id="splitBtn" class="%s">Split</button>\n' "$([ "${view_mode}" = "split" ] && printf 'active')"
	printf '        <button type="button" id="unifiedBtn" class="%s">Unified</button>\n' "$([ "${view_mode}" = "unified" ] && printf 'active')"
	printf '      </div>\n'
	printf '    </div>\n'

	printf '    <div class="diff-panels" id="diffPanels">\n'
	printf '      <div class="diff-panel">\n'
	printf '        <div class="diff-panel-header">%s</div>\n' "$(_mcp_ui_escape_html "${left_title}")"
	printf '        <div class="diff-content" id="leftContent"><div class="diff-empty">Waiting for data...</div></div>\n'
	printf '      </div>\n'
	printf '      <div class="diff-panel" id="rightPanel">\n'
	printf '        <div class="diff-panel-header">%s</div>\n' "$(_mcp_ui_escape_html "${right_title}")"
	printf '        <div class="diff-content" id="rightContent"><div class="diff-empty">Waiting for data...</div></div>\n'
	printf '      </div>\n'
	printf '    </div>\n'
	printf '  </div>\n'

	# JavaScript for diff viewer
	cat <<SCRIPT
  <script type="module">
    import { App } from 'https://cdn.jsdelivr.net/npm/@modelcontextprotocol/ext-apps/+esm';

    const diffPanels = document.getElementById('diffPanels');
    const leftContent = document.getElementById('leftContent');
    const rightContent = document.getElementById('rightContent');
    const rightPanel = document.getElementById('rightPanel');
    const diffStats = document.getElementById('diffStats');
    const splitBtn = document.getElementById('splitBtn');
    const unifiedBtn = document.getElementById('unifiedBtn');

    const showLineNumbers = ${show_line_numbers};
    const syntaxHighlight = ${syntax_highlight};
    let currentMode = '${view_mode}';

    function setViewMode(mode) {
      currentMode = mode;
      splitBtn.classList.toggle('active', mode === 'split');
      unifiedBtn.classList.toggle('active', mode === 'unified');
      diffPanels.classList.toggle('unified', mode === 'unified');
      rightPanel.style.display = mode === 'unified' ? 'none' : '';
    }

    splitBtn.addEventListener('click', () => setViewMode('split'));
    unifiedBtn.addEventListener('click', () => setViewMode('unified'));

    function escapeHtml(text) {
      const div = document.createElement('div');
      div.textContent = text;
      return div.innerHTML;
    }

    function highlightSyntax(text) {
      if (!syntaxHighlight) return escapeHtml(text);
      // Basic syntax highlighting
      return escapeHtml(text)
        .replace(/\b(function|const|let|var|if|else|for|while|return|import|export|class)\b/g, '<span class="token-keyword">\$1</span>')
        .replace(/(["'])(?:(?!\1)[^\\\\]|\\\\.)*\1/g, '<span class="token-string">\$&</span>')
        .replace(/\b(\d+)\b/g, '<span class="token-number">\$1</span>')
        .replace(/(\/\/[^\n]*)/g, '<span class="token-comment">\$1</span>');
    }

    function renderLine(lineNum, content, type) {
      const lineNumHtml = showLineNumbers ? '<div class="diff-line-number">' + lineNum + '</div>' : '';
      return '<div class="diff-line ' + type + '">' +
        lineNumHtml +
        '<div class="diff-line-content">' + highlightSyntax(content) + '</div>' +
        '</div>';
    }

    function renderDiff(leftLines, rightLines, changes) {
      let leftHtml = '';
      let rightHtml = '';
      let addedCount = 0, removedCount = 0;

      if (!changes || changes.length === 0) {
        // Simple side-by-side comparison
        const maxLines = Math.max(leftLines.length, rightLines.length);
        for (let i = 0; i < maxLines; i++) {
          const left = leftLines[i] || '';
          const right = rightLines[i] || '';
          const isDiff = left !== right;
          const type = isDiff ? 'modified' : 'context';
          leftHtml += renderLine(i + 1, left, type);
          rightHtml += renderLine(i + 1, right, type);
        }
      } else {
        // Process change hunks
        changes.forEach(change => {
          const type = change.added ? 'added' : change.removed ? 'removed' : 'context';
          if (change.added) addedCount += change.count || 1;
          if (change.removed) removedCount += change.count || 1;

          const lines = (change.value || '').split('\\n').filter(l => l !== '');
          lines.forEach((line, idx) => {
            const lineNum = change.lineNumber ? change.lineNumber + idx : idx + 1;
            if (change.added) {
              rightHtml += renderLine(lineNum, line, 'added');
            } else if (change.removed) {
              leftHtml += renderLine(lineNum, line, 'removed');
            } else {
              leftHtml += renderLine(lineNum, line, 'context');
              rightHtml += renderLine(lineNum, line, 'context');
            }
          });
        });
      }

      leftContent.innerHTML = leftHtml || '<div class="diff-empty">No content</div>';
      rightContent.innerHTML = rightHtml || '<div class="diff-empty">No content</div>';
      diffStats.textContent = '+' + addedCount + ' / -' + removedCount + ' lines';
    }

    // Create app and set handler BEFORE connect
    const app = new App({ name: "Diff Viewer", version: "1.0.0" });
    app.ontoolresult = (result) => {
      let data = result?.structuredContent;
      if (!data && result?.content) {
        const textContent = result.content.find(c => c.type === 'text');
        if (textContent) {
          try { data = JSON.parse(textContent.text); } catch (e) {
            leftContent.innerHTML = '<div class="diff-empty">Error parsing diff data</div>';
            return;
          }
        }
      }
      if (data) {
        const leftLines = (data.left || data.original || '').split('\\n');
        const rightLines = (data.right || data.modified || '').split('\\n');
        renderDiff(leftLines, rightLines, data.changes);
      }
    };
    await app.connect();

    setViewMode(currentMode);
  </script>
SCRIPT

	_mcp_ui_html_footer
}

# --- Tree View Template ---

mcp_ui_template_tree_view() {
	local config="$1"

	local title
	title="$("${MCPBASH_JSON_TOOL_BIN}" -r '.title // "Tree View"' <<<"${config}")"
	local show_icons
	show_icons="$("${MCPBASH_JSON_TOOL_BIN}" -r '.showIcons // true' <<<"${config}")"
	local expand_level
	expand_level="$("${MCPBASH_JSON_TOOL_BIN}" -r '.expandLevel // 1' <<<"${config}")"
	local selectable
	selectable="$("${MCPBASH_JSON_TOOL_BIN}" -r '.selectable // false' <<<"${config}")"
	local on_select_tool
	on_select_tool="$("${MCPBASH_JSON_TOOL_BIN}" -r '.onSelectTool // ""' <<<"${config}")"

	_mcp_ui_html_header "${title}"

	# Tree-specific styles
	cat <<'TREE_STYLES'
  <style>
    .tree-container {
      font-family: var(--font-sans, system-ui, sans-serif);
    }

    .tree-search {
      margin-bottom: 12px;
    }

    .tree-search input {
      width: 100%;
      max-width: 300px;
    }

    .tree-node {
      user-select: none;
    }

    .tree-node-content {
      display: flex;
      align-items: center;
      padding: 4px 8px;
      border-radius: var(--border-radius-sm, 4px);
      cursor: pointer;
      transition: background-color 0.15s;
    }

    .tree-node-content:hover {
      background: var(--color-background-ghost, rgba(0, 0, 0, 0.04));
    }

    .tree-node-content.selected {
      background: var(--color-background-info, rgba(0, 102, 204, 0.1));
    }

    .tree-toggle {
      width: 20px;
      height: 20px;
      display: flex;
      align-items: center;
      justify-content: center;
      margin-right: 4px;
      color: var(--color-text-tertiary, #999);
      font-size: 10px;
      transition: transform 0.15s;
    }

    .tree-toggle.expanded {
      transform: rotate(90deg);
    }

    .tree-toggle.leaf {
      visibility: hidden;
    }

    .tree-icon {
      width: 18px;
      height: 18px;
      margin-right: 6px;
      display: flex;
      align-items: center;
      justify-content: center;
      font-size: 14px;
    }

    .tree-icon.folder { color: var(--color-text-warning, #ca8a04); }
    .tree-icon.file { color: var(--color-text-secondary, #666); }
    .tree-icon.default { color: var(--color-text-tertiary, #999); }

    .tree-label {
      flex: 1;
      font-size: var(--font-text-sm-size, 13px);
      color: var(--color-text-primary, #1a1a1a);
      overflow: hidden;
      text-overflow: ellipsis;
      white-space: nowrap;
    }

    .tree-meta {
      font-size: var(--font-text-xs-size, 11px);
      color: var(--color-text-tertiary, #999);
      margin-left: 8px;
    }

    .tree-children {
      margin-left: 20px;
      overflow: hidden;
      transition: max-height 0.2s ease-out;
    }

    .tree-children.collapsed {
      max-height: 0 !important;
    }

    .tree-empty {
      padding: 20px;
      text-align: center;
      color: var(--color-text-tertiary, #999);
    }

    .tree-stats {
      margin-top: 12px;
      font-size: var(--font-text-xs-size, 11px);
      color: var(--color-text-tertiary, #999);
    }
  </style>
TREE_STYLES

	printf '  <h2>%s</h2>\n' "$(_mcp_ui_escape_html "${title}")"

	printf '  <div class="tree-container">\n'
	printf '    <div class="tree-search">\n'
	printf '      <input type="text" id="searchInput" placeholder="Filter...">\n'
	printf '    </div>\n'
	printf '    <div id="treeRoot" class="tree-empty">Waiting for data...</div>\n'
	printf '    <div id="treeStats" class="tree-stats"></div>\n'
	printf '  </div>\n'

	# JavaScript for tree view
	cat <<SCRIPT
  <script type="module">
    import { App } from 'https://cdn.jsdelivr.net/npm/@modelcontextprotocol/ext-apps/+esm';

    const treeRoot = document.getElementById('treeRoot');
    const treeStats = document.getElementById('treeStats');
    const searchInput = document.getElementById('searchInput');

    const showIcons = ${show_icons};
    const expandLevel = ${expand_level};
    const selectable = ${selectable};
    const onSelectTool = '${on_select_tool}';

    let treeData = null;
    let selectedNode = null;

    const defaultIcons = {
      folder: '\u{1F4C1}',
      'folder-open': '\u{1F4C2}',
      file: '\u{1F4C4}',
      default: '\u{25CF}'
    };

    function getIcon(node, isExpanded) {
      if (!showIcons) return '';
      const iconType = node.icon || (node.children ? (isExpanded ? 'folder-open' : 'folder') : 'file');
      const iconChar = node.iconChar || defaultIcons[iconType] || defaultIcons.default;
      const iconClass = node.children ? 'folder' : 'file';
      return '<div class="tree-icon ' + iconClass + '">' + iconChar + '</div>';
    }

    function renderNode(node, level = 0, filter = '') {
      const hasChildren = node.children && node.children.length > 0;
      const isExpanded = level < expandLevel;
      const matchesFilter = !filter || node.label.toLowerCase().includes(filter.toLowerCase());
      const childrenMatchFilter = hasChildren && node.children.some(c =>
        c.label.toLowerCase().includes(filter.toLowerCase()) ||
        (c.children && c.children.some(gc => gc.label.toLowerCase().includes(filter.toLowerCase())))
      );

      if (filter && !matchesFilter && !childrenMatchFilter) return '';

      const nodeId = 'node-' + Math.random().toString(36).substr(2, 9);
      let html = '<div class="tree-node" data-id="' + (node.id || nodeId) + '">';
      html += '<div class="tree-node-content" data-node-id="' + (node.id || nodeId) + '">';

      // Toggle button
      const toggleClass = hasChildren ? (isExpanded ? 'expanded' : '') : 'leaf';
      html += '<div class="tree-toggle ' + toggleClass + '">\u{25B6}</div>';

      // Icon
      html += getIcon(node, isExpanded);

      // Label
      html += '<span class="tree-label">' + escapeHtml(node.label) + '</span>';

      // Meta info
      if (node.meta) {
        html += '<span class="tree-meta">' + escapeHtml(node.meta) + '</span>';
      }

      html += '</div>';

      // Children
      if (hasChildren) {
        const childrenClass = isExpanded || (filter && childrenMatchFilter) ? '' : 'collapsed';
        html += '<div class="tree-children ' + childrenClass + '">';
        node.children.forEach(child => {
          html += renderNode(child, level + 1, filter);
        });
        html += '</div>';
      }

      html += '</div>';
      return html;
    }

    function renderTree(data, filter = '') {
      if (!data || (Array.isArray(data) && data.length === 0)) {
        treeRoot.innerHTML = '<div class="tree-empty">No data</div>';
        treeStats.textContent = '';
        return;
      }

      const nodes = Array.isArray(data) ? data : [data];
      let html = '';
      nodes.forEach(node => {
        html += renderNode(node, 0, filter);
      });

      treeRoot.innerHTML = html;
      treeRoot.classList.remove('tree-empty');

      // Count nodes
      let count = 0;
      const countNodes = (n) => { count++; (n.children || []).forEach(countNodes); };
      nodes.forEach(countNodes);
      treeStats.textContent = count + ' items';

      // Attach event listeners
      attachTreeListeners();
    }

    function attachTreeListeners() {
      treeRoot.querySelectorAll('.tree-node-content').forEach(content => {
        content.addEventListener('click', (e) => {
          const toggle = e.target.closest('.tree-toggle');
          const node = content.closest('.tree-node');
          const children = node.querySelector(':scope > .tree-children');

          if (toggle && !toggle.classList.contains('leaf') && children) {
            // Toggle expand/collapse
            toggle.classList.toggle('expanded');
            children.classList.toggle('collapsed');
          } else if (selectable) {
            // Select node
            if (selectedNode) {
              selectedNode.classList.remove('selected');
            }
            content.classList.add('selected');
            selectedNode = content;

            const nodeId = content.dataset.nodeId;
            if (onSelectTool) {
              app.callTool(onSelectTool, { nodeId });
            }
            app.sendMessage('Selected: ' + nodeId);
          }
        });
      });
    }

    function escapeHtml(text) {
      const div = document.createElement('div');
      div.textContent = text;
      return div.innerHTML;
    }

    // Search filter
    let searchTimeout;
    searchInput.addEventListener('input', (e) => {
      clearTimeout(searchTimeout);
      searchTimeout = setTimeout(() => {
        if (treeData) {
          renderTree(treeData, e.target.value);
        }
      }, 200);
    });

    // Create app and set handler BEFORE connect
    const app = new App({ name: "Tree View", version: "1.0.0" });
    app.ontoolresult = (result) => {
      let data = result?.structuredContent;
      if (!data && result?.content) {
        const textContent = result.content.find(c => c.type === 'text');
        if (textContent) {
          try { data = JSON.parse(textContent.text); } catch (e) {
            treeRoot.innerHTML = '<div class="tree-empty">Error parsing tree data</div>';
            return;
          }
        }
      }
      if (data) {
        treeData = data;
        renderTree(treeData);
      }
    };
    await app.connect();
  </script>
SCRIPT

	_mcp_ui_html_footer
}

# --- Kanban Template ---

mcp_ui_template_kanban() {
	local config="$1"

	local title
	title="$("${MCPBASH_JSON_TOOL_BIN}" -r '.title // "Kanban Board"' <<<"${config}")"
	local columns_config
	columns_config="$("${MCPBASH_JSON_TOOL_BIN}" -c '.columns // [{"id":"todo","title":"To Do"},{"id":"in-progress","title":"In Progress"},{"id":"done","title":"Done"}]' <<<"${config}")"
	local draggable
	draggable="$("${MCPBASH_JSON_TOOL_BIN}" -r '.draggable // true' <<<"${config}")"
	local on_move_tool
	on_move_tool="$("${MCPBASH_JSON_TOOL_BIN}" -r '.onMoveTool // ""' <<<"${config}")"
	local on_card_click_tool
	on_card_click_tool="$("${MCPBASH_JSON_TOOL_BIN}" -r '.onCardClickTool // ""' <<<"${config}")"

	_mcp_ui_html_header "${title}"

	# Kanban-specific styles
	cat <<'KANBAN_STYLES'
  <style>
    .kanban-container {
      display: flex;
      gap: 16px;
      overflow-x: auto;
      padding-bottom: 16px;
      min-height: 400px;
    }

    .kanban-column {
      flex: 0 0 280px;
      background: var(--color-background-secondary, #f8f8f8);
      border-radius: var(--border-radius-lg, 8px);
      display: flex;
      flex-direction: column;
      max-height: calc(100vh - 200px);
    }

    .kanban-column-header {
      padding: 12px 16px;
      font-weight: var(--font-weight-semibold, 600);
      font-size: var(--font-text-md-size, 14px);
      color: var(--color-text-primary, #1a1a1a);
      border-bottom: var(--border-width-regular, 1px) solid var(--color-border-secondary, #eee);
      display: flex;
      justify-content: space-between;
      align-items: center;
    }

    .kanban-column-count {
      background: var(--color-background-primary, #fff);
      padding: 2px 8px;
      border-radius: var(--border-radius-full, 9999px);
      font-size: var(--font-text-xs-size, 11px);
      color: var(--color-text-tertiary, #999);
    }

    .kanban-column-body {
      flex: 1;
      padding: 12px;
      overflow-y: auto;
      min-height: 100px;
    }

    .kanban-column-body.drag-over {
      background: var(--color-background-info, rgba(0, 102, 204, 0.05));
    }

    .kanban-card {
      background: var(--color-background-primary, #fff);
      border: var(--border-width-regular, 1px) solid var(--color-border-secondary, #eee);
      border-radius: var(--border-radius-md, 6px);
      padding: 12px;
      margin-bottom: 8px;
      cursor: pointer;
      transition: box-shadow 0.15s, transform 0.15s;
    }

    .kanban-card:hover {
      box-shadow: var(--shadow-sm, 0 1px 3px rgba(0,0,0,0.1));
    }

    .kanban-card.dragging {
      opacity: 0.5;
      transform: rotate(2deg);
    }

    .kanban-card-title {
      font-weight: var(--font-weight-medium, 500);
      font-size: var(--font-text-sm-size, 13px);
      color: var(--color-text-primary, #1a1a1a);
      margin-bottom: 8px;
    }

    .kanban-card-description {
      font-size: var(--font-text-xs-size, 12px);
      color: var(--color-text-secondary, #666);
      line-height: 1.4;
      margin-bottom: 8px;
    }

    .kanban-card-meta {
      display: flex;
      justify-content: space-between;
      align-items: center;
      font-size: var(--font-text-xs-size, 11px);
      color: var(--color-text-tertiary, #999);
    }

    .kanban-card-tags {
      display: flex;
      gap: 4px;
      flex-wrap: wrap;
    }

    .kanban-tag {
      padding: 2px 6px;
      border-radius: var(--border-radius-sm, 4px);
      font-size: 10px;
      background: var(--color-background-secondary, #f0f0f0);
    }

    .kanban-tag.priority-high { background: var(--color-background-danger, #fef2f2); color: var(--color-text-danger, #dc2626); }
    .kanban-tag.priority-medium { background: var(--color-background-warning, #fefce8); color: var(--color-text-warning, #ca8a04); }
    .kanban-tag.priority-low { background: var(--color-background-success, #dcfce7); color: var(--color-text-success, #16a34a); }

    .kanban-empty {
      text-align: center;
      padding: 20px;
      color: var(--color-text-tertiary, #999);
      font-size: var(--font-text-sm-size, 12px);
    }

    .kanban-loading {
      display: flex;
      justify-content: center;
      padding: 40px;
    }
  </style>
KANBAN_STYLES

	printf '  <h2>%s</h2>\n' "$(_mcp_ui_escape_html "${title}")"

	printf '  <div id="kanbanBoard" class="kanban-container">\n'
	printf '    <div class="kanban-loading"><span class="spinner"></span></div>\n'
	printf '  </div>\n'

	# JavaScript for kanban board
	cat <<SCRIPT
  <script type="module">
    import { App } from 'https://cdn.jsdelivr.net/npm/@modelcontextprotocol/ext-apps/+esm';

    const kanbanBoard = document.getElementById('kanbanBoard');
    const columnsConfig = ${columns_config};
    const draggable = ${draggable};
    const onMoveTool = '${on_move_tool}';
    const onCardClickTool = '${on_card_click_tool}';

    let cardsData = [];
    let draggedCard = null;
    let app = null;

    function escapeHtml(text) {
      const div = document.createElement('div');
      div.textContent = text;
      return div.innerHTML;
    }

    function renderCard(card) {
      const tags = card.tags || [];
      const priority = card.priority || '';

      let tagsHtml = '';
      if (priority) {
        tagsHtml += '<span class="kanban-tag priority-' + priority.toLowerCase() + '">' + escapeHtml(priority) + '</span>';
      }
      tags.forEach(tag => {
        tagsHtml += '<span class="kanban-tag">' + escapeHtml(tag) + '</span>';
      });

      return '<div class="kanban-card" data-card-id="' + escapeHtml(card.id) + '" draggable="' + draggable + '">' +
        '<div class="kanban-card-title">' + escapeHtml(card.title) + '</div>' +
        (card.description ? '<div class="kanban-card-description">' + escapeHtml(card.description) + '</div>' : '') +
        '<div class="kanban-card-meta">' +
          '<div class="kanban-card-tags">' + tagsHtml + '</div>' +
          (card.assignee ? '<span>' + escapeHtml(card.assignee) + '</span>' : '') +
        '</div>' +
      '</div>';
    }

    function renderBoard(cards) {
      cardsData = cards || [];

      let html = '';
      columnsConfig.forEach(col => {
        const columnCards = cardsData.filter(c => c.column === col.id || c.status === col.id);
        html += '<div class="kanban-column" data-column-id="' + escapeHtml(col.id) + '">';
        html += '<div class="kanban-column-header">';
        html += '<span>' + escapeHtml(col.title) + '</span>';
        html += '<span class="kanban-column-count">' + columnCards.length + '</span>';
        html += '</div>';
        html += '<div class="kanban-column-body">';

        if (columnCards.length === 0) {
          html += '<div class="kanban-empty">No cards</div>';
        } else {
          columnCards.forEach(card => {
            html += renderCard(card);
          });
        }

        html += '</div></div>';
      });

      kanbanBoard.innerHTML = html;
      attachCardListeners();
    }

    function attachCardListeners() {
      // Card click
      kanbanBoard.querySelectorAll('.kanban-card').forEach(card => {
        card.addEventListener('click', () => {
          const cardId = card.dataset.cardId;
          if (onCardClickTool) {
            app.callTool(onCardClickTool, { cardId });
          }
          app.sendMessage('Card clicked: ' + cardId);
        });

        // Drag events
        if (draggable) {
          card.addEventListener('dragstart', (e) => {
            draggedCard = card;
            card.classList.add('dragging');
            e.dataTransfer.setData('text/plain', card.dataset.cardId);
          });

          card.addEventListener('dragend', () => {
            card.classList.remove('dragging');
            draggedCard = null;
            kanbanBoard.querySelectorAll('.drag-over').forEach(el => el.classList.remove('drag-over'));
          });
        }
      });

      // Column drop zones
      if (draggable) {
        kanbanBoard.querySelectorAll('.kanban-column-body').forEach(body => {
          body.addEventListener('dragover', (e) => {
            e.preventDefault();
            body.classList.add('drag-over');
          });

          body.addEventListener('dragleave', () => {
            body.classList.remove('drag-over');
          });

          body.addEventListener('drop', (e) => {
            e.preventDefault();
            body.classList.remove('drag-over');

            if (draggedCard) {
              const cardId = draggedCard.dataset.cardId;
              const newColumn = body.closest('.kanban-column').dataset.columnId;
              const oldColumn = cardsData.find(c => c.id === cardId)?.column || cardsData.find(c => c.id === cardId)?.status;

              if (oldColumn !== newColumn) {
                // Update local data
                const card = cardsData.find(c => c.id === cardId);
                if (card) {
                  card.column = newColumn;
                  card.status = newColumn;
                }

                // Notify server
                if (onMoveTool) {
                  app.callTool(onMoveTool, { cardId, fromColumn: oldColumn, toColumn: newColumn });
                }
                app.sendMessage('Moved card ' + cardId + ' to ' + newColumn);

                // Re-render
                renderBoard(cardsData);
              }
            }
          });
        });
      }
    }

    // Initial empty board render
    renderBoard([]);

    // Create app and set handler BEFORE connect
    app = new App({ name: "Kanban", version: "1.0.0" });
    app.ontoolresult = (result) => {
      // Per MCP Apps spec, prefer structuredContent
      let data = result?.structuredContent;
      if (!data && result?.content) {
        const textContent = result.content.find(c => c.type === 'text');
        if (textContent) {
          try {
            data = JSON.parse(textContent.text);
          } catch (e) {
            kanbanBoard.innerHTML = '<div class="kanban-empty">Error parsing kanban data</div>';
            return;
          }
        }
      }
      if (data) {
        renderBoard(Array.isArray(data) ? data : data.cards || []);
      }
    };

    // Connect to host
    await app.connect();
  </script>
SCRIPT

	_mcp_ui_html_footer
}
