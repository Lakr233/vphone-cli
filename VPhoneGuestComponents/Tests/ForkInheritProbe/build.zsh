#!/bin/zsh
# Build and sign the fork probes for a vphone guest.
#
#   build.zsh <output dir> [frida-gum devkit dir]
#
# Writes forkprobe-plain and forkprobe-inherit (the same binary signed with
# entitlements-plain.plist, the fuzz loader's set without
# com.apple.private.cs.debugger, and entitlements-inherit.plist, the loader's set
# as it is, debugger key included), and, with a devkit,
# forkgum-plain and forkgum-inherit. The target is arm64e, like the loader.
#
# Signed with Apple's `codesign -s -`, not ldid or `vphone-cli sign`: those
# write the DER entitlements sorted by encoded length, and the kernel's
# CoreEntitlements lookup is a lexicographic binary search, so it misses some
# keys. See
# Research/KernelCustomFirmwarePatches/patch_fork_inherit_invalid_code.md.
set -euo pipefail
cd "${0:a:h}"
output=${1:?Pass an absolute output directory}
devkit=${2:-}
mkdir -p "$output"
sdk=$(xcrun --sdk iphoneos --show-sdk-path)
target=(-target arm64e-apple-ios17.4 -isysroot "$sdk")

xcrun --sdk iphoneos clang -O1 -Wall "${target[@]}" forkprobe.c -o "$output/forkprobe"
for flavour in plain inherit; do
  cp "$output/forkprobe" "$output/forkprobe-$flavour"
  codesign -f -s - --entitlements "entitlements-$flavour.plist" "$output/forkprobe-$flavour"
done

if [[ -n "$devkit" ]]; then
  xcrun --sdk iphoneos clang -O1 -Wall "${target[@]}" -I"$devkit" forkgum.c \
    -L"$devkit" -lfrida-gum -lresolv -lc++ -framework Foundation -framework CoreFoundation \
    -Wl,-dead_strip -o "$output/forkgum"
  for flavour in plain inherit; do
    cp "$output/forkgum" "$output/forkgum-$flavour"
    codesign -f -s - --entitlements "entitlements-$flavour.plist" "$output/forkgum-$flavour"
  done
fi
ls -la "$output"
