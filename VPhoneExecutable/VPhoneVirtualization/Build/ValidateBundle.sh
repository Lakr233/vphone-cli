#!/bin/zsh
# vphone-tier: build
set -euo pipefail

root="$(cd "${0:a:h}/../../.." && pwd)"
bundle="${1:-$root/.build/XcodeBundle/Build/Products/Debug/VPhone.bundle}"
macos="$bundle/Contents/MacOS"
resources="$bundle/Contents/Resources"
frameworks="$bundle/Contents/Frameworks"
guest="$resources/guest-resources"
location_app="$bundle/Contents/Helpers/VPhoneLocation.app"
location_helper="$location_app/Contents/MacOS/vphone-location"

file_copy_spawns="$(/usr/bin/find "$root/VPhoneExecutable" "$root/VPhoneKit" \
    "$root/VPhoneDaemon" "$root/VPhoneGuestComponents" \
    -type d \( -name Build -o -name .build -o -name '*Tests' -o -name '*TestFixtures' \) -prune -o \
    -type f -name '*.swift' -exec /usr/bin/grep -nE '"/(usr/)?bin/(cp|mv|rm)"' {} + || true)"
[[ -z "$file_copy_spawns" ]] || {
    print -u2 "Host file operations must use in-process file APIs, not spawned cp/mv/rm:"
    print -u2 -- "$file_copy_spawns"
    exit 1
}

[[ -d "$bundle" ]] || { print -u2 "Missing Xcode bundle: $bundle"; exit 1; }

require_signed_macho() {
    local file="$1"
    [[ -f "$file" ]] || { print -u2 "Missing binary: ${file#$bundle/}"; exit 1; }
    # Drain every architecture line so pipefail does not mistake file's SIGPIPE
    # after grep's early exit for a malformed universal binary.
    /usr/bin/file "$file" | /usr/bin/grep 'Mach-O' >/dev/null || {
        print -u2 "Not a Mach-O: ${file#$bundle/}"
        exit 1
    }
    /usr/bin/codesign --verify "$file" || {
        print -u2 "Invalid signature: ${file#$bundle/}"
        exit 1
    }
}

for name in vphone-vm vphone-cli vphone-escalator libswiftCompatibilitySpan.vphone.dylib; do
    require_signed_macho "$macos/$name"
done
require_signed_macho "$frameworks/VPhonePatchKit.framework/Versions/A/VPhonePatchKit"
require_signed_macho "$location_helper"
/usr/bin/codesign --verify --strict "$location_app"
# locationd answers only a client inside an .app, and prompts with its usage
# description in the user's language.
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundlePackageType' "$location_app/Contents/Info.plist")" == "APPL" ]] || {
    print -u2 "VPhoneLocation.app is not an application bundle"
    exit 1
}
for language in en zh-Hans ja ko vi; do
    strings="$location_app/Contents/Resources/$language.lproj/InfoPlist.strings"
    /usr/libexec/PlistBuddy -c 'Print :NSLocationWhenInUseUsageDescription' "$strings" >/dev/null 2>&1 || {
        print -u2 "Missing location prompt text in VPhoneLocation.app: $language"
        exit 1
    }
done
# The host microphone is opened by vphone-vm itself, so macOS prompts for this
# bundle and refuses the microphone to one with no usage description.
/usr/libexec/PlistBuddy -c 'Print :NSMicrophoneUsageDescription' "$bundle/Contents/Info.plist" >/dev/null 2>&1 || {
    print -u2 "VPhone.bundle has no microphone usage description"
    exit 1
}
for language in en zh-Hans ja ko vi; do
    strings="$resources/$language.lproj/InfoPlist.strings"
    /usr/libexec/PlistBuddy -c 'Print :NSMicrophoneUsageDescription' "$strings" >/dev/null 2>&1 || {
        print -u2 "Missing microphone prompt text in VPhone.bundle: $language"
        exit 1
    }
