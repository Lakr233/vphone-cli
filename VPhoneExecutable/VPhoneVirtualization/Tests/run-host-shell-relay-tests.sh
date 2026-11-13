#!/bin/zsh
# vphone-tier: build
set -euo pipefail

root="$(cd "${0:a:h}/../../.." && pwd)"
out="$root/.build/host-shell-relay-tests"
mkdir -p "$out"
guest="$root/VPhoneExecutable/VPhoneVirtualization/UI/GuestCommunication"
xcrun --sdk macosx swiftc -swift-version 6 -parse-as-library \
    -target arm64-apple-macos15.0 -module-cache-path "$out/module-cache" \
    "$guest/VPhoneHostShellRelay.swift" \
    "${0:a:h}/HostShellRelayTests.swift" -o "$out/HostShellRelayTests"
"$out/HostShellRelayTests"
