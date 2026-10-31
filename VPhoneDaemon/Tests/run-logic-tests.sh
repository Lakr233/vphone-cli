#!/bin/zsh
set -euo pipefail

# Builds the guest-independent vphoned sources with LogicTests.swift for the
# Mac and runs them: service profile lists and bookkeeping, the first-boot
# settle verdict, the device name rule, the pointer scroll parameters, the
# Irisin package a guest takes. No guest is needed.

daemon="${0:a:h:h}"
temporary="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/vphone-logic-tests.XXXXXX")"
trap '/bin/rm -rf "$temporary"' EXIT

/usr/bin/xcrun --sdk macosx swiftc -swift-version 6 -parse-as-library \
    -module-cache-path "$temporary/module-cache" \
    "$daemon/Daemon/GuestServiceProfile.swift" \
    "$daemon/Daemon/GuestFirstBootSettle.swift" \
    "$daemon/Daemon/GuestDeviceNameRule.swift" \
    "$daemon/Daemon/GuestPointerScroll.swift" \
    "$daemon/Daemon/GuestProcessSpawnPolicy.swift" \
    "$daemon/Daemon/Bootstrap/GuestBootstrapPlatform.swift" \
    "$daemon/Daemon/GuestSetupAssistantState.swift" \
    "$daemon/Daemon/GuestHomeViewDistancePolicy.swift" \
    "$daemon/Tests/LogicTests.swift" \
    -o "$temporary/logic-tests"

"$temporary/logic-tests"
