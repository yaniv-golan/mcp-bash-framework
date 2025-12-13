#!/usr/bin/env bash
set -euo pipefail

# Defaults (XDG Base Directory compliant)
INSTALL_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/mcp-bash"
BIN_DIR="${HOME}/.local/bin"
REPO_URL="${MCPBASH_INSTALL_REPO_URL:-https://github.com/yaniv-golan/mcp-bash-framework.git}"
BRANCH="main"
VERIFY_SHA256=""
ARCHIVE_SOURCE=""

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
	--version | --ref)
		if [ -z "${2:-}" ]; then
			error "--version/--ref requires a tag or commit"
			exit 1
		fi
		BRANCH="$2"
		shift 2
		;;
	--yes | -y)
		YES=true
		shift
		;;
	--verify)
		if [ -z "${2:-}" ]; then
			error "--verify requires a SHA256 checksum value"
			exit 1
		fi
		VERIFY_SHA256="$2"
		shift 2
		;;
	--archive)
		if [ -z "${2:-}" ]; then
			error "--archive requires a local path or URL"
			exit 1
		fi
		ARCHIVE_SOURCE="$2"
		shift 2
		;;
	--help)
		cat <<EOF
mcp-bash installer

Usage: install.sh [OPTIONS]

Options:
  --dir DIR      Install location (default: ~/.local/share/mcp-bash)
  --branch NAME  Git branch to install (default: main)
  --version TAG  Alias for --branch TAG (install a tagged release)
  --ref REF      Alias for --branch REF (install any ref/tag/commit)
  --archive SRC  Install from a local tar.gz path or URL (implies archive install)
  --verify SHA   Verify downloaded archive against expected SHA256 (forces archive install)
  --yes, -y      Non-interactive mode (overwrite without prompting)
                 Auto-enabled when stdin is not a TTY (e.g., curl | bash)
  --help         Show this help

Examples:
  # Preferred: download tarball + SHA256SUMS, verify, then install from local archive
  version=vX.Y.Z
  curl -fsSLO "https://github.com/yaniv-golan/mcp-bash-framework/releases/download/\${version}/mcp-bash-\${version}.tar.gz"
  curl -fsSLO "https://github.com/yaniv-golan/mcp-bash-framework/releases/download/\${version}/SHA256SUMS"
  sha256sum -c SHA256SUMS && bash install.sh --archive "mcp-bash-\${version}.tar.gz" --version "\${version}"

  # Fallback (less safe): curl -fsSL .../install.sh | bash -s -- --yes
  # CI-friendly fallback: curl -fsSL .../install.sh | bash -s -- --yes --version v0.4.0  # auto-prefixes v

Note: Installs to ~/.local/share/mcp-bash with a symlink in ~/.local/bin (XDG compliant)
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

# Normalize tag/ref: accept both v0.4.0 and 0.4.0 by prefixing v when missing.
case "${BRANCH}" in
[0-9]*.[0-9]*.[0-9]*)
	BRANCH="v${BRANCH}"
	;;
esac

printf '\n%s\n' "${BLUE}mcp-bash Installer${NC}"
printf '==================\n\n'

# Canonicalize INSTALL_DIR to prevent path traversal bypasses (e.g., "$HOME/..")
# Note: On systems without resolvers, path protection is weaker (string compare only).
SCRIPT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]-$0}")" && pwd)"
if [ -f "${SCRIPT_ROOT}/lib/path.sh" ]; then
	# shellcheck source=lib/path.sh disable=SC1090,SC1091
	. "${SCRIPT_ROOT}/lib/path.sh"
fi

if command -v mcp_path_normalize >/dev/null 2>&1; then
	INSTALL_DIR="$(mcp_path_normalize --physical "${INSTALL_DIR}")"
elif command -v realpath >/dev/null 2>&1 && realpath -m / >/dev/null 2>&1; then
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