done
# The patch API ships its interface so an out-of-tree patch set can build against
# the same framework the bundle loads.
[[ -d "$frameworks/VPhonePatchKit.framework/Versions/A/Modules/VPhonePatchKit.swiftmodule" ]] || {
    print -u2 "VPhonePatchKit.framework has no Swift module interface"
    exit 1
}
# The presets decide which declared patches apply. A bundle without the standard
# one would fall back to vphone-cli's built-in copy, so a VM built from a shipped
# bundle and one built from an Xcode build could get different patches.
[[ -f "$resources/patches_presets/standard.plist" ]] || {
    print -u2 "Missing patch preset: patches_presets/standard.plist"
    exit 1
}
for preset in "$resources/patches_presets/"*.plist; do
    /usr/bin/plutil -lint -s "$preset" || { print -u2 "Malformed patch preset: ${preset:t}"; exit 1; }
done

for name in vphoned launchdhook-vphone.dylib SystemHook-vphone.dylib libcamfix.dylib \
    libvcamcaptured.dylib libmisfix.dylib libhapticsfix.dylib libAppleParavirtCompilerPluginIOGPUFamily.dylib; do
    require_signed_macho "$guest/$name"
done
for name in vphoned.plist libcamfix.plist libvcamcaptured.plist libmisfix.plist; do
    [[ -f "$guest/$name" ]] || { print -u2 "Missing guest configuration: $name"; exit 1; }
done
# The virtio sound HAL plugin is a whole bundle: audiomxd finds its factory
# through Info.plist, and the bundle signature seals both.
require_signed_macho "$guest/VPhoneVirtIOSound.driver/VPhoneVirtIOSound"
/usr/bin/codesign --verify --strict "$guest/VPhoneVirtIOSound.driver" || {
    print -u2 "Invalid signature: VPhoneVirtIOSound.driver"
    exit 1
}
/usr/libexec/PlistBuddy -c 'Print :CFPlugInFactories' "$guest/VPhoneVirtIOSound.driver/Info.plist" |
    /usr/bin/grep -q VPVirtIOSoundFactory || {
    print -u2 "VPhoneVirtIOSound.driver does not name its factory"
    exit 1
}
[[ ! -e "$guest/libvlocation.dylib" ]] || { print -u2 "Obsolete guest library: libvlocation.dylib"; exit 1; }

for name in vphoned vphoned.signed vphone-app VPhoneAMFIAllow VPhoneEscalator vphone-archive icli vpregister \
    vphone-ask-for-permission libcamfix.dylib libvlocation.dylib libvcamcaptured.dylib launchdhook-vphone.dylib \
    SystemHook-vphone.dylib libmisfix.dylib libAppleParavirtCompilerPluginIOGPUFamily.dylib; do
    [[ ! -e "$macos/$name" ]] || { print -u2 "Obsolete binary: Contents/MacOS/$name"; exit 1; }
done
for name in guest scripts; do
    [[ ! -e "$resources/$name" ]] || { print -u2 "Obsolete directory: Contents/Resources/$name"; exit 1; }
done

/usr/bin/codesign --verify --strict "$bundle"

[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundlePackageType' "$bundle/Contents/Info.plist")" == "BNDL" ]] || {
    print -u2 "The product is not a generic bundle"
    exit 1
}
if /usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$bundle/Contents/Info.plist" >/dev/null 2>&1; then
    print -u2 "The container must not declare an executable"
    exit 1
