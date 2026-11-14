#!/bin/zsh
# Install the optional SOCKS5 service for a running NAT guest, or remove it.
set -euo pipefail
export PATH=/usr/bin:/bin:/usr/sbin:/sbin
umask 077
action=install
case ${1:-} in
  --enable|--disable|--uninstall) action=${1#--}; shift ;;
esac
[[ $# == 1 ]] || { print -u2 "Usage: ${0:t} [--enable|--disable|--uninstall] /path/to/machine"; exit 64; }
machine=${1:A}
[[ -d "$machine" ]] || { print -u2 "Machine directory not found."; exit 1; }
addon_dir=${0:A:h}
identifier=$(printf '%s' "$machine" | shasum -a 256 | cut -c1-32)
label="com.vphone.socks5.$identifier"
domain="gui/$(id -u)"
agent_dir="$HOME/Library/LaunchAgents"
agent="$agent_dir/$label.plist"
support="$HOME/Library/Application Support/vphone-socks5/$identifier"
guest_dir=/private/var/db/vphone-socks5
target="$domain/$label"
if [[ $action != install ]]; then
  [[ -f "$agent" && $(plutil -extract Label raw -o - "$agent") == "$label" ]] || { print -u2 "The SOCKS5 add-on is not installed for this machine."; exit 1; }
fi
case $action in
  enable)
    launchctl enable "$target"
    if ! launchctl print "$target" >/dev/null 2>&1; then
      launchctl bootstrap "$domain" "$agent" || { launchctl disable "$target"; exit 1; }
    fi
    exit 0 ;;
  disable)
    launchctl disable "$target"
    if launchctl print "$target" >/dev/null 2>&1; then
      launchctl bootout "$target" || { launchctl enable "$target"; exit 1; }
    fi
    exit 0 ;;
esac
# jq encodes paths as data, including any quotes or newlines.
send_request() {
  jq -cn "$@" | nc -w 30 -U vphone.sock |
    jq -es 'if length == 1 and .[0].ok == true then true else error(.[0].error // "No guest reply") end' >/dev/null
}
if [[ $action == uninstall ]]; then
  cd "$machine"
  [[ -S vphone.sock ]] || { print -u2 "Start this VM to remove the add-on and its guest files."; exit 1; }
  if launchctl print "$target" >/dev/null 2>&1; then launchctl bootout "$target"; fi
  remove_guest_path() {
    send_request --arg path "$1" '{t:"rpc", method:"files.remove", params:{$path}, screen:false}'
  }
  for name in hev-socks5-server proxy.yml NOTICE; do remove_guest_path "$guest_dir/$name"; done
  # Leave a directory with any user-added files intact.
  remove_guest_path "$guest_dir" || print -u2 "Kept the guest directory $guest_dir."
  rm -f -- "$agent" "$support/serve.zsh"
  if [[ -d "$support" ]]; then rmdir "$support" || print -u2 "Kept the host directory $support."; fi
  print 'Removed the SOCKS5 add-on.'
  exit 0
fi

cd "$machine"
[[ -f config.plist && -S vphone.sock ]] || { print -u2 "Start this VM first."; exit 1; }
[[ $(plutil -extract networkConfig.mode raw -o - config.plist) == nat ]] || { print -u2 "This add-on is for NAT guests."; exit 1; }
working=$(mktemp -d -t vphone-socks5-build)
trap 'rm -rf -- "$working"' EXIT
version=2.13.1
archive="$working/source.tar.xz"
curl --fail --location --retry 2 --output "$archive" "https://github.com/heiher/hev-socks5-server/releases/download/$version/hev-socks5-server-$version.tar.xz"
expected=aecff4c35d7ffa6458ff55512b04d00c1d102ddc3fbee466534a9b1876022da4
[[ $(shasum -a 256 "$archive" | cut -d ' ' -f 1) == "$expected" ]] || { print -u2 "Unexpected HEV source archive checksum."; exit 1; }
tar -xJf "$archive" -C "$working"
source_dir="$working/hev-socks5-server-$version"
make -C "$source_dir" -j4 CC='xcrun --sdk iphoneos clang' PP='xcrun --sdk iphoneos clang' \
  AR='xcrun --sdk iphoneos ar' STRIP='xcrun --sdk iphoneos strip' \
  CFLAGS='-arch arm64 -miphoneos-version-min=15.0' LFLAGS='-arch arm64 -miphoneos-version-min=15.0' exec
server="$source_dir/bin/hev-socks5-server"
codesign --force --sign - --timestamp=none "$server"
codesign --verify --strict "$server"
for notice in LICENSE src/core/LICENSE third-part/yaml/License third-part/hev-task-system/LICENSE; do
  print -r -- "$notice"
  cat "$source_dir/$notice"
  print
done > "$working/NOTICE"

send_request --arg path "$guest_dir" '{t:"rpc", method:"files.mkdir", params:{$path}, screen:false}'
push() {
  send_request --arg local "$1" --arg path "$guest_dir/$2" --argjson mode "$3" \
    '{t:"push", $local, $path, $mode, screen:false}'
}
push "$server" hev-socks5-server 493
push "$working/NOTICE" NOTICE 420

mkdir -p "$support" "$agent_dir"
worker_tmp=$(mktemp "$support/serve.XXXXXX")
install -m 0700 "$addon_dir/serve.zsh" "$worker_tmp"
mv -f "$worker_tmp" "$support/serve.zsh"
agent_tmp=$(mktemp "$agent_dir/$label.XXXXXX")
jq -n --arg label "$label" --arg machine "$machine" --arg worker "$support/serve.zsh" '{
  Label: $label, ProgramArguments: [$worker], WorkingDirectory: $machine,
  Disabled: true, KeepAlive: {PathState: {($machine + "/vphone.sock"): true}},
  ThrottleInterval: 10, ProcessType: "Background"
}' | plutil -convert xml1 -o "$agent_tmp" -
# Keep a live session and its open connections on update. For a fresh install,
# reset any old override before publishing the plist to the login domain.
if [[ ! -f "$agent" ]]; then
  launchctl disable "$target"
  message="Installed SOCKS5 for ${machine:t}. It is off."
else
  message="Updated SOCKS5 for ${machine:t}, keeping its current setting."
fi
mv -f "$agent_tmp" "$agent"
print -r -- "$message"
