#!/bin/zsh
# Sign a built vphone-launchpad.app for distribution. The Xcode build never
# signs; run this afterwards with a Developer ID Application identity from the
# team the app was built for (VPHONE_LAUNCHPAD_TEAM in the gitignored
# Configuration/Developer.xcconfig).
#
#   zsh VPhoneLaunchpad/Build/SignLaunchpad.sh <path/to/vphone-launchpad.app> "Developer ID Application: …"
#
# The helper is signed before the app that seals it. Neither gets
# entitlements. Afterwards the helper is checked against the app's
# SMPrivilegedExecutables requirement, which is what SMJobBless enforces.
set -euo pipefail

app=${1:?usage: SignLaunchpad.sh <vphone-launchpad.app> <identity>}
identity=${2:?usage: SignLaunchpad.sh <vphone-launchpad.app> <identity>}
label=com.vphone.launchpad.helper
helper="$app/Contents/Library/LaunchServices/$label"

requirement=$(/usr/libexec/PlistBuddy -c "Print :SMPrivilegedExecutables:$label" "$app/Contents/Info.plist")
if [[ $requirement == *'subject.OU] = ""'* ]]; then
  print -u2 "error: $app was built without VPHONE_LAUNCHPAD_TEAM; set it in Configuration/Developer.xcconfig and rebuild."
  exit 1
fi

codesign --force --options runtime --timestamp --sign "$identity" "$helper"
codesign --force --options runtime --timestamp --sign "$identity" "$app"

codesign --verify --strict --deep "$app"
codesign --verify --strict -R="$requirement" "$helper"
print "signed $app"
