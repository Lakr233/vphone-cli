#!/bin/zsh
set -euo pipefail

launchpad="${0:a:h:h}"
temporary="$(/usr/bin/mktemp -d)"
trap '/bin/chmod -R u+rwx "$temporary"; /bin/rm -rf "$temporary"' EXIT

/usr/bin/xcrun swiftc -swift-version 6 -strict-concurrency=complete \
    -parse-as-library \
    "$launchpad/VPhoneLaunchpadShared/VPhoneLaunchpadHelperProtocol.swift" \
    "$launchpad/VPhoneLaunchpadHelper/VPhoneLaunchpadHelperCodeCheck.swift" \
    "$launchpad/VPhoneLaunchpadHelper/VPhoneLaunchpadHelperLibraryPath.swift" \
    "$launchpad/Tests/HelperLibraryPathTests.swift" \
    -o "$temporary/helper-library-path-tests"
"$temporary/helper-library-path-tests" "$temporary" "$@"
