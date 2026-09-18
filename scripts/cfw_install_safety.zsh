#!/bin/zsh
# Every command that mutates mounted guest data must use guest_write. Host
# preparation stays outside this sandbox, so a guest symlink can never grant
# access to staging files, build tools, or other host destinations.

cfw_new_mount_root() {
  local root
  root=$(/usr/bin/mktemp -d /private/tmp/cfwhost.XXXXXX) || return 1
  /bin/chmod 0700 "$root" || return 1
  /bin/mkdir "$root/mnt1" "$root/mnt3" "$root/mnt5" || return 1
  print -r -- "$root"
}

cfw_guest_write() {
  local root=$1
  shift
  [[ -d "$root" && ! -L "$root" ]] || return 1
  local suffix
  for suffix in mnt1 mnt3 mnt5; do
    [[ -d "$root/$suffix" && ! -L "$root/$suffix" ]] || return 1
  done
  # Parameters, not interpolated Scheme strings, preserve arbitrary pathname
  # characters. The kernel checks resolved paths, including symlink targets.
  /usr/bin/sandbox-exec \
    -D "ROOT1=$root/mnt1" -D "ROOT3=$root/mnt3" -D "ROOT5=$root/mnt5" \
    -p '(version 1)
        (allow default)
        (deny file-write*)
        (allow file-write* (subpath (param "ROOT1"))
                           (subpath (param "ROOT3"))
                           (subpath (param "ROOT5"))
                           (literal "/dev/null"))
        (deny process-exec (subpath (param "ROOT1"))
                           (subpath (param "ROOT3"))
                           (subpath (param "ROOT5")))' \
    "$@"
}

guest_write() {
  : "${CFW_HOST_MNT:?run through cfw_install_host.sh}"
  cfw_guest_write "$CFW_HOST_MNT" "$@"
}

cfw_mount_volume() {
  local dev=$1 mnt=$2 opts=${3:-rw}
  [[ -d "$mnt" && ! -L "$mnt" ]] || return 1
  local mounted
  mounted=$(/sbin/mount)
  if print -r -- "$mounted" | /usr/bin/grep -Fq " on $mnt ("; then
    print -r -- "$mounted" | /usr/bin/grep -Fq "$dev on $mnt (" || {
      print -u2 -- "[-] unexpected device mounted at $mnt"
      return 1
    }
    return 0
  fi
  /sbin/mount_apfs -o "$opts" "$dev" "$mnt" || return 1
  /sbin/mount | /usr/bin/grep -Fq "$dev on $mnt ("
}
