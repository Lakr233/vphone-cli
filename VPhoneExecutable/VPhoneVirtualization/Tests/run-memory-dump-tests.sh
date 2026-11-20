#!/bin/zsh
# vphone-tier: build
set -euo pipefail

# VPhoneMemoryDump.swift imports VPhoneCoreKit for VPhoneHostFilePermissions
# alone; a one-file module of that name stands in for the real one.
root="$(cd "${0:a:h}/../../.." && pwd)"
out="$root/.build/memory-dump-tests"
mkdir -p "$out/stub"
cat > "$out/stub/VPhoneCoreKit.swift" <<'EOF'
import Foundation

public enum VPhoneHostFilePermissions {
    public static func makeAccessible(at _: URL) throws {}
}
EOF
xcrun --sdk macosx swiftc -swift-version 6 -parse-as-library \
    -target arm64-apple-macos15.0 -module-cache-path "$out/module-cache" \
    -emit-module -emit-library -static -module-name VPhoneCoreKit \
    -emit-module-path "$out/stub/VPhoneCoreKit.swiftmodule" -o "$out/stub/libVPhoneCoreKit.a" \
    "$out/stub/VPhoneCoreKit.swift"
xcrun --sdk macosx swiftc -swift-version 6 -parse-as-library \
    -target arm64-apple-macos15.0 -module-cache-path "$out/module-cache" \
    -I "$out/stub" -L "$out/stub" -lVPhoneCoreKit \
    "$root/VPhoneExecutable/VPhoneVirtualization/UI/VirtualMachine/VPhoneMemoryDump.swift" \
    "${0:a:h}/MemoryDumpTests.swift" -o "$out/MemoryDumpTests"
"$out/MemoryDumpTests" "$out/scratch"
