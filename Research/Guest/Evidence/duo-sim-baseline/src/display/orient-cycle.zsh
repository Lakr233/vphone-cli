#!/bin/zsh
# orient-cycle.zsh <seq-prefix> <posture-verb> <posture-label-P> <posture-label-after>
#   With MobileSafari in the foreground: posture swap to <verb> with -deviceOrientation=portrait,
#   landscapeLeft, landscapeRight (the swap tool's option names), capturing after each; then a
#   reset swap to portrait. Safari's own UIDevice/scene orientation is recorded too.
set -euo pipefail
here=${0:a:h}; root=${here:h:h}
U=28D2B766-8C33-40F0-99D3-56571D6FF08A
pfx=$1 verb=$2 lp=$3 la=$4
pgrep -f "MobileSafari" >/dev/null && $root/tools/sim.zsh pid $U MobileSafari >/dev/null 2>&1 || { xcrun simctl launch $U com.apple.mobilesafari >/dev/null; sleep 5 }
$here/gen-probe.zsh safari >/dev/null
cap() {
  local seq=$1; shift
  $here/capture.zsh $seq "$@" 2>&1 | grep -v '^probe.zsh'
  $root/tools/probe.zsh $U MobileSafari $root/probes/display-safari.lldb $here/states/$seq-safari.txt 2>/dev/null
  print -- "$seq safari: $(grep '^{"' $here/states/$seq-safari.txt | /opt/homebrew/bin/jq -c '[.orientation, (.records[] | select(.api=="UIDevice.orientation") | .value), (.records[] | select(.api=="UIApplication.connectedScenes.summary") | .value[] | [.screenName, .interfaceOrientation, .coordinateSpaceBounds.width, .coordinateSpaceBounds.height])]')"
}
cap $pfx-P "$lp+safari" portrait $verb -deviceOrientation=portrait
cap $pfx-LL "$la+safari" landscapeLeft $verb -deviceOrientation=landscapeLeft
cap $pfx-LR "$la+safari" landscapeRight $verb -deviceOrientation=landscapeRight
POSTURE_OUT=$here/posture $root/tools/posture.zsh $U $verb -deviceOrientation=portrait >/dev/null 2>&1 || true