# Determine install strategy (git clone vs verified archive)
install_via_archive=false
if [ -n "${ARCHIVE_SOURCE}" ] || [ -n "${VERIFY_SHA256}" ]; then
	install_via_archive=true
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

	# Prefer git clone for clean worktrees to avoid copying a live .git directory
	# that may be repacked concurrently. Fallback to tar (excluding .git) to
	# preserve uncommitted changes and untracked files.
	use_clone=0
	if command -v git >/dev/null 2>&1 && git -C "${LOCAL_SRC}" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
		git -C "${LOCAL_SRC}" update-index -q --really-refresh >/dev/null 2>&1 || true
		dirty_status="$(git -C "${LOCAL_SRC}" status --porcelain 2>/dev/null || true)"
		if [ -z "${dirty_status}" ]; then
			if git clone --local --no-hardlinks --branch "${BRANCH}" "${LOCAL_SRC}" "${INSTALL_DIR}" 2>/dev/null; then
				use_clone=1
				success "Cloned clean local source"
			fi
		fi
	fi

	if [ "${use_clone}" -ne 1 ]; then
		if ! command -v tar >/dev/null 2>&1; then
			error "tar is required to copy local source when repository is dirty"
			exit 1
		fi
		if (cd "${LOCAL_SRC}" && tar -cf - --exclude .git .) | (cd "${INSTALL_DIR}" && tar -xf -); then
			success "Copied local source (working tree, .git excluded)"
		else
			error "Failed to copy from local source"
			exit 1
		fi
	fi
