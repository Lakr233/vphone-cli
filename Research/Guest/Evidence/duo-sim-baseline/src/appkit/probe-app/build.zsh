#!/bin/zsh
# build.zsh [out-dir] — builds and ad hoc signs VPAppKitProbe.app for the iOS 27.1 simulator.
set -euo pipefail
here=${0:a:h}
out=${1:-$here/build}
app=$out/VPAppKitProbe.app
rm -rf $app; mkdir -p $app
xcrun --sdk iphonesimulator clang -arch arm64 -mios-simulator-version-min=27.1 -fobjc-arc -fmodules \
  -Wall -Wno-deprecated-declarations -framework UIKit -o $app/VPAppKitProbe $here/main.m
cp $here/Info.plist $app/Info.plist
codesign -s - -f $app >/dev/null 2>&1
print -- $app
