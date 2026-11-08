#!/bin/zsh
set -euo pipefail

daemon="${0:a:h:h}"
temporary="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/vphone-display-layout-tests.XXXXXX")"
trap '/bin/rm -rf "$temporary"' EXIT

/usr/bin/xcrun --sdk macosx clang -fobjc-arc -fblocks -Wall -Wextra -Werror \
    "$daemon/Tests/DisplayLayoutAdmissionTests.m" "$daemon/Native/vphoned_display.m" \
    -framework Foundation -framework IOKit -framework CoreGraphics \
    -o "$temporary/display-layout-tests"
"$temporary/display-layout-tests"
