#!/bin/zsh
set -euo pipefail

# Runs the ResultSchemaCheck package tests: extractor fixtures compared to their
# expected catalog-format `result` cells. No guest is needed.

package="${0:a:h}/ResultSchema"
exec /usr/bin/xcrun swift test --package-path "$package" "$@"
