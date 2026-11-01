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

# Select the device SDK and product suffix explicitly so SwiftPM paths stay iOS
# even when Xcode only offers host destinations without a simulator runtime.
build_project -project "$root/VPhoneDaemon/VPhoneDaemon.xcodeproj" \
    -scheme vphoned -configuration "$configuration" \
    -sdk iphoneos \
    -derivedDataPath "$root/.build/XcodeDaemon" CODE_SIGNING_ALLOWED=NO \
    SUPPORTS_MACCATALYST=NO EFFECTIVE_PLATFORM_NAME=-iphoneos build

# Apple TV and HomePod guests run vphoned built against the AppleTVOS SDK, so
# its `#if os(tvOS)` branches and IcliKit's are the tvOS ones. That SDK has no
# IOKit.framework though tvOS ships one with the same exports, so the build
# links against the iPhoneOS SDK's IOKit headers and stub, targeted at tvOS.
tvos_frameworks="$root/.build/XcodeDaemon/tvos-frameworks"
iphoneos_iokit="$(/usr/bin/xcrun --sdk iphoneos --show-sdk-path)/System/Library/Frameworks/IOKit.framework/Versions/A"
/bin/rm -rf "$tvos_frameworks"
/bin/mkdir -p "$tvos_frameworks/IOKit.framework"
/bin/cp -R "$iphoneos_iokit/Headers" "$tvos_frameworks/IOKit.framework/Headers"
# Xcode 27's iPhoneOS SDK adds arm64e.x1; tvOS has arm64 and arm64e alone.
/usr/bin/sed -E -e 's/, *arm64e?\.[a-z0-9]+-ios//g' -e 's/arm64e?-ios/arm64-tvos, arm64e-tvos/' \
    "$iphoneos_iokit/IOKit.tbd" > "$tvos_frameworks/IOKit.framework/IOKit.tbd"
if ! /usr/bin/grep -q 'arm64-tvos' "$tvos_frameworks/IOKit.framework/IOKit.tbd" ||
    /usr/bin/grep -q -- '-ios[] ,]' "$tvos_frameworks/IOKit.framework/IOKit.tbd"; then
    print -u2 -- "Could not target the iPhoneOS SDK's IOKit.tbd at tvOS"
    exit 1
fi
build_project -project "$root/VPhoneDaemon/VPhoneDaemon.xcodeproj" \
    -scheme vphoned -configuration "$configuration" \
    -sdk appletvos \
    -derivedDataPath "$root/.build/XcodeDaemon" CODE_SIGNING_ALLOWED=NO \
    SUPPORTS_MACCATALYST=NO EFFECTIVE_PLATFORM_NAME=-appletvos \
    FRAMEWORK_SEARCH_PATHS="$tvos_frameworks" build

build_project -project "$root/VPhoneExecutable/VPhoneEscalator/VPhoneEscalator.xcodeproj" \
    -scheme VPhoneEscalator -configuration "$configuration" \
    -derivedDataPath "$root/.build/XcodeAMFIAllow" \
    ARCHS="arm64e arm64e.x1" ONLY_ACTIVE_ARCH=NO CODE_SIGNING_ALLOWED=NO build

/usr/bin/make -C "$root/VPhoneGuestComponents" OUT="$root/.build/guest-components" all

command_products="$root/.build/XcodeCommand/Build/Products/$configuration"
daemon_products="$root/.build/XcodeDaemon/Build/Products/$configuration-iphoneos"
tvos_daemon_products="$root/.build/XcodeDaemon/Build/Products/$configuration-appletvos"
amfi_products="$root/.build/XcodeAMFIAllow/Build/Products/$configuration"
guest_products="$root/.build/guest-components/stage"

# The iOS 26 Swift runtime lacks this symbol, and Swift 6.4 can import it
# strongly even when vphoned targets iOS 15, causing a dyld crash loop.
for daemon in "$daemon_products/vphoned" "$tvos_daemon_products/vphoned"; do
    if /usr/bin/nm -u "$daemon" | /usr/bin/grep -q '_swift_initBorrow'; then
        print -u2 -- "${daemon#$root/} requires _swift_initBorrow, which is unavailable on iOS 26 and tvOS 26"
        exit 1
    fi
done

