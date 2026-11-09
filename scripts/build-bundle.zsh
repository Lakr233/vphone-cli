#!/bin/zsh
set -euo pipefail

# Builds the VPhone scheme (AGENTS.md Quick Reference) into <repo>/.build/XcodeBundle and prints the bundle path.
# The build log goes to .build/build-bundle.log; on failure the last error lines are printed and the exit is 1.
# A rebuild that changes vphone-vm's cdhash needs: sudo <bundle>/Contents/MacOS/vphone-escalator allow <bundle>/Contents/MacOS/vphone-vm

root=${0:a:h:h}
log=$root/.build/build-bundle.log
mkdir -p "$root/.build"
cd "$root"
if ! xcodebuild -workspace VPhone.xcworkspace -scheme VPhone -configuration Debug \
        -destination 'platform=macOS,arch=arm64' -derivedDataPath .build/XcodeBundle build > "$log" 2>&1; then
  grep -E 'error:' "$log" | sort -u | head -20 >&2
  print -u2 "build failed; see $log"
  exit 1
fi
print -r -- "$root/.build/XcodeBundle/Build/Products/Debug/VPhone.bundle"
