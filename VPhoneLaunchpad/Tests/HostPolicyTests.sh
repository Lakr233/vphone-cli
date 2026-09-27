#!/bin/zsh
set -euo pipefail

launchpad="${0:a:h:h}"
temporary="$(/usr/bin/mktemp -d)"
trap '/bin/rm -rf "$temporary"' EXIT

/usr/bin/xcrun swiftc -swift-version 6 -strict-concurrency=complete \
    -parse-as-library \
    "$launchpad/VPhoneLaunchpadShared/VPhoneLaunchpadHostPolicy.swift" \
    "$launchpad/Tests/HostPolicyTests.swift" \
    -o "$temporary/host-policy-tests"
"$temporary/host-policy-tests" "$@"
