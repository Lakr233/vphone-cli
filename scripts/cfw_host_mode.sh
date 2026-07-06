# cfw_host_mode.sh — sourced by cfw_install*.sh when CFW_HOST_MODE=1.
#
# Replaces the SSH-to-ramdisk transport with local operations on the image
# volumes mounted on the host (by the host driver). The rest of each
# installer's logic (cfw.py patching, ldid signing, ipsw/aea cryptex decrypt,
# hdiutil DMG mounts, xcrun builds, DSC/DT patchers) is already host-side and
# runs unchanged. Must run as root. The boot-source flip the ramdisk did with
# `snaputil` is done separately, offline, by tools/apfs_snap_rename.py.
#
# The host root (/) is read-only (SSV), so device paths /mnt1,/mnt3,/mnt5 are
# remapped onto a writable scratch base (CFW_HOST_MNT). Only those exact
# device tokens are remapped, so host source paths (e.g. .../mnt_sysos) are
# left untouched.
: "${CFW_HOST_CONTAINER:?CFW_HOST_MODE=1 but CFW_HOST_CONTAINER (host apfs container disk, e.g. disk20) unset}"
CFW_HOST_MNT="${CFW_HOST_MNT:-/private/tmp/cfwhost}"
/bin/mkdir -p "$CFW_HOST_MNT"
_HOST_TAR="$(command -v gtar 2>/dev/null || echo /opt/homebrew/bin/gtar)"

_map() {   # remap device /mntN tokens -> $CFW_HOST_MNT/mntN
    local s="$1"
    s="${s//\/mnt1/$CFW_HOST_MNT/mnt1}"
    s="${s//\/mnt2/$CFW_HOST_MNT/mnt2}"
    s="${s//\/mnt3/$CFW_HOST_MNT/mnt3}"
    s="${s//\/mnt5/$CFW_HOST_MNT/mnt5}"
    printf '%s' "$s"
}

ssh_cmd() {
    local c="$*"
    case "$c" in
        *snaputil*)                                        return 0 ;;  # flip done offline
        *dropbearkey*)                                     return 0 ;;  # host keys made at first boot
        *dropbear_rsa_host_key*|*dropbear_ecdsa_host_key*) return 0 ;;  # skip chmod of keys not created
        */sbin/halt*)                                      return 0 ;;  # no VM to halt
    esac
    c="${c//\/usr\/bin\/tar/$_HOST_TAR}"                                # macOS bsdtar lacks GNU flags
    /bin/sh -c "$(_map "$c")"
}
scp_to()   { /bin/cp -R "$(_map "$1")" "$(_map "$2")"; }
scp_from() { /bin/cp "$(_map "$1")" "$(_map "$2")"; }
remote_file_exists() { [[ -e "$(_map "$1")" ]]; }
remote_mount() {
    local dev="$1" mnt opts="${3:-rw}"
    mnt="$(_map "$2")"
    local slice="${dev##*disk1}"                     # /dev/disk1sN -> sN
    local hostdev="/dev/${CFW_HOST_CONTAINER}${slice}"
    /bin/mkdir -p "$mnt"
    /sbin/mount | /usr/bin/grep -q " on $mnt " && return 0
    /sbin/mount_apfs -o "$opts" "$hostdev" "$mnt" 2>/dev/null || true
    /sbin/mount | /usr/bin/grep -q " on $mnt " || die "host mount failed: $hostdev -> $mnt"
}
wait_for_device_ssh_ready() { :; }
