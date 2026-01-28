#!/usr/bin/env bash
# UI template generation performance benchmarks
# Run: ./test/benchmark/test_ui_templates.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MCPBASH_HOME="${MCPBASH_HOME:-$(cd "${SCRIPT_DIR}/../.." && pwd)}"

# Source required libraries
# shellcheck source=lib/runtime.sh
# shellcheck disable=SC1091
. "${MCPBASH_HOME}/lib/runtime.sh"
# shellcheck source=lib/json.sh
# shellcheck disable=SC1091
. "${MCPBASH_HOME}/lib/json.sh"
# shellcheck source=lib/ui-templates.sh
# shellcheck disable=SC1091
. "${MCPBASH_HOME}/lib/ui-templates.sh"

MCPBASH_FORCE_MINIMAL=false
mcp_runtime_detect_json_tool

if [ "${MCPBASH_MODE}" = "minimal" ]; then
	echo "SKIP: JSON tooling unavailable, cannot run benchmarks"
	exit 0
fi

export MCPBASH_MODE MCPBASH_JSON_TOOL MCPBASH_JSON_TOOL_BIN

echo "=== UI Template Generation Benchmarks ==="
echo "JSON tool: ${MCPBASH_JSON_TOOL}"
echo ""

# Utility to measure execution time
benchmark() {
	local name="$1"
	local iterations="$2"
	shift 2

	local start end elapsed avg
	start=$(date +%s%N 2>/dev/null || date +%s)

	for ((i = 0; i < iterations; i++)); do
		"$@" >/dev/null 2>&1
	done

	end=$(date +%s%N 2>/dev/null || date +%s)

	# Handle systems without nanosecond precision
	if [ "${#start}" -gt 10 ]; then
		elapsed=$(((end - start) / 1000000))
		avg=$((elapsed / iterations))
		printf "  %-35s %5d iterations in %6d ms (%4d ms/iter)\n" "${name}" "${iterations}" "${elapsed}" "${avg}"
	else
		elapsed=$((end - start))
		avg=$((elapsed * 1000 / iterations))
		printf "  %-35s %5d iterations in %6d s  (%4d ms/iter est)\n" "${name}" "${iterations}" "${elapsed}" "${avg}"
	fi
}

# --- Benchmark 1: Form template generation ---
echo "1. Form Template Generation"

SIMPLE_FORM='{"title":"Simple Form","fields":[{"name":"x","type":"text"}],"submitTool":"test"}'
benchmark "Simple form (1 field)" 50 mcp_ui_template_form "${SIMPLE_FORM}"

MEDIUM_FORM='{"title":"Medium Form","fields":[
  {"name":"name","type":"text","label":"Name","required":true},
  {"name":"email","type":"email","label":"Email"},
  {"name":"age","type":"number","label":"Age"},
  {"name":"bio","type":"textarea","label":"Bio"},
  {"name":"role","type":"select","label":"Role","options":["admin","user","guest"]}
],"submitTool":"submit","cancelable":true}'
benchmark "Medium form (5 fields)" 50 mcp_ui_template_form "${MEDIUM_FORM}"

LARGE_FORM='{"title":"Large Form","fields":['
for i in {1..20}; do
	[ "$i" -gt 1 ] && LARGE_FORM+=','
	LARGE_FORM+='{"name":"field'$i'","type":"text","label":"Field '$i'"}'
done
LARGE_FORM+='],"submitTool":"submit"}'
benchmark "Large form (20 fields)" 20 mcp_ui_template_form "${LARGE_FORM}"

echo ""

# --- Benchmark 2: Data table template ---
echo "2. Data Table Template Generation"

SMALL_TABLE='{"title":"Small Table","columns":[{"key":"id","label":"ID"},{"key":"name","label":"Name"}]}'
benchmark "Small table (2 columns)" 50 mcp_ui_template_data_table "${SMALL_TABLE}"

LARGE_TABLE='{"title":"Large Table","columns":['
for i in {1..10}; do
	[ "$i" -gt 1 ] && LARGE_TABLE+=','
	LARGE_TABLE+='{"key":"col'$i'","label":"Column '$i'","sortable":true}'
