#!/bin/zsh
set -euo pipefail

daemon="${0:a:h:h}"
temporary="$(mktemp -d "${TMPDIR:-/tmp}/vphone-process-output-tests.XXXXXX")"
trap 'rm -rf "$temporary"' EXIT

"${SWIFTC:-swiftc}" -swift-version 6 -warnings-as-errors -parse-as-library \
    -module-cache-path "$temporary/module-cache" \
    "$daemon/Daemon/GuestProcessOutput.swift" "$daemon/Tests/ProcessOutputTests.swift" \
    -o "$temporary/process-output-tests"
"$temporary/process-output-tests"
