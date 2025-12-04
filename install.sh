#!/usr/bin/env bash
set -euo pipefail

# Defaults
INSTALL_DIR="${HOME}/mcp-bash-framework"
REPO_URL="${MCPBASH_INSTALL_REPO_URL:-https://github.com/yaniv-golan/mcp-bash-framework.git}"
BRANCH="main"

# Colors (if terminal supports)
if [ -t 1 ]; then
	RED='\033[0;31m'
	GREEN='\033[0;32m'
	YELLOW='\033[0;33m'
	BLUE='\033[0;34m'
	NC='\033[0m'
else
	RED='' GREEN='' YELLOW='' BLUE='' NC=''
fi

info() { printf "${BLUE}%s${NC}\n" "$1"; }
success() { printf "${GREEN}✓${NC} %s\n" "$1"; }
warn() { printf "${YELLOW}⚠${NC} %s\n" "$1"; }
error() { printf "${RED}✗${NC} %s\n" "$1" >&2; }

# Parse arguments
YES=false
while [ $# -gt 0 ]; do
	case "$1" in
	--dir)
		if [ -z "${2:-}" ]; then
			error "--dir requires a directory path"
			exit 1
		fi
		INSTALL_DIR="$2"
		shift 2
		;;
	--branch)
		if [ -z "${2:-}" ]; then
			error "--branch requires a branch name"
			exit 1
		fi
		BRANCH="$2"
		shift 2
		;;
	--yes | -y)
		YES=true
		shift
		;;
	--help)
		cat <<EOF
mcp-bash installer

Usage: install.sh [OPTIONS]

Options:
  --dir DIR      Install location (default: ~/mcp-bash-framework)
  --branch NAME  Git branch to install (default: main)
  --yes, -y      Non-interactive mode (overwrite without prompting)
                 Auto-enabled when stdin is not a TTY (e.g., curl | bash)
  --help         Show this help

Examples:
  curl -fsSL .../install.sh | bash
  curl -fsSL .../install.sh | bash -s -- --dir ~/.local/mcp-bash
  curl -fsSL .../install.sh | bash -s -- --yes  # CI-friendly
EOF
		exit 0
		;;
	*)
		error "Unknown option: $1"
		exit 1
		;;
	esac
done

# Auto-enable non-interactive mode when stdin is not a TTY (e.g., piped in CI)
if [ ! -t 0 ]; then
	YES=true
fi

printf '\n%s\n' "${BLUE}mcp-bash Installer${NC}"
printf '==================\n\n'

# Canonicalize INSTALL_DIR to prevent path traversal bypasses (e.g., "$HOME/..")
# Note: On systems without realpath -m or readlink -f, path protection is weaker
# (relies on literal string comparison only).
if command -v realpath >/dev/null 2>&1 && realpath -m / >/dev/null 2>&1; then
	# realpath -m works even if path doesn't exist yet
	INSTALL_DIR="$(realpath -m "${INSTALL_DIR}" 2>/dev/null || printf '%s' "${INSTALL_DIR}")"
elif command -v readlink >/dev/null 2>&1 && readlink -f / >/dev/null 2>&1; then
	INSTALL_DIR="$(readlink -f "${INSTALL_DIR}" 2>/dev/null || printf '%s' "${INSTALL_DIR}")"
fi

# Safety check: refuse dangerous install directories (checked AFTER canonicalization)
case "${INSTALL_DIR}" in
/ | "" | "${HOME}" | /usr | /usr/local | /bin | /sbin | /etc | /var | /tmp)
	error "Refusing to install to dangerous path: ${INSTALL_DIR}"
	error "Please specify a safe directory with --dir"
	exit 1
	;;
esac

# Detect OS
OS="$(uname -s)"
ARCH="$(uname -m)"
info "Detecting system... ${OS} (${ARCH})"
info "Install location: ${INSTALL_DIR}"
printf "\n"

# Check for git
if ! command -v git >/dev/null 2>&1; then
	error "git is required but not installed"
	exit 1
fi

# Check for existing installation
# WARNING: This will DELETE the entire install directory if user confirms!
# The install directory should only contain the framework, never user projects.
if [ -d "${INSTALL_DIR}" ]; then
	# Safety check: only delete if it looks like a prior mcp-bash install
	if [ ! -f "${INSTALL_DIR}/bin/mcp-bash" ]; then
		error "Directory ${INSTALL_DIR} exists but doesn't look like an mcp-bash installation"
		error "(missing bin/mcp-bash). Refusing to delete. Remove manually or use a different --dir."
		exit 1
	fi
	warn "Directory ${INSTALL_DIR} already exists (prior mcp-bash installation)"
	warn "Re-installing will DELETE this directory and all its contents!"
	if [ "${YES}" = "true" ]; then
		# Note: curl | bash runs non-interactively and will reach here automatically
		info "Overwriting (--yes mode or non-TTY stdin)"
	else
		read -p "Overwrite? [y/N] " -n 1 -r
		printf "\n"
		if [[ ! $REPLY =~ ^[Yy]$ ]]; then
			info "Installation cancelled"
			exit 0
		fi
	fi
	rm -rf "${INSTALL_DIR}"
