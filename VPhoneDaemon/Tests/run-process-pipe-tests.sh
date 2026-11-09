#!/bin/zsh
set -euo pipefail

daemon="${0:a:h:h}"
temporary="$(mktemp -d "${TMPDIR:-/tmp}/vphone-process-pipe-tests.XXXXXX")"
trap 'rm -rf "$temporary"' EXIT

"${SWIFTC:-swiftc}" -swift-version 6 -warnings-as-errors -parse-as-library \
    -module-cache-path "$temporary/module-cache" \
    "$daemon/Daemon/GuestProcessPipe.swift" "$daemon/Tests/ProcessPipeTests.swift" \
    -o "$temporary/process-pipe-tests"
"$temporary/process-pipe-tests"
