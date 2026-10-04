#!/bin/zsh
# vphone-tier: build
set -euo pipefail

root="$(cd "${0:a:h}/../../.." && pwd)"
configuration="${CONFIGURATION:?}"
bundle="${TARGET_BUILD_DIR:?}/${FULL_PRODUCT_NAME:?}"
macos="$bundle/Contents/MacOS"
resources="$bundle/Contents/Resources"
# VPhonePatchKit is the patch API. vphone-cli links it, and patch sets resolve
# against this one copy rather than statically linking a second disassembler.
frameworks="$bundle/Contents/Frameworks"
# Host programs run from Contents/MacOS. Everything installed into the guest
# lives in guest-resources and never runs on the Mac.
guest="$resources/guest-resources"
location_app="$bundle/Contents/Helpers/VPhoneLocation.app"

# Xcode exports the bundle target's SDK and package paths to build phases. Nested
# xcodebuild must resolve each project's own graph, especially the iOS daemon.
build_project() {
    /usr/bin/env -i HOME="$HOME" TMPDIR="${TMPDIR:-/tmp}" \
        PATH="/usr/bin:/bin:/usr/sbin:/sbin" /usr/bin/xcodebuild "$@"
}

build_project -project "$root/VPhoneExecutable/VPhoneCommand/VPhoneRestore/VPhoneRestore.xcodeproj" \
    -scheme VPhoneRestore -configuration "$configuration" \
    -destination 'platform=macOS,arch=arm64' \
    -derivedDataPath "$root/.build/XcodeRestore" CODE_SIGNING_ALLOWED=NO build

build_project -project "$root/VPhoneExecutable/VPhoneCommand/VPhoneCommand.xcodeproj" \
    -scheme VPhoneCommand -configuration "$configuration" \
    -destination 'platform=macOS,arch=arm64' \
    -derivedDataPath "$root/.build/XcodeCommand" CODE_SIGNING_ALLOWED=NO build

build_project -project "$root/VPhoneDaemon/VPhoneDaemon.xcodeproj" \
    -scheme vphoned -configuration "$configuration" \
    -destination 'generic/platform=iOS' \
    -derivedDataPath "$root/.build/XcodeDaemon" CODE_SIGNING_ALLOWED=NO build

build_project -project "$root/VPhoneExecutable/VPhoneEscalator/VPhoneEscalator.xcodeproj" \
    -scheme VPhoneEscalator -configuration "$configuration" \
    -derivedDataPath "$root/.build/XcodeAMFIAllow" \
    ARCHS="arm64e arm64e.x1" ONLY_ACTIVE_ARCH=NO CODE_SIGNING_ALLOWED=NO build

/usr/bin/make -C "$root/VPhoneGuestComponents" OUT="$root/.build/guest-components" all

command_products="$root/.build/XcodeCommand/Build/Products/$configuration"
daemon_products="$root/.build/XcodeDaemon/Build/Products/$configuration-iphoneos"
amfi_products="$root/.build/XcodeAMFIAllow/Build/Products/$configuration"
guest_products="$root/.build/guest-components/stage"

# The iOS 26 Swift runtime lacks this symbol, and Swift 6.4 can import it
# strongly even when vphoned targets iOS 15, causing a dyld crash loop.
if /usr/bin/nm -u "$daemon_products/vphoned" | /usr/bin/grep -q '_swift_initBorrow'; then
    print -u2 -- "vphoned requires _swift_initBorrow, which is unavailable on iOS 26"
    exit 1
fi

/bin/rm -rf "$macos" "$resources"
/bin/mkdir -p "$macos" "$guest" "$frameworks"
/bin/rm -rf "$frameworks/VPhonePatchKit.framework"
/bin/cp -R "$command_products/VPhonePatchKit.framework" "$frameworks/VPhonePatchKit.framework"
/bin/cp "$TARGET_BUILD_DIR/vphone-vm" "$macos/vphone-vm"
/bin/cp "$command_products/vphone-cli" "$macos/vphone-cli"
/bin/cp "$amfi_products/vphone-escalator" "$macos/vphone-escalator"
/bin/cp "$daemon_products/vphoned" "$guest/vphoned"
/bin/cp "$root/VPhoneDaemon/Configuration/vphoned.plist" "$guest/vphoned.plist"
/bin/cp "$guest_products/launchhook/launchdhook-vphone.dylib" "$guest/launchdhook-vphone.dylib"
/bin/cp "$guest_products/systemhook/SystemHook-vphone.dylib" "$guest/SystemHook-vphone.dylib"
/bin/cp "$guest_products/camfix/libcamfix.dylib" "$guest/libcamfix.dylib"
/bin/cp "$guest_products/camfix/libcamfix.plist" "$guest/libcamfix.plist"
/bin/cp "$guest_products/vcamcaptured/libvcamcaptured.dylib" "$guest/libvcamcaptured.dylib"
/bin/cp "$guest_products/vcamcaptured/libvcamcaptured.plist" "$guest/libvcamcaptured.plist"
/bin/cp "$guest_products/misfix/libmisfix.dylib" "$guest/libmisfix.dylib"
/bin/cp "$guest_products/misfix/libmisfix.plist" "$guest/libmisfix.plist"
/bin/cp "$guest_products/hapticsfix/libhapticsfix.dylib" "$guest/libhapticsfix.dylib"
/bin/cp "$guest_products/gpu/libAppleParavirtCompilerPluginIOGPUFamily.dylib" \
    "$guest/libAppleParavirtCompilerPluginIOGPUFamily.dylib"
