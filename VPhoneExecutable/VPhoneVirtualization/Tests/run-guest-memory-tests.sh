#!/bin/zsh
# vphone-tier: build
set -euo pipefail

# The guest memory sources import VPhoneCoreKit for VPhoneHostFilePermissions
# alone; a one-file module of that name stands in for the real one.
root="$(cd "${0:a:h}/../../.." && pwd)"
sources="$root/VPhoneExecutable/VPhoneVirtualization/UI/VirtualMachine"
out="$root/.build/guest-memory-tests"
mkdir -p "$out/stub"
cat > "$out/stub/VPhoneCoreKit.swift" <<'STUB'
import Foundation

public enum VPhoneHostFilePermissions {
    public static func makeAccessible(at _: URL) throws {}
}
STUB
xcrun --sdk macosx swiftc -swift-version 6 -parse-as-library \
    -target arm64-apple-macos15.0 -module-cache-path "$out/module-cache" \
    -emit-module -emit-library -static -module-name VPhoneCoreKit \
    -emit-module-path "$out/stub/VPhoneCoreKit.swiftmodule" -o "$out/stub/libVPhoneCoreKit.a" \
    "$out/stub/VPhoneCoreKit.swift"
xcrun --sdk macosx swiftc -swift-version 6 -parse-as-library \
    -target arm64-apple-macos15.0 -module-cache-path "$out/module-cache" \
    -I "$out/stub" -L "$out/stub" -lVPhoneCoreKit \
    "$sources/VPhoneMemoryDump.swift" \
    "$sources/GuestMemory/VPhoneGuestPhysicalMemory.swift" \
    "$sources/GuestMemory/VPhoneGuestPhysicalMemory+VirtualMachine.swift" \
    "$sources/GuestMemory/VPhoneGuestKernel.swift" \
    "$sources/GuestMemory/VPhoneKernelSymbols.swift" \
    "$sources/GuestMemory/VPhoneGuestMemoryDumps.swift" \
    "${0:a:h}/GuestMemoryTests.swift" -o "$out/GuestMemoryTests"
"$out/GuestMemoryTests" "$out/scratch" \
    "$root/VPhoneExecutable/VPhoneVirtualization/Resources/kernelcache_recipes"
