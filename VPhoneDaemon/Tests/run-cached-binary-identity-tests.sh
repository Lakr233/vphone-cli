#!/bin/zsh
set -euo pipefail

tests="${0:a:h}"
temporary="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/vphone-cache-identity-tests.XXXXXX")"
trap '/bin/rm -rf "$temporary"' EXIT

${CC:-cc} -std=gnu11 -Wall -Wextra -Werror \
    "$tests/CachedBinaryIdentityTests.c" \
    -o "$temporary/cached-binary-identity-tests"

"$temporary/cached-binary-identity-tests"
