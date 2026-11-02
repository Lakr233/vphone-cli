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
# The terminal reads these through Bundle.module, which searches
# VPhone.bundle's Contents/Resources and root, never Contents/MacOS, and traps
# when it finds nothing. A missing or misplaced resource bundle is therefore
# not a degraded terminal but a crash on opening one, and it carries no
# Mach-O, so no other check here would notice it had gone.
for name in Ghostty terminfo; do
    [[ -d "$resources/GhosttyKit_GhosttyTerminal.bundle/Contents/Resources/$name" ]] || {
        print -u2 "The Ghostty resource bundle in Contents/Resources has no $name directory"
        exit 1
    }
done
require_signed_macho "$location_helper"
/usr/bin/codesign --verify --strict "$location_app"
# One requirement for every build, so locationd keeps one grant for all of
# them (see StageBundle.sh).
[[ "$(/usr/bin/codesign -d -r- "$location_app" 2>/dev/null)" == *'designated => identifier "com.vphone.bundle.location"' ]] || {
    print -u2 "VPhoneLocation.app does not carry its identifier requirement"
    exit 1
}
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
# Every kernelcache recipe has its symbol map and bundle list, and its donor.
for manifest in "$resources/kernelcache_recipes/bases/"*/manifest.json; do
    recipe=${manifest:h}
    for key in symbols kexts; do
        file=$(/usr/bin/plutil -extract $key raw -o - "$manifest") || { print -u2 "Malformed kernelcache recipe: ${recipe:t}"; exit 1; }
        [[ -s "$recipe/$file" ]] || { print -u2 "Kernelcache recipe ${recipe:t} lacks $file"; exit 1; }
    done
    # The donor, or the kext sources in order (the base and donors).
    donors=()
    if count=$(/usr/bin/plutil -extract sources raw -o - "$manifest" 2>/dev/null); then
        for (( i = 0; i < count; i++ )); do
            source=$(/usr/bin/plutil -extract sources.$i raw -o - "$manifest")
            [[ $source == base ]] || donors+=($source)
        done
    else
        donors=($(/usr/bin/plutil -extract donor raw -o - "$manifest"))
    fi
    for donor in $donors; do
        [[ -s "$resources/kernelcache_recipes/donors/$donor/manifest.json" ]] || {
            print -u2 "Kernelcache recipe ${recipe:t} names a missing donor: $donor"
            exit 1
        }
    done
done
[[ -s "$resources/Licenses/native-kdk-MIT.txt" ]] || {
    print -u2 "Missing native KDK extraction licence"
    exit 1
}
# New machines copy this ROM. Without it vm new would fail, and OpenAVB is
# distributed only with its licences. The ROM window is 512 KiB.
for name in OpenAVB.bin LICENSE APSL-2.0.txt; do
    [[ -s "$resources/OpenAVB/$name" ]] || { print -u2 "Missing Contents/Resources/OpenAVB/$name"; exit 1; }
done
(( $(/usr/bin/stat -f %z "$resources/OpenAVB/OpenAVB.bin") <= 0x80000 )) || {
    print -u2 "OpenAVB.bin is larger than the 512 KiB ROM window"
    exit 1
}
/usr/bin/grep -q 'OpenBootROM:' "$resources/OpenAVB/OpenAVB.bin" || {
    print -u2 "Contents/Resources/OpenAVB/OpenAVB.bin is not an OpenAVB image"
    exit 1
}
# The SEP ROM new machines copy, and its licence. The SEP ROM window is
# 0x29000 bytes. Apple's AVPSEPBooter carries its version string and OpenSEP
# none, which is how a machine's SEP ROM is told apart (VPhoneSEPROM).
for name in OpenSEP.bin LICENSE; do
    [[ -s "$resources/OpenSEP/$name" ]] || { print -u2 "Missing Contents/Resources/OpenSEP/$name"; exit 1; }
done
(( $(/usr/bin/stat -f %z "$resources/OpenSEP/OpenSEP.bin") <= 0x29000 )) || {
    print -u2 "OpenSEP.bin is larger than the 0x29000-byte SEP ROM window"
    exit 1
}
if /usr/bin/grep -q 'AVPSEPBooter-' "$resources/OpenSEP/OpenSEP.bin"; then
    print -u2 "Contents/Resources/OpenSEP/OpenSEP.bin is Apple's AVPSEPBooter, not OpenSEP"
    exit 1
