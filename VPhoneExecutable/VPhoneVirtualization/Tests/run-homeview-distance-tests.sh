#!/bin/zsh
set -euo pipefail

tests="${0:a:h}"
repo="${tests:h:h:h}"
out="$repo/.build/homeview-distance-tests"
mkdir -p "$out"
xcrun --sdk macosx swiftc -swift-version 6 -strict-concurrency=complete -parse-as-library \
    -module-cache-path "$out/module-cache" \
    "$tests:h/UI/UserInterface/Panels/Controls/VPhoneHomeViewDistanceModel.swift" \
    "$tests/HomeViewDistanceTests.swift" -o "$out/HomeViewDistanceTests"
"$out/HomeViewDistanceTests" "$@"
