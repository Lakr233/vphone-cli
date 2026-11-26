#!/bin/zsh
set -euo pipefail

# Builds the guest-independent vphoned sources with LogicTests.swift for the
# Mac and runs them: service profile lists and bookkeeping, the first-boot
# settle verdict, the device name rule, the pointer scroll parameters, the
# Irisin package a guest takes, the MobileGestalt answers vphoned adds, the
# value settings.set writes, the screenshot crop, scale and encode, the verified-foreground outcomes. No guest
# is needed.

daemon="${0:a:h:h}"
temporary="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/vphone-logic-tests.XXXXXX")"
trap '/bin/rm -rf "$temporary"' EXIT

# The verified-foreground check imports IcliKit; the stub shared with the
# point-geometry runner stands in for it.
/usr/bin/xcrun --sdk macosx swiftc -swift-version 6 -emit-library -emit-module -module-name IcliKit \
    -module-cache-path "$temporary/module-cache" \
    "$daemon/Tests/IcliForegroundStub.swift" -o "$temporary/libIcliKit.dylib"

/usr/bin/xcrun --sdk macosx swiftc -swift-version 6 -parse-as-library \
    -module-cache-path "$temporary/module-cache" -I "$temporary" -L "$temporary" -lIcliKit \
    -Xlinker -rpath -Xlinker "$temporary" \
    "$daemon/Daemon/GuestServiceProfile.swift" \
    "$daemon/Daemon/GuestFirstBootSettle.swift" \
    "$daemon/Daemon/GuestDeviceNameRule.swift" \
    "$daemon/Daemon/GuestPointerScroll.swift" \
    "$daemon/Daemon/GuestProcessSpawnPolicy.swift" \
    "$daemon/Daemon/GuestProcessOutput.swift" \
    "$daemon/Daemon/GuestProcessSpool.swift" \
    "$daemon/Daemon/Bootstrap/GuestBootstrapPlatform.swift" \
    "$daemon/Daemon/GuestSetupAssistantState.swift" \
    "$daemon/Daemon/GuestHomeViewDistancePolicy.swift" \
    "$daemon/Daemon/GuestMobileGestaltAnswers.swift" \
    "$daemon/Daemon/GuestSettingsValue.swift" \
    "$daemon/Daemon/GuestMethodSpec.swift" \
    "$daemon/Daemon/GuestScreenshotSizing.swift" \
    "$daemon/Daemon/GuestPaging.swift" \
    "$daemon/Daemon/GuestAPI+Foreground.swift" \
    "$daemon/Daemon/GuestElementRequest.swift" \
    "$daemon/Daemon/GuestAccessibilityRequest.swift" \
    "$daemon/Tests/LogicTests.swift" \
    -o "$temporary/logic-tests"

"$temporary/logic-tests"
