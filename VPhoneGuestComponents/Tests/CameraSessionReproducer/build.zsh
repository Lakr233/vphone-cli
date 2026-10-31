#!/bin/zsh
set -euo pipefail
cd "${0:a:h}"
output=${1:?Pass an absolute output directory}
app="$output/Payload/SessionProbe.app"
mkdir -p "$app"
sdk=$(xcrun --sdk iphoneos --show-sdk-path)
xcrun --sdk iphoneos clang -fobjc-arc -O1 -target arm64-apple-ios26.0 \
  -isysroot "$sdk" -c CameraSessionProbe.m -o "$output/CameraSessionProbe.o"
xcrun --sdk iphoneos swiftc -O -target arm64-apple-ios26.0 -sdk "$sdk" \
  -parse-as-library -import-objc-header Bridge.h Probe.swift "$output/CameraSessionProbe.o" \
  -framework AVFoundation -o "$app/SessionProbe"
cp Info.plist "$app/"
codesign --force --sign - "$app"
ditto -c -k --keepParent "$output/Payload" "$output/SessionProbe.ipa"
