#!/bin/zsh
# vphone-tier: build
set -euo pipefail

root="$(cd "${0:a:h}/../../.." && pwd)"
catalog="$root/VPhoneExecutable/VPhoneVirtualization/Resources/Localizable.xcstrings"
stringsdata="$root/.build/localization-stringsdata"
sources=("$root"/VPhoneExecutable/VPhoneVirtualization/UI/**/*.swift(N))

/bin/mkdir -p "$stringsdata"
/bin/rm -f "$stringsdata"/*.stringsdata(N)
/usr/bin/xcrun xcstringstool extract \
    --SwiftUI --legacy-localizable-strings --modern-localizable-strings \
    "${sources[@]}" --output-directory "$stringsdata"
data_files=("$stringsdata"/*.stringsdata(N))
if (( ${#data_files} )); then
    arguments=()
    for file in "${data_files[@]}"; do
        arguments+=(--stringsdata "$file")
    done
    /usr/bin/xcrun xcstringstool sync "$catalog" "${arguments[@]}" --skip-marking-strings-stale
fi
