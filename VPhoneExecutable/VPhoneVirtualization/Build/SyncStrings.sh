#!/bin/zsh
# vphone-tier: build
set -euo pipefail

# Sync from the compiler's own string tables (SWIFT_EMIT_LOC_STRINGS), not from
# `xcstringstool extract`. The syntax-only extractor cannot see types, so it keys
# every interpolation as `%arg`, while `String(localized:)` looks up `%@`/`%lld`
# at runtime. Syncing from its output grew untranslated `%arg` twins of real keys.
root="$(cd "${0:a:h}/../../.." && pwd)"
catalog="$root/VPhoneExecutable/VPhoneVirtualization/Resources/Localizable.xcstrings"
objects="${CONFIGURATION_TEMP_DIR:?}"

data_files=("$objects"/VPhoneVirtualMachineKit.build/Objects-normal/*/*.stringsdata(N)
    "$objects"/vphone-vm.build/Objects-normal/*/*.stringsdata(N))
if (( ${#data_files} )); then
    arguments=()
    for file in "${data_files[@]}"; do
        arguments+=(--stringsdata "$file")
    done
    /usr/bin/xcrun xcstringstool sync "$catalog" "${arguments[@]}" --skip-marking-strings-stale
fi
