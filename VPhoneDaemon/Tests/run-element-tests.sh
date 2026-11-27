#!/bin/zsh
set -euo pipefail

daemon="${0:a:h:h}"
temporary="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/vphone-element-tests.XXXXXX")"
trap '/bin/rm -rf "$temporary"' EXIT

source="$daemon/Native/vphoned_ax_element.m"
tests="$daemon/Tests/ElementTests.m"

/usr/bin/xcrun --sdk macosx clang -fobjc-arc \
    -fprofile-instr-generate -fcoverage-mapping \
    -framework Foundation -framework CoreGraphics \
    "$tests" "$source" "$daemon/Native/vphoned_ax_hierarchy.m" -o "$temporary/element-tests"

LLVM_PROFILE_FILE="$temporary/element.profraw" "$temporary/element-tests"

/usr/bin/xcrun llvm-profdata merge -sparse "$temporary/element.profraw" \
    -o "$temporary/element.profdata"
/usr/bin/xcrun llvm-cov report "$temporary/element-tests" \
    -instr-profile="$temporary/element.profdata" "$source"
