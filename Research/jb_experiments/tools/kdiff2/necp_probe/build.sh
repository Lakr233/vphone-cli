#!/bin/bash
# build + ad-hoc-style manual sign with the wqprobe dev profile (no account in CLI xcodebuild)
set -e
cd "$(dirname "$0")"
SDK=$(xcrun --sdk iphoneos --show-sdk-path)
APP=necp_probe.app
rm -rf "$APP"; mkdir -p "$APP"
xcrun --sdk iphoneos clang -arch arm64 -mios-version-min=17.0 -isysroot "$SDK" -fobjc-arc -framework UIKit -framework Foundation -framework UIKit -o "$APP/necp_probe" main.m
cp Info.plist "$APP/"
PP="$HOME/Library/Developer/Xcode/UserData/Provisioning Profiles/660687d1-e008-48eb-95d4-739ef6b1f931.mobileprovision"
cp "$PP" "$APP/embedded.mobileprovision"
codesign -f -s "Apple Development: Ilya Strelov (SK48H7Y4X4)" --entitlements ent.plist --timestamp=none "$APP"
codesign -dvv "$APP" 2>&1 | grep -E "Identifier|TeamIdentifier|Authority" | head -3