else
	if [ "${install_via_archive}" = "true" ]; then
		if ! command -v tar >/dev/null 2>&1; then
			error "tar is required to extract archive installs"
			exit 1
		fi
		archive_url=""
		archive_path=""
		cleanup_archive=0

		if [ -n "${ARCHIVE_SOURCE}" ]; then
			case "${ARCHIVE_SOURCE}" in
			http://* | https://* | file://*)
				archive_url="${ARCHIVE_SOURCE}"
				;;
			*)
				archive_path="${ARCHIVE_SOURCE}"
				;;
			esac
		else
			archive_url="${MCPBASH_INSTALL_ARCHIVE_URL:-}"
			if [ -z "${archive_url}" ]; then
				# Prefer the release-published tarball for tagged installs so that
				# --verify can use the SHA256SUMS release asset generated from the
				# exact tarball being installed.
				case "${BRANCH}" in
				v*.*.*)
					archive_url="https://github.com/yaniv-golan/mcp-bash-framework/releases/download/${BRANCH}/mcp-bash-${BRANCH}.tar.gz"
					;;
				*)
					archive_url="https://github.com/yaniv-golan/mcp-bash-framework/archive/refs/heads/${BRANCH}.tar.gz"
					;;
				esac
			fi
		fi

		if [ -n "${archive_url}" ]; then
			if ! command -v curl >/dev/null 2>&1; then
				error "curl is required for archive download"
				exit 1
			fi
			tmp_archive="$(mktemp "${TMPDIR:-/tmp}/mcpbash.install.XXXXXX.tar.gz")"
			if [ -z "${tmp_archive}" ]; then
				error "Failed to allocate temp archive path"
				exit 1
			fi
			cleanup_archive=1
			archive_path="${tmp_archive}"
			info "Downloading archive..."
			if ! curl -fsSL "${archive_url}" -o "${archive_path}"; then
				rm -f "${archive_path}" || true
				error "Failed to download archive: ${archive_url}"
				exit 1
			fi
		fi

		if [ -z "${archive_path}" ] || [ ! -f "${archive_path}" ]; then
			error "Archive not found: ${archive_path:-<empty>}"
			exit 1
		fi

		# Verify checksum (optional).
		# - If --verify is provided, verification is mandatory (fail closed).
		# - For tagged installs (vX.Y.Z), attempt to verify against SHA256SUMS when
		#   available, but do not block first-time DX if verification tooling/files
		#   are missing (warn and continue).
		sha_tool=""
		if command -v sha256sum >/dev/null 2>&1; then
			sha_tool="sha256sum"
		elif command -v shasum >/dev/null 2>&1; then
			sha_tool="shasum"
		fi

		compute_sha256() {
			local path="$1"
			if [ -z "${sha_tool}" ]; then
				return 1
			fi
			if [ "${sha_tool}" = "sha256sum" ]; then
				sha256sum "${path}" | awk '{print $1}'
			else
				shasum -a 256 "${path}" | awk '{print $1}'
			fi
		}

		if [ -n "${VERIFY_SHA256}" ]; then
			if [ -z "${sha_tool}" ]; then
				if [ "${cleanup_archive}" -eq 1 ]; then
					rm -f "${archive_path}" || true
				fi
				error "Neither sha256sum nor shasum is available for checksum verification"
				exit 1
			fi
			computed_sha="$(compute_sha256 "${archive_path}")"
			if [ "${computed_sha}" != "${VERIFY_SHA256}" ]; then
				if [ "${cleanup_archive}" -eq 1 ]; then
					rm -f "${archive_path}" || true
				fi
				error "Checksum mismatch! Expected ${VERIFY_SHA256}, got ${computed_sha}"
				exit 1
			fi
			success "Archive checksum verified (--verify)"
		else
			case "${BRANCH}" in
			v*.*.*)
				# Best-effort verification using SHA256SUMS for tagged installs.
				if [ -z "${sha_tool}" ]; then
					warn "Checksum tool not available (sha256sum/shasum); skipping archive verification"
				else
					canonical_file="mcp-bash-${BRANCH}.tar.gz"
					sha_sums_path=""
					cleanup_sums=0

					# Prefer a colocated SHA256SUMS for local archives; for downloaded
					# archives, fetch SHA256SUMS from the same directory as the tarball.
					if [ -n "${archive_url}" ]; then
						sha_url="${archive_url%/*}/SHA256SUMS"
						tmp_sums="$(mktemp "${TMPDIR:-/tmp}/mcpbash.sums.XXXXXX")"
						cleanup_sums=1
						if command -v curl >/dev/null 2>&1 && curl -fsSL "${sha_url}" -o "${tmp_sums}"; then
							sha_sums_path="${tmp_sums}"
						else
							rm -f "${tmp_sums}" 2>/dev/null || true
							warn "Unable to download SHA256SUMS for ${BRANCH}; skipping archive verification"
						fi
					else
						local_dir="$(dirname "${archive_path}")"
						if [ -f "${local_dir}/SHA256SUMS" ]; then
							sha_sums_path="${local_dir}/SHA256SUMS"
						else
							warn "SHA256SUMS not found next to archive; skipping archive verification"
						fi
					fi

					if [ -n "${sha_sums_path}" ]; then
						expected_sha="$(awk -v f="${canonical_file}" '
							NF >= 2 {
								file=$2
								sub(/^\*/, "", file)
								if (file == f) { print $1; exit 0 }
							}
						' "${sha_sums_path}" 2>/dev/null || true)"
						if [ -z "${expected_sha}" ]; then
							# Do not proceed on an unexpected SHA256SUMS shape.
							if [ "${cleanup_sums}" -eq 1 ]; then
								rm -f "${sha_sums_path}" 2>/dev/null || true
							fi
							if [ "${cleanup_archive}" -eq 1 ]; then
								rm -f "${archive_path}" || true
							fi
							error "SHA256SUMS missing entry for ${canonical_file}"
							exit 1
						fi
						computed_sha="$(compute_sha256 "${archive_path}")"
						if [ "${computed_sha}" != "${expected_sha}" ]; then
							if [ "${cleanup_sums}" -eq 1 ]; then
								rm -f "${sha_sums_path}" 2>/dev/null || true
							fi
							if [ "${cleanup_archive}" -eq 1 ]; then
								rm -f "${archive_path}" || true
							fi
							error "Checksum mismatch! Expected ${expected_sha}, got ${computed_sha}"
							exit 1
						fi
						success "Archive checksum verified (SHA256SUMS)"
						if [ "${cleanup_sums}" -eq 1 ]; then
							rm -f "${sha_sums_path}" 2>/dev/null || true
						fi
					fi
				fi
				;;
			esac
		fi
		mkdir -p "${INSTALL_DIR}"
		# Extract archive, stripping the leading directory
		if ! tar -xzf "${archive_path}" -C "${INSTALL_DIR}" --strip-components 1; then
			if [ "${cleanup_archive}" -eq 1 ]; then
				rm -f "${archive_path}" || true
			fi
			error "Failed to extract archive"
			exit 1
		fi
		if [ "${cleanup_archive}" -eq 1 ]; then
			rm -f "${archive_path}" || true
		fi
		success "Installed from archive"
	else
		if git clone --depth 1 --branch "${BRANCH}" "${REPO_URL}" "${INSTALL_DIR}" 2>/dev/null; then
			success "Cloned from GitHub"
		else
			error "Failed to clone repository"
			exit 1
		fi
	fi
