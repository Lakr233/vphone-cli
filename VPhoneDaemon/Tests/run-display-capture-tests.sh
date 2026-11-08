#!/bin/zsh
set -euo pipefail

daemon="${0:a:h:h}"
temporary="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/vphone-display-capture-tests.XXXXXX")"
trap '/bin/rm -rf "$temporary"' EXIT

/usr/bin/xcrun --sdk macosx clang -fobjc-arc -fblocks -Wall -Wextra -Werror \
    "$daemon/Tests/DisplayCaptureTests.m" \
    -framework Foundation -framework IOKit -framework CoreGraphics -framework IOSurface -framework ImageIO \
    -o "$temporary/display-capture-tests"
"$temporary/display-capture-tests"
