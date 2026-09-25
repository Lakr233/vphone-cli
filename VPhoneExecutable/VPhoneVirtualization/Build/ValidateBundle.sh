#!/bin/zsh
# vphone-tier: build
set -euo pipefail

root="$(cd "${0:a:h}/../../.." && pwd)"
bundle="${1:-$root/.build/XcodeBundle/Build/Products/Debug/VPhone.bundle}"
macos="$bundle/Contents/MacOS"
resources="$bundle/Contents/Resources"
guest="$resources/guest-resources"

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
    /usr/bin/file "$file" | /usr/bin/grep -q 'Mach-O' || {
        print -u2 "Not a Mach-O: ${file#$bundle/}"
        exit 1
    }
    /usr/bin/codesign --verify "$file" || {
        print -u2 "Invalid signature: ${file#$bundle/}"
        exit 1
    }
}

for name in vphone-vm vphone-cli VPhoneEscalator libswiftCompatibilitySpan.vphone.dylib; do
    require_signed_macho "$macos/$name"
done
for name in vphoned launchdhook-vphone.dylib SystemHook-vphone.dylib libcamfix.dylib \
    libvcamcaptured.dylib libAppleParavirtCompilerPluginIOGPUFamily.dylib; do
    require_signed_macho "$guest/$name"
done
for name in vphoned.plist libcamfix.plist libvcamcaptured.plist; do
    [[ -f "$guest/$name" ]] || { print -u2 "Missing guest configuration: $name"; exit 1; }
done

for name in vphoned vphoned.signed vphone-app VPhoneAMFIAllow vphone-archive icli vpregister \
    vphone-ask-for-permission libcamfix.dylib libvcamcaptured.dylib launchdhook-vphone.dylib \
    SystemHook-vphone.dylib libAppleParavirtCompilerPluginIOGPUFamily.dylib; do
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
    /usr/bin/file "$file" | /usr/bin/grep -q 'Mach-O' || continue
    platform="$(/usr/bin/vtool -show-build "$file" 2>/dev/null | /usr/bin/awk '$1 == "platform" {print $2; exit}')"
    case "$file" in
        "$macos/"*)
            [[ "$platform" != IOS ]] || { print -u2 "iOS binary in Contents/MacOS: ${file#$bundle/}"; exit 1; }
            ;;
        "$guest/"*)
            [[ "$platform" == IOS ]] || { print -u2 "Non-iOS binary in guest-resources: ${file#$bundle/}"; exit 1; }
            ;;
        *)
            print -u2 "Mach-O outside Contents/MacOS and guest-resources: ${file#$bundle/}"
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
for name in vphone-cli VPhoneEscalator; do
    process_entitlements="$(/usr/bin/codesign -d --entitlements - --xml "$macos/$name" 2>/dev/null || true)"
    [[ "$process_entitlements" != *'com.apple.private.virtualization'* &&
        "$process_entitlements" != *'com.apple.CommCenter.fine-grained'* ]] || {
        print -u2 "Unexpected private entitlements on $name"
        exit 1
    }
done

for name in vphone-vm vphone-cli VPhoneEscalator; do
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
