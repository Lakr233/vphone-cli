#!/bin/zsh
# vphone-tier: build
set -euo pipefail

destination=${2:-}
if [[ ${1:-} == --check ]]; then
    [[ -s "$destination/manifest.tsv" ]] || { print -u2 'Missing package notice manifest'; exit 1; }
    while IFS=$'\t' read -r identity revision kind relative digest; do
        if [[ $kind == (missing|artifact_missing) ]]; then
            print -u2 "No $kind notice file supplied by $identity at $revision"
            continue
        fi
        file="$destination/$identity/$revision/$kind/$relative"
        [[ -s $file && $(/usr/bin/shasum -a 256 "$file" | /usr/bin/awk '{print $1}') == $digest ]] || {
            print -u2 "Missing or changed package notice: $identity/$relative"
            exit 1
        }
    done < "$destination/manifest.tsv"
    exit 0
fi

destination=${1:?usage: stage-package-notices.zsh destination resolved source-packages [resolved source-packages ...]}
shift
(( $# > 0 && $# % 2 == 0 )) || { print -u2 'Expected resolved/source-packages pairs'; exit 1; }
/bin/mkdir -p "$destination"
manifest="$destination/manifest.tsv"
: > "$manifest"

is_notice() {
    local relative=${1:l}
    [[ ${relative:t} == (license*|licence*|copying*|notice*|*third*party*notice*)
        || /$relative == */(licenses|licences|notices)/* ]]
}

record_notice() {
    local identity=$1 revision=$2 kind=$3 relative=$4
    local target="$destination/$identity/$revision/$kind/$relative"
    /bin/mkdir -p "${target:h}"
    /bin/cat > "$target"
    [[ -s $target ]] || { /bin/rm "$target"; return; }
    local digest=$(/usr/bin/shasum -a 256 "$target" | /usr/bin/awk '{print $1}')
    printf '%s\t%s\t%s\t%s\t%s\n' "$identity" "$revision" "$kind" "$relative" "$digest" >> "$manifest"
}

package_directory() {
    local parent=$1 identity=$2 candidate
    for candidate in "$parent"/*(N/); do
        [[ ${candidate:t:l} == $identity ]] && { print -r -- "$candidate"; return; }
    done
    return 1
}

while (( $# )); do
    resolved=$1
    packages=$2
    shift 2
    count=$(/usr/bin/plutil -extract pins raw -o - "$resolved")
    for (( i = 0; i < count; i++ )); do
        identity=$(/usr/bin/plutil -extract pins.$i.identity raw -o - "$resolved")
        revision=$(/usr/bin/plutil -extract pins.$i.state.revision raw -o - "$resolved")
        checkout=$(package_directory "$packages/checkouts" "$identity") || {
            print -u2 "Missing package checkout: $identity"
            exit 1
        }
        [[ $(/usr/bin/git -C "$checkout" rev-parse HEAD) == $revision ]] || {
            print -u2 "Package checkout does not match its pin: $identity"
            exit 1
        }
        found=0
        # Read committed blobs, preserving exact pinned bytes and nested paths.
        while IFS= read -r -d '' entry; do
            metadata=${entry%%$'\t'*}
            relative=${entry#*$'\t'}
            [[ $metadata == 100???\ blob\ * ]] || continue
            is_notice "$relative" || continue
            /usr/bin/git -C "$checkout" show "$revision:$relative" |
                record_notice "$identity" "$revision" checkout "$relative"
            found=1
        done < <(/usr/bin/git -C "$checkout" ls-tree -r -z "$revision")
        # Only notice files from this package's downloaded binary targets.
        # SDKs, build products and firmware directories are never traversed.
        artifact=$(package_directory "$packages/artifacts" "$identity") || artifact=''
        if [[ -d $artifact ]]; then
            artifact_found=0
            while IFS= read -r -d '' file; do
                relative=${file#$artifact/}
                is_notice "$relative" || continue
                record_notice "$identity" "$revision" "artifacts-${packages:h:t}" "$relative" < "$file"
                found=1
                artifact_found=1
            done < <(/usr/bin/find "$artifact" -type f -print0)
            if (( ! artifact_found )); then
                printf '%s\t%s\tartifact_missing\t-\t-\n' "$identity" "$revision" >> "$manifest"
            fi
        fi
        if (( ! found )); then
            printf '%s\t%s\tmissing\t-\t-\n' "$identity" "$revision" >> "$manifest"
        fi
    done
done
LC_ALL=C /usr/bin/sort -u "$manifest" -o "$manifest"
"$0" --check "$destination"