done
LARGE_TABLE+=']}'
benchmark "Large table (10 columns)" 30 mcp_ui_template_data_table "${LARGE_TABLE}"

echo ""

# --- Benchmark 3: Progress template ---
echo "3. Progress Template Generation"

SIMPLE_PROGRESS='{"title":"Progress","showPercentage":true}'
benchmark "Simple progress" 50 mcp_ui_template_progress "${SIMPLE_PROGRESS}"

FULL_PROGRESS='{"title":"Full Progress","showPercentage":true,"showCurrentStep":true,"cancelTool":"cancel","cancelConfirm":"Cancel?"}'
benchmark "Full progress (with cancel)" 50 mcp_ui_template_progress "${FULL_PROGRESS}"

echo ""

# --- Benchmark 4: Diff viewer template ---
echo "4. Diff Viewer Template Generation"

SIMPLE_DIFF='{"title":"Diff","viewMode":"split"}'
benchmark "Simple diff viewer" 30 mcp_ui_template_diff_viewer "${SIMPLE_DIFF}"

FULL_DIFF='{"title":"Full Diff","viewMode":"unified","showLineNumbers":true,"syntaxHighlight":true,"leftTitle":"Before","rightTitle":"After"}'
benchmark "Full diff viewer" 30 mcp_ui_template_diff_viewer "${FULL_DIFF}"

echo ""

# --- Benchmark 5: Tree view template ---
echo "5. Tree View Template Generation"

SIMPLE_TREE='{"title":"Tree","showIcons":true,"expandLevel":1}'
benchmark "Simple tree view" 30 mcp_ui_template_tree_view "${SIMPLE_TREE}"

FULL_TREE='{"title":"Full Tree","showIcons":true,"expandLevel":3,"selectable":true,"onSelectTool":"select-node"}'
benchmark "Full tree view" 30 mcp_ui_template_tree_view "${FULL_TREE}"

echo ""

# --- Benchmark 6: Kanban template ---
echo "6. Kanban Template Generation"

SIMPLE_KANBAN='{"title":"Kanban"}'
benchmark "Simple kanban (default cols)" 30 mcp_ui_template_kanban "${SIMPLE_KANBAN}"

FULL_KANBAN='{"title":"Full Kanban","columns":[
  {"id":"backlog","title":"Backlog"},
  {"id":"todo","title":"To Do"},
  {"id":"in-progress","title":"In Progress"},
  {"id":"review","title":"Review"},
  {"id":"done","title":"Done"}
],"draggable":true,"onMoveTool":"move-card","onCardClickTool":"open-card"}'
benchmark "Full kanban (5 columns)" 30 mcp_ui_template_kanban "${FULL_KANBAN}"

echo ""

# --- Benchmark 7: Registry scaling ---
echo "7. UI Registry Scaling (resource discovery simulation)"

BENCH_TMPDIR="$(mktemp -d)"
trap 'rm -rf "${BENCH_TMPDIR}"' EXIT

# shellcheck source=lib/ui.sh
# shellcheck disable=SC1091
. "${MCPBASH_HOME}/lib/ui.sh"

# Create test UI resources
create_ui_resources() {
	local count="$1"
	local dir="${BENCH_TMPDIR}/ui-${count}"
	mkdir -p "${dir}/ui"

	for ((i = 1; i <= count; i++)); do
		mkdir -p "${dir}/ui/resource-${i}"
		echo '<!DOCTYPE html><html><body>Resource '${i}'</body></html>' >"${dir}/ui/resource-${i}/index.html"
		echo '{"description":"Resource '${i}'"}' >"${dir}/ui/resource-${i}/ui.meta.json"
	done

	echo "${dir}"
}

# Test with different resource counts
for count in 10 50 100; do
	ui_dir="$(create_ui_resources "${count}")"

	# Reset registry state
	MCP_UI_REGISTRY_JSON=""
	export MCP_UI_REGISTRY_HASH=""
	MCP_UI_TOTAL=0
	MCP_UI_LAST_SCAN=""
	MCPBASH_UI_DIR="${ui_dir}/ui"
	MCPBASH_TOOLS_DIR="${ui_dir}/tools"

	benchmark "Registry scan (${count} resources)" 5 mcp_ui_discover
done

echo ""
echo "=== Benchmark Complete ==="
