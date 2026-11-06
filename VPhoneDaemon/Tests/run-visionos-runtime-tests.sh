#!/bin/zsh
set -euo pipefail
root="$(cd "${0:a:h}/.." && pwd)"
out="$(mktemp -d)"
trap 'rm -rf "$out"' EXIT
xcrun swiftc "$root/Daemon/GuestRuntimePlatform.swift" "$root/Tests/VisionOSRuntimeTests.swift" -o "$out/tests"
"$out/tests"
