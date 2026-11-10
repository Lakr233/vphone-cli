#!/bin/zsh
set -euo pipefail

daemon="${0:a:h:h}"
temporary="$(mktemp -d "${TMPDIR:-/tmp}/vphone-display-metrics-tests.XXXXXX")"
trap 'rm -rf "$temporary"' EXIT

compiler=(swiftc)
if [[ -x /usr/bin/xcrun ]]; then compiler=(/usr/bin/xcrun --sdk macosx swiftc); fi
"${compiler[@]}" -swift-version 6 -parse-as-library \
    -module-cache-path "$temporary/module-cache" \
    "$daemon/Daemon/GuestDisplayMetrics.swift" \
    "$daemon/Tests/DisplayMetricsTests.swift" \
    -o "$temporary/display-metrics-tests"
"$temporary/display-metrics-tests"
