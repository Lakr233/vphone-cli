#!/bin/zsh
# vphone-tier: build
set -euo pipefail

root="$(cd "${0:a:h}/../../.." && pwd)"
bundle="${1:-$root/.build/XcodeBundle/Build/Products/Debug/VPhone.bundle}"
macos="$bundle/Contents/MacOS"
resources="$bundle/Contents/Resources"

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

for name in vphone-vm vphone-cli VPhoneEscalator vphoned vphoned.signed \
    libswiftCompatibilitySpan.vphone.dylib libcamfix.dylib libvcamcaptured.dylib \
    launchdhook-vphone.dylib SystemHook-vphone.dylib \
    libAppleParavirtCompilerPluginIOGPUFamily.dylib; do
    [[ -f "$macos/$name" ]] || { print -u2 "Missing binary: Contents/MacOS/$name"; exit 1; }
    /usr/bin/file "$macos/$name" | /usr/bin/grep -q 'Mach-O' || {
        print -u2 "Not a Mach-O: $name"
        exit 1
    }
    /usr/bin/codesign --verify "$macos/$name" || {
        print -u2 "Invalid signature: $name"
        exit 1
    }
done

for name in vphone-app VPhoneAMFIAllow vphone-archive icli vpregister vphone-ask-for-permission; do
    [[ ! -e "$macos/$name" ]] || { print -u2 "Obsolete binary: $name"; exit 1; }
done

for name in vphoned.plist VPhoneDaemon.entitlements; do
    [[ -f "$resources/scripts/vphoned/$name" ]] || {
        print -u2 "Missing guest configuration: $name"
        exit 1
    }
done

/usr/bin/codesign --verify --strict "$bundle"
/usr/bin/codesign --verify "$macos/vphone-vm"
/usr/bin/codesign --verify "$macos/vphone-cli"
/usr/bin/codesign --verify "$macos/VPhoneEscalator"
/usr/bin/codesign --verify "$macos/vphoned.signed"

[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundlePackageType' "$bundle/Contents/Info.plist")" == "BNDL" ]] || {
    print -u2 "The product is not a generic bundle"
    exit 1
}
if /usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$bundle/Contents/Info.plist" >/dev/null 2>&1; then
    print -u2 "The container must not declare an executable"
    exit 1
fi
while IFS= read -r file; do
    if /usr/bin/file "$file" | /usr/bin/grep -q 'Mach-O' && [[ "$file" != "$macos/"* ]]; then
        print -u2 "Mach-O outside Contents/MacOS: $file"
        exit 1
    fi
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
daemon_entitlements="$(/usr/bin/codesign -d --entitlements - --xml "$macos/vphoned.signed" 2>/dev/null)"
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
