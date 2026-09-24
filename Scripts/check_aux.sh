#!/bin/zsh
# vphone-tier: build
set -euo pipefail

root="${0:a:h:h}"
bundle="${1:-$root/.build/XcodeApp/Build/Products/Debug/vphone-app.app}"
macos="$bundle/Contents/MacOS"
resources="$bundle/Contents/Resources"

[[ -d "$bundle" ]] || { print -u2 "Missing Xcode app: $bundle"; exit 1; }

for name in vphone-vm vphone-cli VPhoneEscalator vphoned vphoned.signed \
    vpregister libcamfix.dylib libvcamcaptured.dylib TweakLoader.dylib \
    libAppleParavirtCompilerPluginIOGPUFamily.dylib; do
    [[ -f "$macos/$name" ]] || { print -u2 "Missing binary: Contents/MacOS/$name"; exit 1; }
    /usr/bin/file "$macos/$name" | /usr/bin/grep -q 'Mach-O' || {
        print -u2 "Not a Mach-O: $name"
        exit 1
    }
done

for name in vphone-archive icli vphone-ask-for-permission vphone-amfi-allow; do
    [[ ! -e "$macos/$name" ]] || { print -u2 "Obsolete binary: $name"; exit 1; }
done

for name in vphoned.plist entitlements.plist; do
    [[ -f "$resources/scripts/vphoned/$name" ]] || {
        print -u2 "Missing guest configuration: $name"
        exit 1
    }
done

/usr/bin/codesign --verify --strict "$bundle"
/usr/bin/codesign --verify "$macos/vphone-cli"
/usr/bin/codesign --verify "$macos/VPhoneEscalator"
/usr/bin/codesign --verify "$macos/vphoned.signed"

entitlements="$(/usr/bin/codesign -d --entitlements - --xml "$bundle" 2>/dev/null)"
[[ "$entitlements" == *'com.apple.private.virtualization'* ]] || {
    print -u2 "VM private entitlements are missing"
    exit 1
}

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
