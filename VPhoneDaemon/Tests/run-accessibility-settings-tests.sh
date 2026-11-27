#!/bin/zsh
set -euo pipefail

daemon="${0:a:h:h}"
temporary="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/vphone-accessibility-settings-tests.XXXXXX")"
trap '/bin/rm -rf "$temporary"' EXIT

source="$daemon/Native/vphoned_ax_settings.m"
tests="$daemon/Tests/AccessibilitySettingsTests.m"

/usr/bin/xcrun --sdk macosx clang -fobjc-arc \
    -fprofile-instr-generate -fcoverage-mapping \
    -framework Foundation \
    "$tests" "$source" -o "$temporary/accessibility-settings-tests"

LLVM_PROFILE_FILE="$temporary/settings.profraw" "$temporary/accessibility-settings-tests"

/usr/bin/xcrun llvm-profdata merge -sparse "$temporary/settings.profraw" \
    -o "$temporary/settings.profdata"
/usr/bin/xcrun llvm-cov report "$temporary/accessibility-settings-tests" \
    -instr-profile="$temporary/settings.profdata" "$source"