/bin/rm -rf "$macos" "$resources"
/bin/mkdir -p "$macos" "$guest" "$frameworks"
/bin/rm -rf "$frameworks/VPhonePatchKit.framework"
/bin/cp -R "$command_products/VPhonePatchKit.framework" "$frameworks/VPhonePatchKit.framework"
/bin/cp "$TARGET_BUILD_DIR/vphone-vm" "$macos/vphone-vm"
# The terminal window's resources. libghostty is a static library, so nothing
# is embedded for it, but GhosttyTerminal reads its Ghostty directory and its
# compiled terminfo through Bundle.module. That searches Bundle.main's
# resources and then its root, and for vphone-vm Bundle.main is VPhone.bundle,
# not Contents/MacOS, so a copy beside the executable is never found. Without
# this the window traps the moment a session is opened.
/bin/cp -R "$TARGET_BUILD_DIR/GhosttyKit_GhosttyTerminal.bundle" \
    "$resources/GhosttyKit_GhosttyTerminal.bundle"
/bin/cp "$command_products/vphone-cli" "$macos/vphone-cli"
/bin/cp "$amfi_products/vphone-escalator" "$macos/vphone-escalator"
/bin/cp "$daemon_products/vphoned" "$guest/vphoned"
/bin/cp "$tvos_daemon_products/vphoned" "$guest/vphoned-tvos"
# Watch guests still run the iOS daemon marked watchOS: watchOS 8 is iOS 15's
# release.
daemon_sdk="$(/usr/bin/otool -l "$guest/vphoned" | /usr/bin/awk '/LC_BUILD_VERSION/ { found = 1 } found && $1 == "sdk" { print $2; exit }')"
/usr/bin/xcrun vtool -set-build-version watchos 8.0 "$daemon_sdk" -replace -output "$guest/vphoned-watchos" "$guest/vphoned"
# iOS before 26 needs Span's back-deployment library. Keep /usr/lib/swift
# first so newer guests use their system implementation; only the iOS daemon
# gets this private fallback. The TV and watch daemons above have none.
guest_compatibility_library="$(/usr/bin/xcrun swift-stdlib-tool --print \
    --scan-executable "$guest/vphoned" --platform iphoneos | \
    /usr/bin/grep '/libswiftCompatibilitySpan.dylib$')"
/bin/cp "$guest_compatibility_library" "$guest/libswiftCompatibilitySpan.dylib"
/usr/bin/install_name_tool -add_rpath /usr/lib/vphone "$guest/vphoned"
/usr/bin/codesign --force --sign - "$guest/libswiftCompatibilitySpan.dylib"
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
/bin/cp "$guest_products/batteryhealthfix/libbatteryhealthfix.dylib" "$guest/libbatteryhealthfix.dylib"
/bin/cp "$guest_products/devicehubfix/libdevicehubfix.dylib" "$guest/libdevicehubfix.dylib"
/bin/cp "$guest_products/devicename/libdevicename.dylib" "$guest/libdevicename.dylib"
/bin/cp "$guest_products/prefsfix/libprefsfix.dylib" "$guest/libprefsfix.dylib"
/bin/cp "$guest_products/signinfix/libsigninfix.dylib" "$guest/libsigninfix.dylib"
/bin/cp "$guest_products/ios17desktop/libvphoneios17desktop.dylib" "$guest/libvphoneios17desktop.dylib"
/bin/cp "$guest_products/gyroscope/libvphonegyro.dylib" "$guest/libvphonegyro.dylib"
/bin/cp "$guest_products/accelerometer/libvphoneaccelerometer.dylib" "$guest/libvphoneaccelerometer.dylib"
/bin/cp "$guest_products/hinge/libvphonehinge.dylib" "$guest/libvphonehinge.dylib"
/bin/cp "$guest_products/foldguard/libvphonefoldguard.dylib" "$guest/libvphonefoldguard.dylib"
/bin/cp "$guest_products/folddisplay/libvphonefolddisplay.dylib" "$guest/libvphonefolddisplay.dylib"
/bin/cp "$guest_products/attitude/libvphoneattitude.dylib" "$guest/libvphoneattitude.dylib"
/bin/cp "$guest_products/cryptexstaging/libvphonecryptexstaging.dylib" "$guest/libvphonecryptexstaging.dylib"
/bin/cp "$guest_products/homepodpersona/libvphoneinstallpersona.dylib" "$guest/libvphoneinstallpersona.dylib"
/bin/cp "$guest_products/homepodmisfix/libvphonehomepodmisfix.dylib" "$guest/libvphonehomepodmisfix.dylib"
/bin/cp "$guest_products/homepoddisplay/libvphonehomepoddisplay.dylib" "$guest/libvphonehomepoddisplay.dylib"
/bin/cp "$guest_products/tvsetupfocus/libvphonetvsetupfocus.dylib" "$guest/libvphonetvsetupfocus.dylib"
/bin/cp "$guest_products/homepodsetup/vphone-homepod-setup" "$guest/vphone-homepod-setup"
/bin/cp "$guest_products/homepodsetup/com.vphone.homepod-setup.plist" "$guest/com.vphone.homepod-setup.plist"
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