fi

# Create symlink in ~/.local/bin (XDG standard location)
info "Creating symlink..."
mkdir -p "${BIN_DIR}"
ln -sf "${INSTALL_DIR}/bin/mcp-bash" "${BIN_DIR}/mcp-bash"
success "Symlinked ${BIN_DIR}/mcp-bash → ${INSTALL_DIR}/bin/mcp-bash"

# Configure PATH for ~/.local/bin if needed
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

PATH_LINE='export PATH="$HOME/.local/bin:$PATH"'
PATH_NEEDED=false

# Check if ~/.local/bin is already in PATH
if [[ ":${PATH}:" != *":${BIN_DIR}:"* ]] && [[ ":${PATH}:" != *":${HOME}/.local/bin:"* ]]; then
	PATH_NEEDED=true
fi

if [ "${PATH_NEEDED}" = "true" ]; then
	if [ -n "${RC_FILE}" ]; then
		success "Detected shell: ${SHELL_NAME}"
		# Check for existing ~/.local/bin PATH entry
		if grep -qE '(^|:)\$HOME/\.local/bin(:|$)|~/.local/bin' "${RC_FILE}" 2>/dev/null; then
			info "\$HOME/.local/bin already in ${RC_FILE} (will take effect in new shells)"
		else
			printf '\n# Add ~/.local/bin to PATH (XDG standard)\n%s\n' "${PATH_LINE}" >>"${RC_FILE}"
			success "Added ~/.local/bin to PATH in ${RC_FILE}"
		fi
	else
		warn "Add this to your shell config manually:"
		printf "  %s\n" "${PATH_LINE}"
	fi
else
	success "\$HOME/.local/bin already in PATH"
fi

# Verify installation
printf "\n"
info "Verifying installation..."
export PATH="${BIN_DIR}:${PATH}"

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

if [ "${PATH_NEEDED}" = "true" ] && [ -n "${RC_FILE}" ]; then
	printf 'To start using mcp-bash, run:\n'
	printf '  %s%s%s\n\n' "${BLUE}" "source ${RC_FILE}" "${NC}"
	printf 'Or open a new terminal.\n\n'
fi

printf 'Quick start:\n\n'
printf '  %s%s%s\n' "${BLUE}" 'mcp-bash new my-server && cd my-server' "${NC}"
printf '  %s%s%s\n\n' "${BLUE}" 'mcp-bash run-tool hello' "${NC}"
printf 'Test with MCP Inspector:\n\n'
printf '  %s%s%s\n' "${BLUE}" 'npx @modelcontextprotocol/inspector --transport stdio -- mcp-bash' "${NC}"
