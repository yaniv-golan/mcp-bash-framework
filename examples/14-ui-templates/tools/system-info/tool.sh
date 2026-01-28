#!/usr/bin/env bash
set -euo pipefail

# Source SDK
# shellcheck disable=SC1091
source "${MCP_SDK:?MCP_SDK environment variable not set}/tool-sdk.sh"

# Get CPU load average (1-minute)
get_cpu_load() {
	if command -v uptime >/dev/null 2>&1; then
		# Handle both "load average:" (Linux) and "load averages:" (macOS)
		uptime | sed 's/.*load average[s]*: *//' | awk -F'[ ,]+' '{print $1}'
	else
		echo "N/A"
	fi
}

# Get memory usage (cross-platform)
get_memory_info() {
	if [[ "$(uname)" == "Darwin" ]]; then
		# macOS
		local page_size
		page_size=$(pagesize 2>/dev/null || echo 4096)
		local vm_stat_output
		vm_stat_output=$(vm_stat 2>/dev/null || echo "")

		if [ -n "${vm_stat_output}" ]; then
			local pages_active pages_wired pages_compressed
			pages_active=$(echo "${vm_stat_output}" | awk '/Pages active:/ {gsub(/\./,"",$3); print $3}')
			pages_wired=$(echo "${vm_stat_output}" | awk '/Pages wired down:/ {gsub(/\./,"",$4); print $4}')
			pages_compressed=$(echo "${vm_stat_output}" | awk '/Pages occupied by compressor:/ {gsub(/\./,"",$5); print $5}')

			local total_mem
			total_mem=$(sysctl -n hw.memsize 2>/dev/null || echo 0)
			total_mem=$((total_mem / 1024 / 1024)) # Convert to MB

			local used_pages=$((${pages_active:-0} + ${pages_wired:-0} + ${pages_compressed:-0}))
			local used_mem=$((used_pages * page_size / 1024 / 1024))
			local pct_used=$((used_mem * 100 / total_mem))

			echo "${used_mem}|${total_mem}|${pct_used}"
		else
			echo "0|0|0"
		fi
	else
		# Linux
		if command -v free >/dev/null 2>&1; then
			local mem_info
			mem_info=$(free -m | awk '/^Mem:/ {print $3"|"$2"|"int($3*100/$2)}')
			echo "${mem_info}"
		else
			echo "0|0|0"
		fi
	fi
}

# Get disk usage
get_disk_info() {
	if command -v df >/dev/null 2>&1; then
		# Get root partition info
		df -h / 2>/dev/null | awk 'NR==2 {
			gsub(/%/,"",$5)
			print $3"|"$2"|"$5
		}'
	else
		echo "0|0|0"
	fi
}

# Get system uptime in human readable format
get_uptime() {
	if command -v uptime >/dev/null 2>&1; then
		uptime | sed 's/.*up //' | sed 's/,.*//' | tr -d ' '
	else
		echo "N/A"
	fi
}

# Get hostname
get_hostname() {
	hostname 2>/dev/null || echo "unknown"
}

# Get OS info
get_os_info() {
	if [[ "$(uname)" == "Darwin" ]]; then
		sw_vers -productName 2>/dev/null | tr -d '\n'
		echo -n " "
		sw_vers -productVersion 2>/dev/null
	elif [ -f /etc/os-release ]; then
		grep PRETTY_NAME /etc/os-release | cut -d'"' -f2
	else
		uname -s
	fi
}

# Gather all system info
cpu_load=$(get_cpu_load)
memory_info=$(get_memory_info)
disk_info=$(get_disk_info)
uptime_str=$(get_uptime)
hostname_str=$(get_hostname)
os_info=$(get_os_info)

# Parse memory info
mem_used=$(echo "${memory_info}" | cut -d'|' -f1)
mem_total=$(echo "${memory_info}" | cut -d'|' -f2)
mem_pct=$(echo "${memory_info}" | cut -d'|' -f3)

# Parse disk info
disk_used=$(echo "${disk_info}" | cut -d'|' -f1)
disk_total=$(echo "${disk_info}" | cut -d'|' -f2)
disk_pct=$(echo "${disk_info}" | cut -d'|' -f3)

# Build result using mcp_json_obj
result=$(mcp_json_obj \
	hostname "${hostname_str}" \
	os "${os_info}" \
	uptime "${uptime_str}" \
	cpuLoad "${cpu_load}" \
	memoryUsedMB "${mem_used}" \
	memoryTotalMB "${mem_total}" \
	memoryPercent "${mem_pct}" \
	diskUsed "${disk_used}" \
	diskTotal "${disk_total}" \
	diskPercent "${disk_pct}")

mcp_result_success "${result}"
