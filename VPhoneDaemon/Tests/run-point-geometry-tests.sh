#!/bin/zsh
set -euo pipefail

daemon="${0:a:h:h}"
root="${daemon:h}"
icli="$root/.build/XcodeBundle/SourcePackages/checkouts/icli"
input="$daemon/Daemon/GuestAPI+Input.swift"
host="$root/VPhoneExecutable/VPhoneVirtualization/UI/GuestCommunication/VPhoneGuestControlSystem.swift"
while (( $# )); do
    case "$1" in
        --icli) icli=$2; shift 2 ;;
        --input-source) input=$2; shift 2 ;;
        --host-source) host=$2; shift 2 ;;
        *) print -u2 "Unknown option: $1"; exit 2 ;;
    esac
done
icli=${icli:A}
pin=$(jq -r '.pins[] | select(.identity == "icli") | .state.revision' "$daemon/VPhoneDaemon.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved")
[[ $(git -C "$icli" rev-parse HEAD) == "$pin" ]] || { print -u2 'Icli checkout does not match the consumer pin'; exit 1; }
temporary="$(mktemp -d "${TMPDIR:-/tmp}/vphone-point-geometry-tests.XXXXXX")"
trap 'rm -rf "$temporary"' EXIT
print -r -- "module IcliPrivate { header \"$icli/Sources/IcliPrivate/include/IcliInterfaceGeometry.h\" export * }" > "$temporary/module.modulemap"
compiler=("${SWIFTC:-swiftc}")
cc=("${CC:-clang}")
if [[ -x /usr/bin/xcrun ]]; then compiler=(/usr/bin/xcrun --sdk macosx swiftc); cc=(/usr/bin/xcrun --sdk macosx clang); fi
extension=so
[[ $(uname -s) == Darwin ]] && extension=dylib
"${cc[@]}" -std=c11 -fPIC -Wall -Wextra -Werror -I"$icli/Sources/IcliPrivate/include" -c "$icli/Sources/IcliPrivate/InterfaceGeometry.c" -o "$temporary/geometry.o"
flags=(-swift-version 6 -warnings-as-errors -module-cache-path "$temporary/modules" -I "$temporary" -L "$temporary")
"${compiler[@]}" "${flags[@]}" -emit-library -emit-module -module-name IcliKit \
    "$icli/Sources/IcliKit/Input/InterfaceGeometry.swift" "$daemon/Tests/PointGeometry/IcliTestSupport.swift" \
    "$temporary/geometry.o" -o "$temporary/libIcliKit.$extension"
"${compiler[@]}" "${flags[@]}" -emit-library -emit-module -module-name VphonedNative \
    "$daemon/Tests/PointGeometry/NativeTestSupport.swift" -o "$temporary/libVphonedNative.$extension"
"${compiler[@]}" "${flags[@]}" -parse-as-library -lIcliKit -lVphonedNative -Xlinker -rpath -Xlinker "$temporary" \
    "$daemon/Daemon/GuestMethodSpec.swift" "$daemon/Daemon/GuestPointGeometry.swift" \
    "$daemon/Daemon/GuestAPI+PointGeometry.swift" "$input" "$daemon/Tests/PointGeometry/PointGeometryTests.swift" \
    -o "$temporary/point-tests"
"$temporary/point-tests"
cat "$host" "$daemon/Tests/PointGeometry/HostLockTests.swift" > "$temporary/HostLockTests.swift"
"${compiler[@]}" "${flags[@]}" -parse-as-library "$temporary/HostLockTests.swift" -o "$temporary/lock-tests"
"$temporary/lock-tests"