# The boot ROM new machines copy (vm new), with the licences it is
# distributed under. Checked in prebuilt; see Resources/OpenAVB/README.md.
/bin/mkdir -p "$resources/OpenAVB"
/bin/cp "$root/VPhoneExecutable/VPhoneVirtualization/Resources/OpenAVB/OpenAVB.bin" \
    "$root/VPhoneExecutable/VPhoneVirtualization/Resources/OpenAVB/LICENSE" \
    "$root/VPhoneExecutable/VPhoneVirtualization/Resources/OpenAVB/APSL-2.0.txt" \
    "$resources/OpenAVB/"

# The SEP ROM new machines copy, with its licence. Checked in prebuilt; see
# Resources/OpenSEP/README.md.
/bin/mkdir -p "$resources/OpenSEP"
/bin/cp "$root/VPhoneExecutable/VPhoneVirtualization/Resources/OpenSEP/OpenSEP.bin" \
    "$root/VPhoneExecutable/VPhoneVirtualization/Resources/OpenSEP/LICENSE" \
    "$resources/OpenSEP/"

# Patch presets. Prewritten plists, read by vphone-cli at patch time to decide
# which declared patches apply. Nothing generates or edits these.
/bin/mkdir -p "$resources/patches_presets"
/bin/cp "$root/VPhoneExecutable/VPhoneVirtualization/Resources/patches_presets/"*.plist \
    "$resources/patches_presets/"
# What `fw patch` rebuilds a research board kernelcache from; see its README.
/bin/rm -rf "$resources/kernelcache_recipes"
/bin/cp -R "$root/VPhoneExecutable/VPhoneVirtualization/Resources/kernelcache_recipes" "$resources/"

# Native KDK extraction ports MIT-licensed reference algorithms.
/bin/mkdir -p "$resources/Licenses"
/bin/cp "$root/VPhoneExecutable/VPhoneCommand/FirmwarePatcher/KernelCache/KDK/LICENSE" \
    "$resources/Licenses/native-kdk-MIT.txt"

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
/usr/bin/codesign --force --sign - --entitlements "$root/VPhoneDaemon/Configuration/VPhoneDaemon.entitlements" "$guest/vphoned-tvos"
/usr/bin/codesign --force --sign - --entitlements "$root/VPhoneDaemon/Configuration/VPhoneDaemon.entitlements" "$guest/vphoned-watchos"
/usr/bin/codesign --force --sign - "$macos/vphone-escalator"
/usr/bin/codesign --force --sign - "$macos/libswiftCompatibilitySpan.vphone.dylib"
/usr/bin/codesign --force --sign - --entitlements "$root/VPhoneExecutable/VPhoneVirtualization/Resources/VPhoneVirtualization.entitlements" "$macos/vphone-vm"
# locationd keeps the requirement a client first registered with and turns
# away a client with another one while that one still runs. An ad hoc
# signature's implicit requirement is its cdhash, so each build would be a
# new app: after an update the grant is lost, and two machines on different
# bundles cannot both read the Mac's location. Every build names the helper by
# identifier instead. That lends nothing new: the helper already hands the
# location to whatever starts it.
/usr/bin/codesign --force --sign - \
    --requirements '=designated => identifier "com.vphone.bundle.location"' "$location_app"
/usr/bin/codesign --force --sign - "$bundle"

"${0:a:h}/ValidateBundle.sh" "$bundle"
