#!/bin/zsh
set -euo pipefail

root=${0:a:h:h:h}
temporary=$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/vphone-notice-release-gate.XXXXXX")
trap '/bin/rm -rf "$temporary"' EXIT
collector="$root/scripts/stage-package-notices.zsh"
revision=1111111111111111111111111111111111111111
destination="$temporary/notices"
/bin/mkdir -p "$destination/fixture/$revision/checkout"
print -r -- 'Fixture copyright and license' > "$destination/fixture/$revision/checkout/LICENSE"
digest=$(/usr/bin/shasum -a 256 "$destination/fixture/$revision/checkout/LICENSE" | /usr/bin/awk '{print $1}')
printf 'fixture\t%s\tcheckout\tLICENSE\t%s\n' "$revision" "$digest" > "$temporary/complete.tsv"
/bin/cp "$temporary/complete.tsv" "$destination/manifest.tsv"
"$collector" --check "$destination" --require-notices

for kind in missing artifact_missing; do
    /bin/cp "$temporary/complete.tsv" "$destination/manifest.tsv"
    printf 'uncovered\t%s\t%s\t-\t-\n' "$revision" "$kind" >> "$destination/manifest.tsv"
    "$collector" --check "$destination"
    if "$collector" --check "$destination" --require-notices; then
        print -u2 "$kind unexpectedly passed the distribution gate"
        exit 1
    fi
done

/bin/cp "$temporary/complete.tsv" "$destination/manifest.tsv"
for option in --require-notice ''; do
    if "$collector" --check "$destination" "$option"; then
        print -u2 'An unknown or empty validation option unexpectedly passed'
        exit 1
    fi
done
print 'Package notice release gate: complete notices accepted; missing notices and unknown options refused'
