#!/bin/zsh
set -euo pipefail

root=${0:a:h:h:h}
temporary=$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/vphone-package-notices.XXXXXX")
trap '/bin/rm -rf "$temporary"' EXIT
packages="$temporary/SourcePackages"
/bin/mkdir -p "$packages/checkouts" "$packages/artifacts/fixture/Fake.xcframework/Licenses"
/usr/bin/git clone --quiet --shared --no-checkout "$root" "$packages/checkouts/fixture"
revision=$(/usr/bin/git -C "$root" rev-parse HEAD)
printf '{"pins":[{"identity":"fixture","state":{"revision":"%s"}}]}' "$revision" > "$temporary/pins.json"
print -r -- 'nested dependency attribution' > "$packages/artifacts/fixture/Fake.xcframework/Licenses/dependency.txt"
print -r -- 'binary payload must stay outside the notice set' > "$packages/artifacts/fixture/Fake.xcframework/payload.bin"
collector="$root/scripts/stage-package-notices.zsh"
"$collector" "$temporary/notices" "$temporary/pins.json" "$packages"
/usr/bin/git -C "$root" show "$revision:LICENSE" |
    /usr/bin/cmp - "$temporary/notices/fixture/$revision/checkout/LICENSE"
/usr/bin/cmp "$packages/artifacts/fixture/Fake.xcframework/Licenses/dependency.txt" \
    "$temporary/notices/fixture/$revision/artifacts-${packages:h:t}/Fake.xcframework/Licenses/dependency.txt"
[[ ! -e "$temporary/notices/fixture/$revision/artifacts-${packages:h:t}/Fake.xcframework/payload.bin" ]]
/bin/rm "$packages/artifacts/fixture/Fake.xcframework/Licenses/dependency.txt"
"$collector" "$temporary/notices" "$temporary/pins.json" "$packages"
[[ ! -e "$temporary/notices/fixture/$revision/artifacts-${packages:h:t}/Fake.xcframework/Licenses/dependency.txt" ]]
print -r -- 'changed' >> "$temporary/notices/fixture/$revision/checkout/LICENSE"
if "$collector" --check "$temporary/notices"; then
    print -u2 'Changed notice unexpectedly passed admission'
    exit 1
fi
/usr/bin/sed "s/$revision/0000000000000000000000000000000000000000/" "$temporary/pins.json" > "$temporary/stale.json"
if "$collector" "$temporary/stale-notices" "$temporary/stale.json" "$packages"; then
    print -u2 'Checkout with a stale pin unexpectedly passed admission'
    exit 1
fi
print 'Package notices: pinned bytes, nested notices, payload exclusion, fresh output and admission passed'
