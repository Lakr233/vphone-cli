#!/bin/zsh
set -euo pipefail

# Tests run-result-schema-check.sh resolution, pin checks and usage handling
# against a fake repo root and temp HOME. No tool build succeeds or is needed.

here="${0:a:h}"
runner="$here/run-result-schema-check.sh"
repo="${here:h:h}"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
fails=0

# expect <name> <exit> <substring> -- cmd...   (checks combined output)
expect() {
  local name="$1" code="$2" want="$3"; shift 4
  local out rc=0
  out=$("$@" 2>&1) || rc=$?
  if [[ $rc -eq $code && "$out" == *"$want"* ]]; then print "PASS $name"
  else print "FAIL $name: exit $rc (want $code), want '$want', got: $out"; fails=$((fails+1)); fi
}

commit() { /usr/bin/git -C "$1" -c user.name=t -c user.email=t@t commit -q --allow-empty -m "$2"; }
mkrepo() { mkdir -p "$1"; /usr/bin/git -C "$1" init -q; commit "$1" x; }
mkdd() {
  local d="$1/Library/Developer/Xcode/DerivedData/$2/SourcePackages/checkouts/icli"
  mkrepo "$d"
}

good="$tmp/good"; mkrepo "$good"
sha=$(/usr/bin/git -C "$good" rev-parse HEAD)
fakeroot="$tmp/root"
resolved="$fakeroot/VPhone.xcworkspace/xcshareddata/swiftpm/Package.resolved"
mkdir -p "${resolved:h}"
mkpin() { cat > "$resolved" <<JSON
{
  "pins" : [
    {
      "identity" : "other",
      "state" : {
        "revision" : "aaaa",
        "version" : "1.0.0"
      }
    },
    {
      "identity" : "icli",
      "state" : {
        "revision" : "$1",
        "version" : "0.10.0"
      }
    }
  ]
}
JSON
}
mkpin "$sha"
export RESULT_SCHEMA_REPO_ROOT="$fakeroot"

H0="$tmp/h0"; mkdir -p "$H0"
H2="$tmp/h2"; mkdd "$H2" A-1; mkdd "$H2" B-2
expect "zero checkouts" 2 "icli checkout not found at" -- env HOME="$H0" zsh "$runner"
expect "two checkouts" 2 "ambiguous icli checkout" -- env HOME="$H2" zsh "$runner"

other="$tmp/other"; mkrepo "$other"; commit "$other" different
osha=$(/usr/bin/git -C "$other" rev-parse HEAD)
expect "revision mismatch" 2 "icli revision mismatch: checkout $osha pin $sha" -- zsh "$runner" --icli "$other"

rm -f "$resolved"
expect "unreadable Package.resolved" 2 "cannot read icli pin from $resolved" -- zsh "$runner" --icli "$good"
mkpin "$sha"

nogit="$tmp/nogit"; mkdir -p "$nogit"
expect "no .git" 2 "cannot read icli pin from $nogit" -- zsh "$runner" --icli "$nogit"

# Checkout selection: each checkout is a distinct commit, so the revision-mismatch message names the one chosen.
explicit="$tmp/explicit"; mkrepo "$explicit"; commit "$explicit" e
builtrepo="$fakeroot/.build/XcodeBundle/SourcePackages/checkouts/icli"; mkrepo "$builtrepo"; commit "$builtrepo" b
H1="$tmp/h1"; mkdd "$H1" A-1
ddrepo="$H1/Library/Developer/Xcode/DerivedData/A-1/SourcePackages/checkouts/icli"; commit "$ddrepo" d
esha=$(/usr/bin/git -C "$explicit" rev-parse HEAD)
bsha=$(/usr/bin/git -C "$builtrepo" rev-parse HEAD)
dsha=$(/usr/bin/git -C "$ddrepo" rev-parse HEAD)
expect "--icli beats build tree" 2 "checkout $esha pin" -- env HOME="$H1" zsh "$runner" --icli "$explicit"
expect "build tree beats DerivedData" 2 "checkout $bsha pin" -- env HOME="$H1" zsh "$runner"
rm -rf "$fakeroot/.build"
expect "lone DerivedData checkout used" 2 "checkout $dsha pin" -- env HOME="$H1" zsh "$runner"

expect "tool build failure" 2 "tool build failed" -- env RESULT_SCHEMA_PACKAGE="$tmp/nopackage" zsh "$runner" --icli "$good"
expect "bare positional" 2 "usage:" -- zsh "$runner" foo
expect "--bogus" 2 "usage:" -- zsh "$runner" --bogus
expect "missing flag value" 2 "missing --icli" -- zsh "$runner" --icli
expect "--help" 0 "usage:" -- zsh "$runner" --help

# --method nosuch. needs the real tool, repo and pin.
unset RESULT_SCHEMA_REPO_ROOT
real="$repo/.build/XcodeBundle/SourcePackages/checkouts/icli"
if [[ -d "$real" ]]; then
  expect "--method nosuch." 2 "no methods match nosuch." -- zsh "$runner" --method nosuch.
elif [[ -n "${CI:-}" ]]; then
  print "FAIL --method nosuch.: no icli checkout in .build"; fails=$((fails+1))
else
  print "SKIP --method nosuch. (no icli checkout in .build)"
fi

yml="$repo/.github/workflows/build.yml"
step=$(/usr/bin/awk '/^      - name: /{ on = ($0 ~ /name: Check RPC result schemas$/) } on' "$yml")
verify_line=$(/usr/bin/grep -n '^      - name: Verify bundle$' "$yml" | /usr/bin/cut -d: -f1)
check_line=$(/usr/bin/grep -n '^      - name: Check RPC result schemas$' "$yml" | /usr/bin/cut -d: -f1)
if [[ -n "$verify_line" && -n "$check_line" ]] && (( check_line > verify_line )) && [[ "$step" == *run-result-schema-check.sh* ]]; then
  print "PASS build.yml runs the check after Verify bundle"
else print "FAIL build.yml lacks step 'Check RPC result schemas' after 'Verify bundle' running run-result-schema-check.sh"; fails=$((fails+1)); fi
if print -r -- "$step" | /usr/bin/grep -nE 'continue-on-error|[|][|] true'; then
  print "FAIL check step has continue-on-error or || true"; fails=$((fails+1))
else print "PASS check step has no continue-on-error or || true"; fi

print "$fails failed"
(( fails == 0 ))
