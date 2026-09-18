#!/bin/zsh
set -euo pipefail
source "${0:a:h:h}/scripts/cfw_install_safety.zsh"
root=$(cfw_new_mount_root)
other=$(mktemp -d /private/tmp/cfw-host-sentinel.XXXXXX)
trap 'rm -rf "$root" "$other"' EXIT
print -n sentinel > "$other/sentinel"
print -n payload > "$other/input"
mkdir "$other/staging"
# A positive assertion ensures a broken sandbox cannot make negative tests pass.
cfw_guest_write "$root" /bin/cp "$other/input" "$root/mnt1/valid"
[[ "$(cat "$root/mnt1/valid")" == payload ]]
for destination in "$other/sentinel" "$other/staging"; do
  ln -s "$destination" "$root/mnt1/escape"
  if cfw_guest_write "$root" /bin/cp "$other/input" "$root/mnt1/escape" 2>/dev/null; then
    print -u2 'guest write escaped its mounts'; exit 1
  fi
  rm "$root/mnt1/escape"
done
ln -s "$other" "$root/mnt1/ancestor"
if cfw_guest_write "$root" /bin/cp "$other/input" "$root/mnt1/ancestor/sentinel" 2>/dev/null; then
  print -u2 'ancestor symlink escaped'; exit 1
fi
if cfw_guest_write "$root" /bin/chmod 000 "$root/mnt1/ancestor/sentinel" 2>/dev/null; then
  print -u2 'metadata write escaped'; exit 1
fi
if cfw_guest_write "$root" /bin/ln -sf target "$root/mnt1/ancestor/new-link" 2>/dev/null; then
  print -u2 'symlink creation escaped'; exit 1
fi
if cfw_guest_write "$root" /bin/mkdir -p "$root/mnt1/ancestor/new-directory" 2>/dev/null; then
  print -u2 'directory creation escaped'; exit 1
fi
[[ ! -L "$other/new-link" && ! -e "$other/new-directory" ]]
[[ "$(cat "$other/sentinel")" == sentinel ]]
[[ ! -e "$other/staging/input" ]]
# Recursive copies must receive exactly the same boundary.
mkdir "$other/tree" "$root/mnt1/tree"
print -n payload > "$other/tree/file"
ln -s "$other/sentinel" "$root/mnt1/tree/file"
cfw_guest_write "$root" /bin/cp -R "$other/tree/." "$root/mnt1/tree" 2>/dev/null || true
[[ "$(cat "$other/sentinel")" == sentinel ]]
print 'cfw installer safety checks passed'
