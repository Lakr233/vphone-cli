#!/bin/zsh
set -euo pipefail

launchpad="${0:a:h:h}"
temporary="$(/usr/bin/mktemp -d)"
trap '/bin/rm -rf "$temporary"' EXIT

# The child process calls the kit's spawn; build just that file as the module.
/usr/bin/xcrun swiftc -swift-version 6 -strict-concurrency=complete \
    -parse-as-library -module-name VPhoneCoreKit \
    -emit-module -emit-module-path "$temporary/VPhoneCoreKit.swiftmodule" \
    -emit-object -o "$temporary/VPhoneCoreKit.o" \
    "${launchpad:h}/VPhoneKit/VPhoneCoreKit/Process/VPhoneDetachedProcess.swift"

/usr/bin/xcrun swiftc -swift-version 6 -strict-concurrency=complete \
    -parse-as-library -I "$temporary" "$temporary/VPhoneCoreKit.o" \
    "$launchpad/VPhoneLaunchpadShared/VPhoneLaunchpadBundleStore.swift" \
    "$launchpad/VPhoneLaunchpadShared/VPhoneLaunchpadLineReader.swift" \
    "$launchpad/VPhoneLaunchpadShared/VPhoneLaunchpadLauncherPolicy.swift" \
    "$launchpad/VPhoneLaunchpad/Command/VPhoneLaunchpadChildProcess.swift" \
    "$launchpad/VPhoneLaunchpad/Command/VPhoneLaunchpadCommandLine.swift" \
    "$launchpad/VPhoneLaunchpad/Machines/VPhoneLaunchpadMachine.swift" \
    "$launchpad/VPhoneLaunchpad/Machines/VPhoneLaunchpadMachineBinding.swift" \
    "$launchpad/VPhoneLaunchpad/Machines/VPhoneLaunchpadMachineSnapshot.swift" \
    "$launchpad/Tests/MachineSnapshotsTests.swift" \
    -o "$temporary/machine-snapshots-tests"
"$temporary/machine-snapshots-tests" "$@"