fi

# Clone or copy repository
info "Downloading mcp-bash framework..."
if [ -n "${MCPBASH_INSTALL_LOCAL_SOURCE:-}" ]; then
	LOCAL_SRC="${MCPBASH_INSTALL_LOCAL_SOURCE}"
	if [ ! -d "${LOCAL_SRC}" ]; then
		error "Local source directory not found: ${LOCAL_SRC}"
		exit 1
	fi
	if [ ! -f "${LOCAL_SRC}/bin/mcp-bash" ]; then
		error "Local source ${LOCAL_SRC} does not look like an mcp-bash checkout (missing bin/mcp-bash)"
		exit 1
	fi
	mkdir -p "${INSTALL_DIR}"
	if cp -a "${LOCAL_SRC}/." "${INSTALL_DIR}/"; then
		success "Copied from local source"
	else
		error "Failed to copy from local source"
		exit 1
	fi
else
	if git clone --depth 1 --branch "${BRANCH}" "${REPO_URL}" "${INSTALL_DIR}" 2>/dev/null; then
		success "Cloned from GitHub"
	else
		error "Failed to clone repository"
		exit 1
	fi
fi

# Detect shell and configure PATH
info "Configuring shell..."
SHELL_NAME="$(basename "${SHELL}")"
case "${SHELL_NAME}" in
zsh)
	RC_FILE="${HOME}/.zshrc"
	;;
bash)
	# On Windows/Git Bash, prefer .bashrc (created by Git for Windows)
	# On macOS, .bash_profile is more common for login shells
	# On Linux, .bashrc is standard
	if [ -f "${HOME}/.bashrc" ]; then
		RC_FILE="${HOME}/.bashrc"
	elif [ -f "${HOME}/.bash_profile" ]; then
		RC_FILE="${HOME}/.bash_profile"
	else
		# Create .bashrc as default
		RC_FILE="${HOME}/.bashrc"
	fi
	;;
*)
	RC_FILE=""
	warn "Unknown shell: ${SHELL_NAME}"
	warn "Note: PowerShell is not supported; use Git Bash on Windows"
	;;
esac

PATH_LINE="export PATH=\"${INSTALL_DIR}/bin:\$PATH\""

if [ -n "${RC_FILE}" ]; then
	success "Detected shell: ${SHELL_NAME}"
	# Check for existing PATH entry using the actual install dir (not hardcoded name)
	if grep -qF "${INSTALL_DIR}/bin" "${RC_FILE}" 2>/dev/null; then
		warn "PATH already configured in ${RC_FILE}"
	else
		printf '\n# mcp-bash framework\n%s\n' "${PATH_LINE}" >>"${RC_FILE}"
		success "Added to ${RC_FILE}"
	fi
else
	warn "Add this to your shell config manually:"
	printf "  %s\n" "${PATH_LINE}"
fi

# Verify installation
printf "\n"
info "Verifying installation..."
export PATH="${INSTALL_DIR}/bin:${PATH}"

if "${INSTALL_DIR}/bin/mcp-bash" --version >/dev/null 2>&1; then
	VERSION="$("${INSTALL_DIR}/bin/mcp-bash" --version | awk '{print $2}')"
	success "mcp-bash --version: ${VERSION}"
else
	error "mcp-bash failed to run"
	exit 1
fi

# Check for jq
if command -v jq >/dev/null 2>&1; then
	success "jq found: $(command -v jq)"
elif command -v gojq >/dev/null 2>&1; then
	success "gojq found: $(command -v gojq)"
else
	warn "jq not found (install with: brew install jq  OR  apt install jq)"
fi

# Success message
printf '\n%s\n\n' "${GREEN}Installation complete!${NC}"

if [ -n "${RC_FILE}" ]; then
	printf 'To start using mcp-bash, run:\n'
	printf '  %s%s%s\n\n' "${BLUE}" "source ${RC_FILE}" "${NC}"
	printf 'Or open a new terminal.\n\n'
fi

printf 'Quick start:\n'
printf '  %s%s%s\n' "${BLUE}" 'mkdir my-server && cd my-server' "${NC}"
printf '  %s%s%s\n' "${BLUE}" 'mcp-bash init --name my-server' "${NC}"
printf '  %s%s%s\n' "${BLUE}" 'npx @modelcontextprotocol/inspector --transport stdio -- mcp-bash' "${NC}"
