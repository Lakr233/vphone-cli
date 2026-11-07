#!/bin/zsh
set -euo pipefail

# Drift check: builds and runs ResultSchemaCheck against the icli checkout SwiftPM
# resolved for this build. No guest and no network are needed.
# Test overrides: RESULT_SCHEMA_REPO_ROOT, RESULT_SCHEMA_PACKAGE, HOME.

usage() {
  print -r -- "usage: run-result-schema-check.sh [--icli <dir>] [--method <prefix>] [--help]"
}
die() { print -ru2 -- "$1"; exit 2 }
bad_usage() { print -ru2 -- "$1"; usage >&2; exit 2 }

icli="" method=""
while (( $# )); do
  case "$1" in
    --help) usage; exit 0 ;;
    --icli)   (( $# >= 2 )) || bad_usage "missing --icli";   icli="$2"; shift 2 ;;
    --method) (( $# >= 2 )) || bad_usage "missing --method"; method="$2"; shift 2 ;;
    *) bad_usage "unknown argument: $1" ;;
  esac
done

root="${RESULT_SCHEMA_REPO_ROOT:-${0:a:h:h:h}}"
package="${RESULT_SCHEMA_PACKAGE:-$root/VPhoneDaemon/Tests/ResultSchema}"

if [[ -z "$icli" ]]; then
  built="$root/.build/XcodeBundle/SourcePackages/checkouts/icli"
  if [[ -d "$built" ]]; then
    icli="$built"
  else
    derived=("$HOME"/Library/Developer/Xcode/DerivedData/*/SourcePackages/checkouts/icli(N/))
    case ${#derived} in
      1) icli="${derived[1]}" ;;
      0) die "icli checkout not found at $built, $HOME/Library/Developer/Xcode/DerivedData/*/SourcePackages/checkouts/icli; pass --icli <dir> or build once so SourcePackages/checkouts/icli exists" ;;
      *) die "ambiguous icli checkout: ${(j:, :)derived}; pass --icli <dir> to choose one" ;;
    esac
  fi
fi

resolved="$root/VPhone.xcworkspace/xcshareddata/swiftpm/Package.resolved"
pin=""
if [[ -r "$resolved" ]]; then
  pin=$(/usr/bin/awk '/"identity"/ { in_icli = ($0 ~ /"icli"/) } in_icli && /"revision"/ { gsub(/[^0-9a-f]/, "", $3); print $3; exit }' "$resolved")
fi
[[ -n "$pin" ]] || die "cannot read icli pin from $resolved"

head=""
if [[ -e "$icli/.git" ]]; then
  head=$(/usr/bin/git -C "$icli" rev-parse HEAD 2>/dev/null) || head=""
fi
[[ -n "$head" ]] || die "cannot read icli pin from $icli"
[[ "$head" == "$pin" ]] || die "icli revision mismatch: checkout $head pin $pin"

/usr/bin/xcrun swift build --package-path "$package" -c release --product ResultSchemaCheck >&2 || die "tool build failed"
bin=$(/usr/bin/xcrun swift build --package-path "$package" -c release --show-bin-path) || die "tool build failed"

args=(--repo "$root" --icli "$icli")
[[ -n "$method" ]] && args+=(--method "$method")
exec "$bin/ResultSchemaCheck" "${args[@]}"
