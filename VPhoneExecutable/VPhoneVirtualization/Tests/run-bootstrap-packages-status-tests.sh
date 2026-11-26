#!/bin/zsh
# vphone-tier: build
set -euo pipefail
root="$(cd "${0:a:h}/../../.." && pwd)"
out="$root/.build/bootstrap-packages-status-tests"
mkdir -p "$out"
xcrun --sdk macosx swiftc -swift-version 6 -parse-as-library \
    -target arm64-apple-macos15.0 -module-cache-path "$out/module-cache" \
    "$root/VPhoneExecutable/VPhoneVirtualization/UI/GuestCommunication/VPhoneBootstrapPackagesStatus.swift" \
    "${0:a:h}/BootstrapPackagesStatusTests.swift" -o "$out/BootstrapPackagesStatusTests"
"$out/BootstrapPackagesStatusTests" "$@"
