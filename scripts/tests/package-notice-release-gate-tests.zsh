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

# An excepted package is admitted only for an artifact without notices, and
# only at the revision its exception names.
other=2222222222222222222222222222222222222222
printf '# comment\nuncovered\t%s\thttps://example.invalid/fix\n' "$revision" > "$temporary/exceptions.tsv"
export VPHONE_NOTICE_EXCEPTIONS="$temporary/exceptions.tsv"
/bin/cp "$temporary/complete.tsv" "$destination/manifest.tsv"
printf 'uncovered\t%s\tartifact_missing\t-\t-\n' "$revision" >> "$destination/manifest.tsv"
"$collector" --check "$destination" --require-notices
for row in "uncovered	$other	artifact_missing" "uncovered	$revision	missing" "other	$revision	artifact_missing"; do
    /bin/cp "$temporary/complete.tsv" "$destination/manifest.tsv"
    printf '%s\t-\t-\n' "$row" >> "$destination/manifest.tsv"
    if "$collector" --check "$destination" --require-notices; then
        print -u2 "An unexcepted row unexpectedly passed the distribution gate: $row"
        exit 1
    fi
done
unset VPHONE_NOTICE_EXCEPTIONS

# Every committed exception names a package pinned at exactly that revision.
while IFS=$'\t' read -r identity pinned tracked; do
    [[ -n $identity && $identity != \#* ]] || continue
    [[ $tracked == https://* ]] || { print -u2 "Exception for $identity names no tracking link"; exit 1; }
    /usr/bin/grep -q "\"identity\" : \"$identity\"" "$root/VPhone.xcworkspace/xcshareddata/swiftpm/Package.resolved" \
        || { print -u2 "Exception for $identity, which is not a package"; exit 1; }
    /usr/bin/grep -rq --include=Package.resolved "\"revision\" : \"$pinned\"" "$root/VPhone.xcworkspace" "$root/VPhoneLaunchpad" "$root/VPhoneExecutable" "$root/VPhoneKit" "$root/VPhoneDaemon" \
        || { print -u2 "Exception for $identity at $pinned, which is no longer pinned; remove it"; exit 1; }
done < "$root/scripts/package-notice-exceptions.tsv"
print 'Package notice release gate: complete notices accepted; missing notices and unknown options refused; exceptions admit only their pinned artifact rows'
