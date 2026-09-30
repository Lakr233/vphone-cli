#!/bin/zsh
set -euo pipefail

daemon="${0:a:h:h}"
root="${daemon:h}"
packages="${VPHONE_SOURCE_PACKAGES:-$root/.build/XcodeBundle/SourcePackages}"
icli="${VPHONE_ICLI_CHECKOUT:-$packages/checkouts/icli}"
archives=("$packages"/artifacts/libarchive.xcframework/**/macos-arm64_x86_64/libarchive.framework/Versions/A/libarchive(N))
archive="${VPHONE_LIBARCHIVE_BINARY:-${archives[1]:-}}"
if [[ ! -f "$icli/Sources/IcliPrivate/Archive.m" || ! -f "$archive" ]]; then
    print -u2 'Build the VPhone scheme first to resolve the pinned Icli and libarchive dependencies.'
    exit 1
fi
headers="${archive:h}/Headers"
temporary="$(/usr/bin/mktemp -d)"
trap '/bin/rm -rf "$temporary"' EXIT
mkdir -p "$temporary/include/libarchive"
cp "$headers/archive.h" "$headers/archive_entry.h" "$temporary/include/libarchive/"

# Compile the actual pinned extractor and its real headers, not a replacement
# reader. Its iOS-only app registration/signing operations are not linked here.
/usr/bin/xcrun clang -fobjc-arc -Wall -Wextra \
    -I"$temporary/include" -I"$icli/Sources/IcliPrivate/include" \
    -I"$icli/Sources/IcliSystemPrivate/include" \
    -c "$icli/Sources/IcliPrivate/Archive.m" -o "$temporary/archive.o"
/usr/bin/xcrun swiftc -swift-version 6 -strict-concurrency=complete \
    -warnings-as-errors -parse-as-library -module-cache-path "$temporary/modules" \
    -import-objc-header "$daemon/Tests/ArchiveLocaleBridge.h" \
    "$daemon/Daemon/GuestArchiveLocale.swift" "$daemon/Tests/ArchiveLocaleTests.swift" \
    "$temporary/archive.o" "$archive" -framework Foundation \
    -lz -lbz2 -liconv -lxml2 -o "$temporary/archive-locale-tests"
"$temporary/archive-locale-tests"
