#!/usr/bin/env bash
set -euo pipefail

# Clear com.apple.quarantine on the framework or a project path.
# Usage: scripts/macos-dequarantine.sh [path]

if [ "$(uname -s 2>/dev/null || printf '')" != "Darwin" ]; then
	printf 'This helper is macOS-only (Darwin required).\n' >&2
	exit 1
fi

if ! command -v xattr >/dev/null 2>&1; then
	printf 'xattr not found. Install Xcode Command Line Tools: xcode-select --install\n' >&2
	exit 1
fi

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
default_target="$(cd "${script_dir}/.." && pwd)"
target="${1:-${default_target}}"

if [ ! -e "${target}" ]; then
	printf 'Target does not exist: %s\n' "${target}" >&2
	exit 1
fi

printf 'Clearing com.apple.quarantine from: %s\n' "${target}"
if [ -d "${target}" ]; then
	if ! xattr -r -d com.apple.quarantine "${target}" 2>/dev/null; then
		xattr -cr "${target}"
	fi
else
	if ! xattr -d com.apple.quarantine "${target}" 2>/dev/null; then
		xattr -c "${target}"
	fi
fi
printf 'Done. Restart Claude Desktop if it was running.\n'
