#!/usr/bin/env bash
# Verified local file reads for resource providers (Bash 3.2+).
#
# mcp_file_read_verified closes the check-then-open race that a plain
# "[ -L path ] / open / [ -L path ]" sequence leaves open. The caller passes the
# absolute, canonical path it has already checked and, optionally, the
# canonical root the path was checked against. The helper then:
#   1. changes into the parent directory. From here on the directory is pinned
#      by inode: swapping it, or any directory above it, for a symlink no longer
#      changes where the file is opened;
#   2. if a root was given, walks up from the pinned directory with ".." (the
#      directory's real parent, not a name lookup) and requires the ancestor at
#      the expected depth to be the root (same device and inode). This proves
#      the pinned directory is inside the root even if a parent directory was
#      swapped for a symlink before step 1;
#   3. lstats the final component (no symlink following) and requires a
#      regular file;
#   4. opens it on fd 9;
#   5. stats the open descriptor through /dev/fd/9 and requires a regular file
#      with the same device and inode as step 3. macOS reports the devfs device
#      for anything stat'd through /dev/fd/N, so there the file's birth time
#      (nanoseconds), which writes and links do not change, stands in for the
#      device;
#   6. streams the content from fd 9, so the bytes returned are the bytes of
#      the file that was checked.
# A symlink swapped in at any point before the open is refused; a swap after
# the open has no effect on what is read. If the descriptor cannot be identified
# (no usable stat, no /dev/fd), the read is refused rather than done unchecked.
#
# getcwd() is deliberately not used: on macOS it can spin indefinitely while a
# directory above the working directory is being renamed.
#
# Not covered: a hard link to an outside file placed inside the root is a
# regular file inside the root (Linux blocks this for files the attacker does
# not own when fs.protected_hardlinks=1; macOS does not).
#
# Return codes:
#   0 content written to stdout
#   2 refused: not a regular file, a symlink, outside the root, or the file
#     changed between the check and the open
#   3 not found or could not be opened
#   4 larger than MAX_BYTES (nothing written)
#   5 the opened descriptor could not be identified on this platform (refused)

# mcp_file_read_identity MODE PATH
# MODE is "lstat" (do not follow a final symlink) or "fd" (follow, for /dev/fd/N).
# Prints "dev|ino|birth|size|type" with type normalized to "regular", "dir" or
# "other". birth is the birth time with nanoseconds where stat reports it (BSD
# %B, GNU %w), otherwise "-" (GNU) or a placeholder (BusyBox); it is only used
# on macOS. Returns 1 if no supported stat is available.
mcp_file_read_identity() {
	local mode="$1"
	local target="$2"
	local out=""
	# GNU coreutils and BusyBox use -c; BSD/macOS uses -f. Try GNU first: on
	# GNU, -f means --file-system and the BSD format would fail as a filename.
	if [ "${mode}" = "fd" ]; then
		out="$(stat -L -c '%d|%i|%w|%s|%F' "${target}" 2>/dev/null)" \
			|| out="$(stat -L -f '%d|%i|%.9FB|%z|%HT' "${target}" 2>/dev/null)" \
			|| out=""
	else
		out="$(stat -c '%d|%i|%w|%s|%F' "${target}" 2>/dev/null)" \
			|| out="$(stat -f '%d|%i|%.9FB|%z|%HT' "${target}" 2>/dev/null)" \
			|| out=""
	fi
	[ -n "${out}" ] || return 1
	local type="${out##*|}"
	case "${type}" in
	[Rr]egular*) type="regular" ;;
	[Dd]irectory) type="dir" ;;
	*) type="other" ;;
	esac
	printf '%s|%s' "${out%|*}" "${type}"
}

# mcp_file_read_canonical_path PATH
# Prints PATH with its parent directory resolved physically and the final
# component kept as is, so a symlink final component is still seen (and
# refused) by mcp_file_read_verified. Returns 1 if the parent does not resolve.
mcp_file_read_canonical_path() {
	local path="$1"
	local dir="${path%/*}"
	local base="${path##*/}"
	if [ "${dir}" = "${path}" ]; then
		dir="."
	fi
	[ -n "${dir}" ] || dir="/"
	local physical=""
	if command -v realpath >/dev/null 2>&1; then
		physical="$(realpath "${dir}" 2>/dev/null || true)"
	fi
	if [ -z "${physical}" ]; then
		physical="$(cd -P "${dir}" 2>/dev/null && pwd -P)" || return 1
	fi
	[ -n "${physical}" ] || return 1
	if [ "${physical}" = "/" ]; then
		printf '/%s' "${base}"
	else
		printf '%s/%s' "${physical}" "${base}"
	fi
}