fi
# Host programs live in Contents/MacOS and guest payloads in guest-resources.
# The build platform keeps an iOS binary from landing among the host programs.
while IFS= read -r file; do
    /usr/bin/file "$file" | /usr/bin/grep 'Mach-O' >/dev/null || continue
    platform="$(/usr/bin/vtool -show-build "$file" 2>/dev/null | /usr/bin/awk '$1 == "platform" && !found {print $2; found=1}')"
    case "$file" in
        "$macos/"*)
            [[ "$platform" != IOS ]] || { print -u2 "iOS binary in Contents/MacOS: ${file#$bundle/}"; exit 1; }
            ;;
        "$location_helper")
            [[ "$platform" != IOS ]] || { print -u2 "iOS binary in VPhoneLocation.app"; exit 1; }
            ;;
        "$frameworks/"*)
            [[ "$platform" != IOS ]] || { print -u2 "iOS binary in Contents/Frameworks: ${file#$bundle/}"; exit 1; }
            ;;
        "$guest/"*)
            [[ "$platform" == IOS ]] || { print -u2 "Non-iOS binary in guest-resources: ${file#$bundle/}"; exit 1; }
            ;;
        *)
            print -u2 "Mach-O outside Contents/MacOS, Contents/Frameworks, VPhoneLocation.app and guest-resources: ${file#$bundle/}"
            exit 1
            ;;
    esac
done < <(/usr/bin/find "$bundle/Contents" -type f)
bundle_entitlements="$(/usr/bin/codesign -d --entitlements - --xml "$bundle" 2>/dev/null || true)"
[[ "$bundle_entitlements" != *'com.apple.private.virtualization'* ]] || {
    print -u2 "The bundle must not carry private virtualization entitlements"
    exit 1
}
vm_entitlements="$(/usr/bin/codesign -d --entitlements - --xml "$macos/vphone-vm" 2>/dev/null)"
[[ "$vm_entitlements" == *'com.apple.private.virtualization'* ]] || {
    print -u2 "VM private entitlements are missing"
    exit 1
}
[[ "$vm_entitlements" != *'com.apple.CommCenter.fine-grained'* ]] || {
    print -u2 "Guest daemon entitlements leaked into vphone-vm"
    exit 1
}
daemon_entitlements="$(/usr/bin/codesign -d --entitlements - --xml "$guest/vphoned" 2>/dev/null)"
[[ "$daemon_entitlements" == *'com.apple.CommCenter.fine-grained'* &&
    "$daemon_entitlements" != *'com.apple.private.virtualization'* ]] || {
    print -u2 "vphoned has the wrong entitlements"
    exit 1
}
for name in vphone-cli vphone-escalator ../Helpers/VPhoneLocation.app/Contents/MacOS/vphone-location; do
    process_entitlements="$(/usr/bin/codesign -d --entitlements - --xml "$macos/$name" 2>/dev/null || true)"
    [[ "$process_entitlements" != *'com.apple.private.virtualization'* &&
        "$process_entitlements" != *'com.apple.CommCenter.fine-grained'* ]] || {
        print -u2 "Unexpected private entitlements on $name"
        exit 1
    }
done

for name in vphone-vm vphone-cli vphone-escalator ../Helpers/VPhoneLocation.app/Contents/MacOS/vphone-location; do
    /usr/bin/otool -L "$macos/$name" | /usr/bin/awk 'NR > 1 {print $1}' |
    while IFS= read -r dependency; do
        case "$dependency" in
            /usr/lib/*|/System/Library/*|@rpath/*|@loader_path/*|@executable_path/*) ;;
            *) print -u2 "External host dependency in $name: $dependency"; exit 1 ;;
        esac
    done
done

temporary="$(/usr/bin/mktemp -d)"
trap '/bin/rm -rf "$temporary"' EXIT
/bin/mkdir -p "$temporary/source" "$temporary/destination"
print -rn -- 'vphone archive round trip' > "$temporary/source/probe.txt"
/usr/bin/env -i HOME="$HOME" PATH=/usr/bin:/bin \
    "$macos/vphone-cli" archive create -f "$temporary/probe.tar.zst" \
    -C "$temporary/source" --zstd >/dev/null
/usr/bin/env -i HOME="$HOME" PATH=/usr/bin:/bin \
    "$macos/vphone-cli" archive extract -f "$temporary/probe.tar.zst" \
    -C "$temporary/destination" >/dev/null
/usr/bin/cmp "$temporary/source/probe.txt" "$temporary/destination/probe.txt"

print "Bundle admission passed: $bundle"
