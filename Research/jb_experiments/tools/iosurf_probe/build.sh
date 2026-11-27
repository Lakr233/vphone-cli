#!/bin/bash
# build + ad-hoc-style manual sign with the wqprobe dev profile (no account in CLI xcodebuild)
set -e
cd "$(dirname "$0")"
SDK=$(xcrun --sdk iphoneos --show-sdk-path)
APP=iosurf.app
rm -rf "$APP"; mkdir -p "$APP"
xcrun --sdk iphoneos clang -arch arm64 -mios-version-min=17.0 -isysroot "$SDK" -fobjc-arc -framework UIKit -framework Foundation -framework IOKit -o "$APP/iosurf" main.m
cp Info.plist "$APP/"
PP="$HOME/Library/Developer/Xcode/UserData/Provisioning Profiles/46268155-a22f-4171-8ec4-dc3aa63070f8.mobileprovision"
cp "$PP" "$APP/embedded.mobileprovision"
codesign -f -s "Apple Development: Ilya Strelov (SK48H7Y4X4)" --entitlements ent.plist --timestamp=none "$APP"
codesign -dvv "$APP" 2>&1 | grep -E "Identifier|TeamIdentifier|Authority" | head -3
