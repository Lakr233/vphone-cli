#!/bin/zsh
set -euo pipefail

tests=${0:a:h}
root=${tests:h}
temporary=$(mktemp -d)
trap 'rm -rf "$temporary"' EXIT
chmod 0700 "$temporary"

xcrun swiftc -swift-version 6 -D VPHONE_UNATTENDED_GRANT_TEST \
  "$root/VPhoneLaunchpadHelper/VPhoneLaunchpadHelperUnattendedGrant.swift" \
  "$tests/UnattendedGrantTests.swift" \
  -o "$temporary/UnattendedGrantTests"

VPHONE_GRANT_TEST_PARENT="$temporary" "$temporary/UnattendedGrantTests"
