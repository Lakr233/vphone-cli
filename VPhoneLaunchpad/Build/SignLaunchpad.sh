#!/bin/zsh
# Sign a built vphone-launchpad.app for distribution. The Xcode build never
# signs; run this afterwards with a Developer ID Application identity from the
# team the app was built for (VPHONE_LAUNCHPAD_TEAM in the gitignored
# Configuration/Developer.xcconfig).
#
#   zsh VPhoneLaunchpad/Build/SignLaunchpad.sh <path/to/vphone-launchpad.app> "Developer ID Application: …"
#
# The helper, the command line tool and the VM launcher are signed before the
# app that seals them, without entitlements. The app gets the hardened
# runtime resource entitlements in Resources/VPhoneLaunchpad.entitlements
# (microphone, camera and location) and no private ones. They are applied only here:
# CODE_SIGNING_ALLOWED is NO at build time, so no xcconfig sets
# CODE_SIGN_ENTITLEMENTS. The launcher is the process macOS holds responsible
# for each VM Launchpad starts; as a tool in the app's Contents/MacOS it is
# attributed to the app, so a guest's privacy prompts and grants are the
# app's, and under the hardened runtime the app's main executable must carry
# the matching entitlement or macOS refuses without asking. Afterwards the
# app's entitlements are checked, and the helper is checked against the app's
# SMPrivilegedExecutables requirement, which is what SMJobBless enforces.
set -euo pipefail

app=${1:?usage: SignLaunchpad.sh <vphone-launchpad.app> <identity>}
identity=${2:?usage: SignLaunchpad.sh <vphone-launchpad.app> <identity>}
entitlements="${0:a:h}/../Resources/VPhoneLaunchpad.entitlements"
label=com.vphone.launchpad.helper
helper="$app/Contents/Library/LaunchServices/$label"

requirement=$(/usr/libexec/PlistBuddy -c "Print :SMPrivilegedExecutables:$label" "$app/Contents/Info.plist")
if [[ $requirement == *'subject.OU] = ""'* ]]; then
  print -u2 "error: $app was built without VPHONE_LAUNCHPAD_TEAM; set it in Configuration/Developer.xcconfig and rebuild."
  exit 1
fi

codesign --force --options runtime --timestamp --sign "$identity" "$helper"
codesign --force --options runtime --timestamp --identifier com.vphone.launchpad.cli \
  --sign "$identity" "$app/Contents/MacOS/vphone-launchpad-cli"
codesign --force --options runtime --timestamp --identifier com.vphone.launchpad.launcher \
  --sign "$identity" "$app/Contents/MacOS/vphone-launchpad-launcher"
codesign --force --options runtime --timestamp --entitlements "$entitlements" \
  --sign "$identity" "$app"

codesign --verify --strict --deep "$app"
signed=$(codesign -d --entitlements - --xml "$app" 2>/dev/null)
for key in com.apple.security.device.audio-input com.apple.security.device.camera com.apple.security.personal-information.location; do
  if [[ $signed != *"<key>$key</key><true/>"* ]]; then
    print -u2 "error: $app is not signed with $key."
    exit 1
  fi
done
codesign --verify --strict -R="$requirement" "$helper"
print "signed $app"
