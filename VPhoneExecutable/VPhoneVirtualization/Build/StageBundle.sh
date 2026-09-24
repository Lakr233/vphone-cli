#!/bin/zsh
# vphone-tier: build
set -euo pipefail

root="$(cd "${0:a:h}/../../.." && pwd)"
configuration="${CONFIGURATION:?}"
bundle="${TARGET_BUILD_DIR:?}/${FULL_PRODUCT_NAME:?}"
macos="$bundle/Contents/MacOS"
resources="$bundle/Contents/Resources"

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

build_project -project "$root/VPhoneDaemon/VPhoneDaemon.xcodeproj" \
    -scheme vpregister -configuration "$configuration" \
    -destination 'generic/platform=iOS' \
    -derivedDataPath "$root/.build/XcodeDaemon" CODE_SIGNING_ALLOWED=NO build

build_project -project "$root/VPhoneExecutable/VPhoneEscalator/VPhoneEscalator.xcodeproj" \
    -scheme VPhoneEscalator -configuration "$configuration" \
    -destination 'platform=macOS,arch=arm64e' \
    -derivedDataPath "$root/.build/XcodeAMFIAllow" CODE_SIGNING_ALLOWED=NO build

/usr/bin/make -C "$root/VPhoneGuestComponents" OUT="$root/.build/guest-components" all

command_products="$root/.build/XcodeCommand/Build/Products/$configuration"
daemon_products="$root/.build/XcodeDaemon/Build/Products/$configuration-iphoneos"
amfi_products="$root/.build/XcodeAMFIAllow/Build/Products/$configuration"
guest_products="$root/.build/guest-components/stage"

# The iOS 26 Swift runtime lacks this symbol. Swift Collections 1.7.0 emits
# it with Xcode 27 even when vphoned targets iOS 15, causing a dyld crash loop.
if /usr/bin/nm -u "$daemon_products/vphoned" | /usr/bin/grep -q '_swift_initBorrow'; then
    print -u2 -- "vphoned requires _swift_initBorrow, which is unavailable on iOS 26"
    exit 1
fi

/bin/rm -rf "$macos" "$resources"
/bin/mkdir -p "$macos" "$resources/scripts/vphoned" "$resources/guest"
/bin/cp "$TARGET_BUILD_DIR/vphone-vm" "$macos/vphone-vm"
/bin/cp "$command_products/vphone-cli" "$macos/vphone-cli"
/bin/cp "$daemon_products/vphoned" "$macos/vphoned"
/bin/cp "$daemon_products/vphoned" "$macos/vphoned.signed"
/bin/cp "$daemon_products/vpregister" "$macos/vpregister"
/bin/cp "$amfi_products/VPhoneEscalator" "$macos/VPhoneEscalator"
/bin/cp "$guest_products/camfix/libcamfix.dylib" "$macos/libcamfix.dylib"
/bin/cp "$guest_products/vcamcaptured/libvcamcaptured.dylib" "$macos/libvcamcaptured.dylib"
/bin/cp "$guest_products/tweakloader/TweakLoader.dylib" "$macos/TweakLoader.dylib"
/bin/cp "$guest_products/gpu/libAppleParavirtCompilerPluginIOGPUFamily.dylib" "$macos/libAppleParavirtCompilerPluginIOGPUFamily.dylib"
/bin/cp "$root/VPhoneDaemon/Configuration/vphoned.plist" "$resources/scripts/vphoned/vphoned.plist"
/bin/cp "$root/VPhoneDaemon/Configuration/VPhoneDaemon.entitlements" "$resources/scripts/vphoned/VPhoneDaemon.entitlements"
/bin/cp "$guest_products/camfix/libcamfix.plist" "$resources/guest/libcamfix.plist"
/bin/cp "$guest_products/vcamcaptured/libvcamcaptured.plist" "$resources/guest/libvcamcaptured.plist"

# vphone-vm needs Swift's span back-deployment library on macOS 15. Xcode's
# generic bundle has no main executable. Use a private load name for the VM child.
compatibility_library="$(/usr/bin/xcrun swift-stdlib-tool --print \
    --scan-executable "$macos/vphone-vm" --platform macosx | \
    /usr/bin/grep '/libswiftCompatibilitySpan.dylib$')"
/bin/cp "$compatibility_library" "$macos/libswiftCompatibilitySpan.vphone.dylib"
/usr/bin/install_name_tool -change @rpath/libswiftCompatibilitySpan.dylib \
    @loader_path/libswiftCompatibilitySpan.vphone.dylib "$macos/vphone-vm"
/bin/rm -f "$macos/libswiftCompatibilitySpan.dylib" \
    "$macos/libswiftCompatibilitySpan.dylib.original"
/bin/rm -f "$bundle/Contents/Frameworks/libswiftCompatibilitySpan.dylib"

/usr/bin/codesign --force --sign - "$macos/vphone-cli"
/usr/bin/codesign --force --sign - --entitlements "$root/VPhoneDaemon/Configuration/VPhoneDaemon.entitlements" "$macos/vphoned"
/usr/bin/codesign --force --sign - --entitlements "$root/VPhoneDaemon/Configuration/VPhoneDaemon.entitlements" "$macos/vphoned.signed"
/usr/bin/codesign --force --sign - "$macos/vpregister"
/usr/bin/codesign --force --sign - "$macos/VPhoneEscalator"
/usr/bin/codesign --force --sign - "$macos/libswiftCompatibilitySpan.vphone.dylib"
/usr/bin/codesign --force --sign - --entitlements "$root/VPhoneExecutable/VPhoneVirtualization/Resources/VPhoneVirtualization.entitlements" "$macos/vphone-vm"
/usr/bin/codesign --force --sign - "$bundle"
