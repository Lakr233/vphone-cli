#!/bin/zsh
set -euo pipefail

daemon="${0:a:h:h}"
temporary="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/vphone-photos-tests.XXXXXX")"
trap '/bin/rm -rf "$temporary"' EXIT

/usr/bin/xcrun --sdk macosx clang -fobjc-arc -g \
    -Wall -Wextra -Werror -Wno-unused-parameter -Wno-incompatible-pointer-types \
    -fsanitize=undefined \
    -framework Foundation \
    "$daemon/Tests/PhotosImportTests.m" -o "$temporary/photos-tests"

VP_PHOTOS_TEST_ROOT="$temporary/jobs" "$temporary/photos-tests"
