#!/bin/zsh
# Simulator helpers for the iPhone Duo baseline harness.
#
#   sim.zsh create [name]                 create an iPhone Duo / iOS 27.1 sim, print its UDID
#   sim.zsh clone <src> <new-name>        clone a (shut down) sim, print the new UDID
#   sim.zsh boot <name|udid>              boot and wait for boot to finish
#   sim.zsh shutdown <name|udid>          shut down
#   sim.zsh udid <name|udid>              resolve a device name to its UDID
#   sim.zsh pid <name|udid> <process>     pid of a process inside that sim (SpringBoard,
#                                         backboardd, MobileSafari, Preferences, ...)
#   sim.zsh ps <name|udid>                list the sim's processes (pid name)
#   sim.zsh runtime-root                  the mounted iOS 27.1 RuntimeRoot (needs a booted 27.1 sim)
#   sim.zsh shared-cache                  the sim dyld shared cache path
#   sim.zsh shot <name|udid> <out-dir> <tag>
#                                         screenshot display 1 (cover) and 3 (inner) to
#                                         <out-dir>/<tag>-d1.png and <tag>-d3.png
#   sim.zsh lit <png>                     print "lit <mean>" or "dark <mean>" for a screenshot
#
# The two pre-existing "iPhone Duo" devices are protected: boot, shutdown, erase and delete
# refuse them. Nothing here deletes a device.
set -euo pipefail

SIM_DEVICE_TYPE="com.apple.CoreSimulator.SimDeviceType.iPhone-Duo"
SIM_RUNTIME="com.apple.CoreSimulator.SimRuntime.iOS-27-1"
SIM_PROTECTED=(B738069B-DF72-4050-A9D8-333E16B0D664 4D48BBE9-DFC0-41C4-AC6A-86B60A88E629)

sim_die() { print -u2 -- "sim.zsh: $*"; exit 1 }

sim_udid() {
  local arg=$1
  if [[ $arg =~ '^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$' ]]; then
    print -- ${arg:u}; return
  fi
  local matches
  matches=$(xcrun simctl list devices -j | /opt/homebrew/bin/jq -r --arg n "$arg" \
    '.devices[] | .[] | select(.name == $n) | .udid')
  [[ -n $matches ]] || sim_die "no simulator named '$arg'"
  (( $(print -- $matches | wc -l) == 1 )) || sim_die "more than one simulator named '$arg': $matches"
  print -- $matches
}

sim_guard() {
  local udid=$1
  (( ${SIM_PROTECTED[(Ie)$udid]} == 0 )) || sim_die "refusing to touch protected device $udid"
}

# launchd_sim of a booted device is started with its device data path on the command line.
sim_launchd_pid() {
  local udid=$1
  ps -A -o pid=,command= | awk -v u="Devices/$udid/data/var/run/launchd_bootstrap.plist" \
    'index($0, "launchd_sim") && index($0, u) && !p { p = $1 } END { if (p) print p }'
}

sim_ps() {
  local udid=$1 lpid
  lpid=$(sim_launchd_pid $udid)
  [[ -n $lpid ]] || sim_die "$udid is not booted (no launchd_sim)"
  # Every sim process is a child of that launchd_sim. comm is the full executable path.
  ps -A -o pid=,ppid=,comm= | awk -v p=$lpid '$2 == p { n = $3; for (i = 4; i <= NF; i++) n = n " " $i; sub(".*/", "", n); print $1, n }'
}

sim_pid() {
  local udid=$1 name=$2 pid
  pid=$(sim_ps $udid | awk -v n="$name" '$2 == n { print $1 }' | tail -1)
  [[ -n $pid ]] || sim_die "no process '$name' in $udid"
  print -- $pid
}

sim_runtime_root() {
  local root
  root=( /private/var/run/com.apple.security.cryptexd/mnt/com.apple.iPhoneOS.SimulatorRuntime-v24.1.94425.0.*/Library/Developer/CoreSimulator/Profiles/Runtimes/iOS\ 27.1.simruntime/Contents/Resources/RuntimeRoot(N/) )
  (( ${#root} > 0 )) || sim_die "iOS 27.1 runtime is not mounted; boot a 27.1 simulator first"
  print -- ${root[1]}
}

# A panel that is not driven captures as pure black (every channel 0). Downscale to 32x32,
# then take the mean and the max of R,G,B. Lit means some pixel rises clearly above black:
# a freshly booted cover with its wallpaper not yet drawn still shows icons (max > 24).
sim_lit() {
  local png=$1 dir tmp off stats
  dir=$(mktemp -d -t simlit); tmp=$dir/x.bmp
  sips -z 32 32 -s format bmp "$png" --out "$tmp" >/dev/null
  off=$(od -An -tu4 -j 10 -N 4 "$tmp" | tr -d ' ')
  stats=$(od -An -v -tu1 -j $off "$tmp" | awk '{ for (i = 1; i <= NF; i++) { c++; if (c % 4 != 0) { s += $i; n++; if ($i > m) m = $i } } } END { printf "mean=%.2f max=%d", (n ? s / n : 0), m }')
  rm -rf "$dir"
  if (( ${${stats##*max=}%% *} > 24 )); then print -- "lit $stats"; else print -- "dark $stats"; fi
}

cmd=${1:-}; shift || true
case $cmd in
  create)
    name=${1:-duo-baseline-harness}
    xcrun simctl create "$name" $SIM_DEVICE_TYPE $SIM_RUNTIME ;;
  clone)
    (( $# == 2 )) || sim_die "usage: clone <src> <new-name>"
    src=$(sim_udid $1); xcrun simctl clone $src "$2" ;;
  boot)
    udid=$(sim_udid ${1:?device}); sim_guard $udid
    xcrun simctl boot $udid 2>/dev/null || true
    xcrun simctl bootstatus $udid -b >/dev/null
    print -- $udid ;;
  shutdown)
    udid=$(sim_udid ${1:?device}); sim_guard $udid
    xcrun simctl shutdown $udid ;;
  erase|delete)
    sim_die "$cmd is deliberately not provided" ;;
  udid) sim_udid ${1:?device} ;;
  ps) sim_ps $(sim_udid ${1:?device}) ;;
  pid) sim_pid $(sim_udid ${1:?device}) ${2:?process} ;;
  runtime-root) sim_runtime_root ;;
  shared-cache) print -- "$(sim_runtime_root)/System/Library/Caches/com.apple.dyld/dyld_sim_shared_cache_arm64" ;;
  shot)
    (( $# == 3 )) || sim_die "usage: shot <device> <out-dir> <tag>"
    udid=$(sim_udid $1); mkdir -p "$2"
    xcrun simctl io $udid screenshot --display=1 "$2/$3-d1.png" >/dev/null 2>&1
    xcrun simctl io $udid screenshot --display=3 "$2/$3-d3.png" >/dev/null 2>&1
    print -- "$2/$3-d1.png $(sim_lit "$2/$3-d1.png")"
    print -- "$2/$3-d3.png $(sim_lit "$2/$3-d3.png")" ;;
  lit) sim_lit ${1:?png} ;;
  *) sed -n '2,22p' ${0:a} | sed 's/^# \{0,1\}//'; exit 2 ;;
esac