# mcp_file_read_verified PATH [MAX_BYTES] [ROOT]
# PATH must be absolute and canonical and must be the exact path the caller
# validated. ROOT, if given, must be canonical and contain PATH's parent
# directory; the pinned directory is then checked to really be inside it. See
# the header for the checks and return codes.
mcp_file_read_verified() {
	local path="$1"
	local max_bytes="${2:-}"
	local root="${3:-}"
	case "${path}" in
	/*) ;;
	*) return 2 ;;
	esac
	local dir="${path%/*}"
	local base="${path##*/}"
	[ -n "${dir}" ] || dir="/"
	case "${base}" in
	"" | . | ..) return 3 ;;
	esac
	case "${max_bytes}" in
	"" | *[!0-9]*) max_bytes="" ;;
	esac

	# Relative path from the parent directory up to ROOT ("." when they are
	# the same directory, "./.." one level below, and so on).
	local up=""
	if [ -n "${root}" ] && [ "${root}" != "/" ]; then
		root="${root%/}"
		local rel=""
		if [ "${dir}" = "${root}" ]; then
			rel=""
		elif [ "${dir:0:$((${#root} + 1))}" = "${root}/" ]; then
			rel="${dir:$((${#root} + 1))}"
		else
			return 2
		fi
		up="."
		while [ -n "${rel}" ]; do
			up="${up}/.."
			case "${rel}" in
			*/*) rel="${rel#*/}" ;;
			*) rel="" ;;
			esac
		done
	fi

	# Subshell: the cd and fd 9 stay local to this call.
	(
		cd -P "${dir}" 2>/dev/null || exit 3

		if [ -n "${up}" ]; then
			root_id="$(mcp_file_read_identity lstat "${root}")" || exit 5
			anc_id="$(mcp_file_read_identity lstat "${up}")" || exit 2
			IFS='|' read -r root_dev root_ino _ _ root_type <<<"${root_id}"
			IFS='|' read -r anc_dev anc_ino _ _ anc_type <<<"${anc_id}"
			if [ "${root_type}" != "dir" ] || [ "${anc_type}" != "dir" ] \
				|| [ "${root_dev}" != "${anc_dev}" ] || [ "${root_ino}" != "${anc_ino}" ]; then
				exit 2
			fi
		fi

		if [ ! -e "./${base}" ] && [ ! -L "./${base}" ]; then
			exit 3
		fi
		checked="$(mcp_file_read_identity lstat "./${base}")" || exit 5
		case "${checked}" in
		*"|regular") ;;
		*) exit 2 ;;
		esac

		exec 9<"./${base}" || exit 3

		opened="$(mcp_file_read_identity fd /dev/fd/9)" || {
			exec 9<&-
			exit 5
		}
		case "${opened}" in
		*"|regular") ;;
		*)
			exec 9<&-
			exit 2
			;;
		esac

		# Fields: dev|ino|birth|size|type
		IFS='|' read -r checked_dev checked_ino checked_birth _ _ <<<"${checked}"
		IFS='|' read -r opened_dev opened_ino opened_birth size _ <<<"${opened}"
		if [ "${checked_ino}" != "${opened_ino}" ]; then
			exec 9<&-
			exit 2
		fi
		if [ "${checked_dev}" != "${opened_dev}" ]; then
			# Only acceptable where /dev/fd/N reports the devfs device (macOS).
			# There the birth time stands in for the device.
			devfs_dev="$(stat -c '%d' /dev/null 2>/dev/null || stat -f '%d' /dev/null 2>/dev/null || true)"
			if [ -z "${devfs_dev}" ] || [ "${opened_dev}" != "${devfs_dev}" ] \
				|| [ "${checked_birth}" = "${checked_birth#*[0-9]}" ] \
				|| [ "${checked_birth}" != "${opened_birth}" ]; then
				exec 9<&-
				exit 2
			fi
		fi

		if [ -n "${max_bytes}" ]; then
			case "${size}" in
			"" | *[!0-9]*)
				exec 9<&-
				exit 5
				;;
			esac
			if [ "${size}" -gt "${max_bytes}" ]; then
				exec 9<&-
				exit 4
			fi
			# Bound the output too, in case the file grows after the check.
			head -c "${max_bytes}" <&9
		else
			cat <&9
		fi
		exec 9<&-
	)
}
