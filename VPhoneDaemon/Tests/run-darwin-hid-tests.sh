#!/bin/zsh
set -euo pipefail
root="$(cd "${0:a:h}/.." && pwd)"
out="$(mktemp -d)"
trap 'rm -rf "$out"' EXIT
xcrun --sdk macosx clang -fobjc-arc -fblocks -Wall -Wextra -Werror \
    "$root/Tests/DarwinHIDTests.m" -framework Foundation -o "$out/hid-tests"
"$out/hid-tests"
"$out/hid-tests" missing-symbols