fi

for name in vphoned vphoned-tvos vphoned-watchos libvphonetvsetupfocus.dylib libswiftCompatibilitySpan.dylib launchdhook-vphone.dylib SystemHook-vphone.dylib libcamfix.dylib \
    libvcamcaptured.dylib libmisfix.dylib libhapticsfix.dylib libbatteryhealthfix.dylib libdevicehubfix.dylib libdevicename.dylib \
    libprefsfix.dylib libsigninfix.dylib libvphoneios17desktop.dylib libvphonegyro.dylib libvphoneaccelerometer.dylib libvphonehinge.dylib libvphonefoldguard.dylib libvphonefolddisplay.dylib libvphoneattitude.dylib libvphonehomepoddisplay.dylib libvphonecryptexstaging.dylib libvphoneinstallpersona.dylib libvphonehomepodmisfix.dylib vphone-homepod-setup libAppleParavirtCompilerPluginIOGPUFamily.dylib; do
    require_signed_macho "$guest/$name"
done
# iOS 18 must be able to resolve the compatibility library without Xcode.
# /usr/lib/swift remains first for guests whose standard library has Span.
daemon_rpaths="$(/usr/bin/otool -l "$guest/vphoned" | /usr/bin/awk '
    $2 == "LC_RPATH" { rpath = 1; next }
    rpath && $1 == "path" { print $2; rpath = 0 }
')"
[[ "${daemon_rpaths%%$'\n'*}" == /usr/lib/swift &&
   "$daemon_rpaths" == *$'\n/usr/lib/vphone' ]] || {
    print -u2 "vphoned must search system Swift libraries before its bundled fallback"
    exit 1
}
/usr/bin/otool -L "$guest/vphoned" | /usr/bin/awk 'NR > 1 {print $1}' |
    /usr/bin/grep -Fx '@rpath/libswiftCompatibilitySpan.dylib' >/dev/null || {
        print -u2 "vphoned does not use the bundled Span compatibility library"
        exit 1
    }
# The scripting session runs on JavaScriptCore, which watchOS does not ship.
# IcliKit's probe opens it at run time, so the daemon names no JavaScriptCore
# symbol; a reference would leave the watch guest without a daemon at all.
for daemon in vphoned vphoned-tvos vphoned-watchos; do
    javascriptcore_loads="$(/usr/bin/otool -l "$guest/$daemon" | /usr/bin/awk '
        $1 == "cmd" { command = $2 }
        $1 == "name" && $2 ~ /JavaScriptCore/ { print command }
    ' | /usr/bin/sort -u)"
    [[ -z "$javascriptcore_loads" ]] || {
        print -u2 "$daemon must not link JavaScriptCore, which the probe opens at run time: $javascriptcore_loads"
        exit 1
    }
done
for name in vphoned.plist libcamfix.plist libvcamcaptured.plist libmisfix.plist com.vphone.homepod-setup.plist; do
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
        "$guest/vphoned-tvos"|"$guest/libvphonetvsetupfocus.dylib"|"$guest/libvphonehomepoddisplay.dylib"|"$guest/libvphonecryptexstaging.dylib"|"$guest/libvphoneinstallpersona.dylib"|"$guest/libvphonehomepodmisfix.dylib"|"$guest/vphone-homepod-setup")
            # tvOS dyld refuses an iOS-platform daemon on an Apple TV guest.
            [[ "$platform" == TVOS ]] || { print -u2 "Non-tvOS binary: ${file#$bundle/}"; exit 1; }
            ;;
        "$guest/vphoned-watchos")
            [[ "$platform" == WATCHOS ]] || { print -u2 "Non-watchOS binary: ${file#$bundle/}"; exit 1; }
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
for daemon in vphoned vphoned-tvos vphoned-watchos; do
    daemon_entitlements="$(/usr/bin/codesign -d --entitlements - --xml "$guest/$daemon" 2>/dev/null)"
    [[ "$daemon_entitlements" == *'com.apple.CommCenter.fine-grained'* &&
        "$daemon_entitlements" != *'com.apple.private.virtualization'* ]] || {
        print -u2 "$daemon has the wrong entitlements"
        exit 1
    }
done
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
