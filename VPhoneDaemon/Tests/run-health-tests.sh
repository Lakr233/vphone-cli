#!/bin/sh
set -eu

daemon="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
temporary="$(mktemp -d "${TMPDIR:-/tmp}/vphone-health-tests.XXXXXX")"
trap 'rm -rf "$temporary"' EXIT

"${SWIFTC:-swiftc}" -swift-version 6 -warnings-as-errors -parse-as-library \
    -module-cache-path "$temporary/module-cache" \
    "$daemon/Daemon/GuestHealthCheck.swift" "$daemon/Tests/HealthCheckTests.swift" \
    -o "$temporary/health-tests"
"$temporary/health-tests"
