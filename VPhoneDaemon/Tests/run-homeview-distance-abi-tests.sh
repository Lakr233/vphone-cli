#!/bin/zsh
set -euo pipefail
tests="${0:a:h}"
repo="${tests:h:h}"
out="$repo/.build/homeview-distance-abi-tests"
mkdir -p "$out"
xcrun --sdk macosx clang -fobjc-arc -fblocks -Wall -Wextra -Werror \
    "$tests/HomeViewDistanceABITests.m" -framework Foundation -o "$out/HomeViewDistanceABITests"
"$out/HomeViewDistanceABITests"