# The HAL plugin is a bundle, signed whole by the Makefile; copied as a tree so
# its _CodeSignature still matches.
/bin/cp -R "$guest_products/virtiosound/VPhoneVirtIOSound.driver" "$guest/VPhoneVirtIOSound.driver"

# The commit this bundle was built from, shown in vphone-vm's app menu next to
# CFBundleShortVersionString and CFBundleVersion. A tree with uncommitted
# tracked changes is marked dirty. Outside a git checkout the key is removed,
# so an incremental build never keeps a stale hash.
info_plist="$bundle/Contents/Info.plist"
if build_hash="$(/usr/bin/git -C "$root" rev-parse --verify --short HEAD 2>/dev/null)"; then
    if [[ -n "$(/usr/bin/git -C "$root" status --porcelain --untracked-files=no 2>/dev/null)" ]]; then
        build_hash+="-dirty"
    fi
    /usr/bin/plutil -replace VPhoneBuildHash -string "$build_hash" "$info_plist"
else
    /usr/bin/plutil -remove VPhoneBuildHash "$info_plist" 2>/dev/null || true
fi

# Patch presets. Prewritten plists, read by vphone-cli at patch time to decide
# which declared patches apply. Nothing generates or edits these.
/bin/mkdir -p "$resources/patches_presets"
/bin/cp "$root/VPhoneExecutable/VPhoneVirtualization/Resources/patches_presets/"*.plist \
    "$resources/patches_presets/"

"${0:a:h}/SyncStrings.sh"
/usr/bin/xcrun xcstringstool compile \
    "$root/VPhoneExecutable/VPhoneVirtualization/Resources/Localizable.xcstrings" \
    --output-directory "$resources"
# The microphone prompt names this bundle, and reads its text from here.
/usr/bin/xcrun xcstringstool compile \
    "$root/VPhoneExecutable/VPhoneVirtualization/Resources/InfoPlist.xcstrings" \
    --output-directory "$resources"

# locationd ignores a client inside a generic bundle, so vphone-vm reads the
# host location through this app. Its InfoPlist.strings translate the
# location prompt.
/bin/rm -rf "$location_app"
/bin/mkdir -p "$location_app/Contents/MacOS" "$location_app/Contents/Resources"
/bin/cp "$root/VPhoneExecutable/VPhoneVirtualization/Resources/VPhoneLocation.Info.plist" \
    "$location_app/Contents/Info.plist"
/bin/cp "$TARGET_BUILD_DIR/vphone-location" "$location_app/Contents/MacOS/vphone-location"
/usr/bin/xcrun xcstringstool compile \
    "$root/VPhoneExecutable/VPhoneVirtualization/Resources/InfoPlist.xcstrings" \
    --output-directory "$location_app/Contents/Resources"

# vphone-vm needs Swift's span back-deployment library on macOS 15. Xcode's
# generic bundle has no main executable. Use a private load name for the VM child.
compatibility_library="$(/usr/bin/xcrun swift-stdlib-tool --print \
    --scan-executable "$macos/vphone-vm" --platform macosx | \
    /usr/bin/grep '/libswiftCompatibilitySpan.dylib$')"
/bin/cp "$compatibility_library" "$macos/libswiftCompatibilitySpan.vphone.dylib"
/usr/bin/install_name_tool -change @rpath/libswiftCompatibilitySpan.dylib \
    @loader_path/libswiftCompatibilitySpan.vphone.dylib "$macos/vphone-vm"
/bin/rm -f "$frameworks/libswiftCompatibilitySpan.dylib"

/usr/bin/codesign --force --sign - "$frameworks/VPhonePatchKit.framework"
/usr/bin/codesign --force --sign - "$macos/vphone-cli"
/usr/bin/codesign --force --sign - --entitlements "$root/VPhoneDaemon/Configuration/VPhoneDaemon.entitlements" "$guest/vphoned"
/usr/bin/codesign --force --sign - "$macos/vphone-escalator"
/usr/bin/codesign --force --sign - "$macos/libswiftCompatibilitySpan.vphone.dylib"
/usr/bin/codesign --force --sign - --entitlements "$root/VPhoneExecutable/VPhoneVirtualization/Resources/VPhoneVirtualization.entitlements" "$macos/vphone-vm"
/usr/bin/codesign --force --sign - "$location_app"
/usr/bin/codesign --force --sign - "$bundle"

"${0:a:h}/ValidateBundle.sh" "$bundle"
