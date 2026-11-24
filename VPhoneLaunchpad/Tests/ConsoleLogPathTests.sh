#!/bin/zsh
set -euo pipefail

launchpad="${0:a:h:h}"
temporary="$(/usr/bin/mktemp -d)"
trap '/bin/rm -rf "$temporary"' EXIT

# The console-log naming calls the kit's VPhoneMachineConsoleLog; build just
# that file as the VPhoneCoreKit module.
/usr/bin/xcrun swiftc -swift-version 6 -strict-concurrency=complete \
    -parse-as-library -module-name VPhoneCoreKit \
    -emit-module -emit-module-path "$temporary/VPhoneCoreKit.swiftmodule" \
    -emit-object -o "$temporary/VPhoneCoreKit.o" \
    "${launchpad:h}/VPhoneKit/VPhoneCoreKit/Support/VPhoneMachineConsoleLog.swift"

/usr/bin/xcrun swiftc -swift-version 6 -strict-concurrency=complete \
    -parse-as-library -I "$temporary" "$temporary/VPhoneCoreKit.o" \
    "$launchpad/VPhoneLaunchpad/Machines/VPhoneLaunchpadConsoleLog.swift" \
    "$launchpad/Tests/ConsoleLogPathTests.swift" \
    -o "$temporary/console-log-path-tests"
"$temporary/console-log-path-tests" "$@"
