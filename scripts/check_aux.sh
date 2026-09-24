#!/bin/zsh
# vphone-tier: build
# check_aux.sh — the self-containment admission gates.
#
# THE RULE IS PER ENVIRONMENT. There are three, and they are not the same:
#
#   build   the machine that builds the .app — a developer's Mac or CI. Xcode,
#           `xcrun`, clang, swift, git and Homebrew are all fine here, because
#           the workflow installs them. Nothing in this tier ships.
#   dist    the .app, on a stranger's clean macOS. ONLY /usr/lib, /System and
#           what is inside the bundle. No Homebrew, no Xcode, no PATH lookups,
#           no third-party program of any kind.
#   guest   inside the VM. iOS binaries and the scripts that run there. Not part
#           of host self-containment; they ship as payload, never run here.
#
# That distinction is the whole point of this file's current shape. It used to
# hold ONE list applied to the entire repository, so `xcrun` in a build script
# and `xcrun` in something the .app ships counted the same — and the list
# shrinking said nothing about whether the product was any closer to standing on
# its own. Each script declares its tier on line 2; see scripts/dist_manifest.sh.
#
# The gates, none of which proves self-containment on its own:
#
#   0  tier declarations   every script says which environment it runs in
#   1  dependency closure  recursive otool -L on the bundle, plus relocation
#   1c bundle contents     the bundle holds the dist manifest and nothing else
#   2  source scan         the PATH lookups otool cannot see, weighed per tier
#   3  restricted smoke    each entry binary doing its smallest real job
#
# What is missing is gate 4 — a machine with no Homebrew at all, running a
# matrix of real work. Gates 1 and 2 are cheap and precise; gate 3 is a smoke
# test that only covers the code it actually executes and cannot see a
# hardcoded absolute path, because `env -i` clears variables and
# /opt/homebrew stays right where it is. Do not read a green run here as
# "it will work on another machine".
#
# Usage: check_aux.sh [--fast]     (--fast skips gate 3)
set -uo pipefail   # deliberately no -e: a gate reports every finding, then exits

SCRIPT_DIR="${0:a:h}"
PROJ="${SCRIPT_DIR:h}"
cd "$PROJ"

FAST=0
[[ "${1:-}" == "--fast" || "${CHECK_AUX_FAST:-0}" == "1" ]] && FAST=1

BUNDLE=".build/vphone-cli.app"
FAILURES=0

red()   { print -P "%F{red}$*%f" }
green() { print -P "%F{green}$*%f" }
amber() { print -P "%F{yellow}$*%f" }
fail()  { red "  FAIL  $*"; (( FAILURES++ )) }

section() { print ""; print -P "%B== $* ==%b" }

# ---------------------------------------------------------------------------
# Registered remaining dependencies — per tier
# ---------------------------------------------------------------------------
# DIST is the list that matters, and it is the one a release requires to be
# EMPTY. Anything on it is a third-party program the shipped .app still reaches
# for, which means the .app works on the machine that built it and nowhere else.
#
# It is empty today. Getting it there was the work: `ldid` became `vphone-cli
# sign`, `gtar`/`zstd`/`tar` became `vphone-archive`, `ipsw` became
# `vphone-cli fw aea-key` / `fw im4p-*` plus IM4P handling in FirmwarePatcher,
# `xcrun` went away entirely because the five guest binaries are cross-compiled
# at build time now, and `aria2c`/`wget` were download fallbacks that curl
# already covered.
#
# Keep it empty. Adding a line here is a decision to ship something that does
# not work on a clean Mac.
typeset -a DIST_REMAINING=(
)

# BUILD is deliberately permissive: this tier is a developer's Mac or a CI
# runner that just ran `brew install`, and holding it to the dist rule would be
# pointless ceremony. What it may NOT do is leak — gate 1c checks that no
# build-tier script is inside the .app, and gate 2 checks that no dist-tier
# script execs one.
typeset -a BUILD_ALLOWED=(
  brew xcrun xcodebuild clang swift git make rsync
  ldid gtar zstd ipsw aria2c wget sshpass trustcache insert_dylib
)

# python3 must never appear on any of these lists. The restore backend was its
# last consumer and is now libirecovery + idevicerestore linked into vphone-cli,
# so an interpreter lookup anywhere in this repo is not a debt to pay down — it
# is a regression, and gate 2 FAILS on one in every tier. `fold_program` still
# folds python3.13 and friends onto `python3`, so a versioned lookup fails under
# the name people will search for.
#
# The AMFI bypass is on no list either, and for the opposite reason to the one
# that used to be written here: it is not an external program any more.
# `vphone-amfi-allow` is built from this repository's own C, ships in the
# bundle, and links CoreFoundation, Security and libSystem — so gate 1 weighs it
# like everything else. What must not appear is a LOOKUP: `make amfi_allow` runs
# it by absolute path.

# Programs macOS ships that the dist tier may use. This is the honest boundary
# of "zero dependencies" — widening it means editing this file, which is the
# point. Everything here is under /usr/bin, /bin, /usr/sbin or /sbin on a stock
# install; `aea` is macOS 12+, `mount_apfs` and `diskutil` are /sbin and
# /usr/sbin.
typeset -a SYSTEM_WHITELIST=(
  aa aea plutil ditto hdiutil diskutil mount_apfs umount mount curl sudo
  codesign otool lsof awk find file sed grep readlink basename dirname
  shasum sha256sum xattr stat id uname sysctl defaults nvram
  zsh sh bash cp mv rm mkdir chmod chown ln ls cat head tail sort uniq
  wc tr cut printf echo date mktemp sleep kill ps open tee xargs
)

fold_program() {
  local needle="$1"
  [[ "$needle" == python3* ]] && needle=python3
  print -r -- "$needle"
}

in_list() {   # in_list <needle> <list…>
  local needle="$1"; shift
  for r in "$@"; do [[ "$r" == "$needle" ]] && return 0; done
  return 1
}

# ---------------------------------------------------------------------------
# Gate 0 — tier declarations
# ---------------------------------------------------------------------------
# An undeclared script is not a formality: the bundler reads these lines, and
# an undeclared one silently ships nowhere. Better to say so here than to have
# `cfw install` fail on a stranger's machine with "no such file".
typeset -A TIER
check_tiers() {
  local name tier
  while IFS=$'\t' read -r name tier; do
    TIER[$name]="$tier"
    case "$tier" in
      build|dist|guest) ;;
      undeclared) fail "gate 0: scripts/$name has no '# vphone-tier:' on line 2" ;;
      *)          fail "gate 0: scripts/$name declares unknown tier '$tier'" ;;
    esac
  done < <(zsh "$SCRIPT_DIR/dist_manifest.sh" --tiers)
  (( ${#TIER} )) || { fail "gate 0: no scripts found"; return }
  local dist=0 build=0 guest=0
  for name in ${(k)TIER}; do
    case "${TIER[$name]}" in
      dist)  (( dist++ )) ;;
      build) (( build++ )) ;;
      guest) (( guest++ )) ;;
    esac
  done
  green "  ok    gate 0: ${#TIER} scripts declared — $dist dist, $build build, $guest guest"
}

# ---------------------------------------------------------------------------
# Gate 1 — dependency closure
# ---------------------------------------------------------------------------
# Recursive, not one level: an executable can be clean while a dylib it loads
# from inside the bundle is not. And every absolute path fails, including one
# that happens to resolve inside the bundle right now — the build machine
# writes paths like /Users/.../.build/.../vphone.app/..., which check out here
# and break the moment the .app is copied anywhere. Only @rpath, @loader_path
# and @executable_path are relative at runtime.
check_closure() {
  local root="$1"           # bundle dir, or a directory of loose binaries
  local -a queue=() seen=()
  local obj="" dep="" resolved=""

  while IFS= read -r obj; do queue+=("$obj"); done < <(
    find "$root" -type f -perm -u+x 2>/dev/null \
      | while IFS= read -r f; do
          # Resources/guest holds the iOS guest daemon and related resources,
          # plus vphoned.signed for a live install. They are arm64
          # iphoneos Mach-Os; they never run on this host and their link lines
          # say nothing about whether this .app is self-contained.
          [[ "$f" == */Contents/Resources/guest/* ]] && continue
          [[ "${f:t}" == "vphoned.signed" ]] && continue
          file "$f" 2>/dev/null | grep -q "Mach-O" && print -r -- "$f"
        done
  )

  (( ${#queue} )) || { fail "gate 1: no Mach-O files found under $root"; return }

  while (( ${#queue} )); do
    obj="${queue[1]}"; shift queue
    [[ " ${seen[*]} " == *" $obj "* ]] && continue
    seen+=("$obj")

    # Fat binaries print a dependency list per slice; check them all.
    while IFS= read -r dep; do
      case "$dep" in
        /usr/lib/*|/System/Library/*) ;;
        @rpath/*|@loader_path/*|@executable_path/*)
          resolved="$root/Contents/MacOS/${dep:t}"
          if [[ -f "$resolved" ]]; then
            queue+=("$resolved")
          else
            fail "gate 1: ${obj:t} loads $dep, which is not shipped in the bundle"
          fi
          ;;
        /*)
          if in_list "${dep:t:r}" $DIST_REMAINING || in_list "${dep:t}" $DIST_REMAINING; then
            note "gate 1: ${obj:t} -> $dep"
          else
            fail "gate 1: ${obj:t} -> $dep"
          fi
          ;;
      esac
    done < <(otool -L "$obj" 2>/dev/null | grep -E '^\s+\S+ \(compat' | awk '{print $1}')

    # LC_RPATH entries pointing into a toolchain are what SwiftPM always emits,
    # and they are harmless here because /usr/lib/swift comes first and macOS
    # ships the Swift runtime. Reporting them on every binary would drown the
    # gate; report only an rpath that is neither a toolchain path nor relative.
    local rp=""   # `local rp` with no value makes zsh print the parameter
    while IFS= read -r rp; do
      [[ -z "$rp" ]] && continue
      case "$rp" in
        /usr/lib/swift|@*) ;;
        */XcodeDefault.xctoolchain/*|*/com.apple.security.cryptexd/*) ;;
        *) fail "gate 1: ${obj:t} carries LC_RPATH $rp" ;;
      esac
    done < <(otool -l "$obj" 2>/dev/null | grep -A2 LC_RPATH | grep ' path ' | awk '{print $2}')

    codesign -v "$obj" 2>/dev/null || fail "gate 1: ${obj:t} is not validly signed"
  done
  green "  ok    gate 1: ${#seen} host Mach-O(s) under ${root:t}, all on /usr/lib + /System"
}

# ---------------------------------------------------------------------------
# Gate 1c — the bundle carries the dist manifest, and nothing else
# ---------------------------------------------------------------------------
# The bundler used to work from a list of EXCLUSIONS, so anything new shipped by
# default. That is how the .app came to carry build.sh, check_aux.sh and
# setup_tools.sh — which runs `brew install` — alongside the scripts it actually
# needs. It is an allowlist now, and this gate is what keeps it honest: a
# build-tier script inside the bundle is a hard failure, because everything in
# that tier is allowed to assume a toolchain the dist tier does not have.
check_bundle_contents() {
  local root="$1"
  local res="$root/Contents/Resources/scripts"
  [[ -d "$res" ]] || { fail "gate 1c: no Contents/Resources/scripts in the bundle"; return }

  local name shipped=0
  for name in ${(k)TIER}; do
    if [[ -e "$res/$name" ]]; then
      case "${TIER[$name]}" in
        dist|guest) (( shipped++ )) ;;
        *) fail "gate 1c: $name is tier ${TIER[$name]} and is in the bundle" ;;
      esac
    elif [[ "${TIER[$name]}" == dist || "${TIER[$name]}" == guest ]]; then
      fail "gate 1c: $name is tier ${TIER[$name]} and is NOT in the bundle"
    fi
  done

  # Nothing may appear under Resources/scripts that the manifest did not put
  # there — a stale file from an older bundle is exactly as dangerous as a
  # wrongly-declared one, and `make bundle` builds over whatever is already on
  # disk.
  local -a manifest=()
  while IFS= read -r name; do manifest+=("$name"); done \
    < <(zsh "$SCRIPT_DIR/dist_manifest.sh")
  local entry rel m ok
  for entry in "$res"/**/*(N.); do
    rel="${entry#$res/}"
    ok=0
    for m in $manifest; do
      # The manifest names files and whole directories, so a bundled file is
      # accounted for when it IS an entry or sits under one.
      [[ "$rel" == "$m" || "$rel" == "$m"/* ]] && { ok=1; break }
    done
    (( ok )) || fail "gate 1c: $rel is in the bundle but not in the manifest"
  done

  green "  ok    gate 1c: $shipped dist/guest scripts shipped, no build-tier file in the bundle"
}

# ---------------------------------------------------------------------------
# Gate 2 — source scan, per tier
# ---------------------------------------------------------------------------
# otool describes link time. These are the runtime lookups it cannot see: a
# `command -v python3` fallback, and a `tar --zstd` that quietly spawns a
# zstd(1) from PATH. Neither shows up in gate 1.
#
# The tier decides the verdict, not the program. `xcrun` in guest_binaries.mk is
# correct — that file exists to use the iPhoneOS SDK. The same `xcrun` in
# cfw_install_jb.sh was a bug, because that script ships, and it made a full
# Xcode install a prerequisite for putting firmware on a VM.
check_sources() {
  local hits="" line="" prog="" file="" tier=""

  # --- Swift: the whole package is dist. ---
  # A path into a package prefix that names something -- .../bin/ipsw,
  # .../opt/keystone/lib. Requiring a name after bin|opt|lib is what keeps the
  # guest PATH string in VPhoneBootPatterns out of this: it contains
  # "/usr/local/bin:" as a PATH element, which is a directory in the GUEST, not
  # a program on this host.
  hits=$(grep -rnE '(opt/homebrew|usr/local)/(bin|opt|lib|sbin)/[A-Za-z0-9_.-]+' \
           --include='*.swift' sources/ 2>/dev/null | grep -v ':[0-9]*: *//')
  if [[ -n "$hits" ]]; then
    while IFS= read -r line; do
      [[ -z "$line" ]] && continue
      fail "gate 2 [dist]: hardcoded prefix in Swift — $line"
    done <<< "$hits"
  else
    green "  ok    gate 2 [dist]: no Homebrew path anywhere in sources/"
  fi

  # --- Shell: one file at a time, judged by its own tier. ---
  # This has to be a command, not the English word "which". Requiring a command
  # position -- line start, or after | ; && || ( $( ! if -- and dropping comment
  # lines is the difference between a gate people read and one they learn to
  # ignore. `which is enough for...` in a comment is not a PATH lookup.
  local -a dist_clean=()
  for file in scripts/*.sh; do
    tier="${TIER[${file:t}]:-undeclared}"
    [[ "$tier" == guest ]] && continue     # runs in iOS; not our PATH
    [[ "$tier" == build ]] && continue     # may assume Xcode and Homebrew

    local found=0
    # PATH lookups.
    while IFS= read -r line; do
      [[ -z "$line" ]] && continue
      prog=$(fold_program "$(print -r -- "$line" \
        | sed -E 's/.*(command -v|which)[[:space:]]+([A-Za-z0-9_.-]+).*/\2/')")
      if in_list "$prog" $DIST_REMAINING; then
        note "gate 2 [dist]: PATH lookup for '$prog' — ${line%%:*}"
      else
        fail "gate 2 [dist]: PATH lookup for '$prog' — $line"
      fi
      found=1
    done < <(grep -nE '^[^#]*(^|[;&|(]|\$\(|`|! |if )[[:space:]]*(command -v|which)[[:space:]]+[A-Za-z0-9_.-]+' \
               "$file" 2>/dev/null | sed "s|^|$file:|")

    # Homebrew and /usr/local, in any shape.
    while IFS= read -r line; do
      [[ -z "$line" ]] && continue
      # /usr/local paths inside a GUEST filesystem string are not host lookups:
      # iosbinpack64 installs into /usr/local/bin on the VM's own volume.
      [[ "$line" == */iosbinpack64* || "$line" == *tmpdir* ]] && continue
      fail "gate 2 [dist]: Homebrew or /usr/local — $line"
      found=1
    done < <(grep -nE '/opt/homebrew|/usr/local/(bin|opt|lib|sbin)' "$file" 2>/dev/null \
               | grep -vE '^[0-9]+:[[:space:]]*#' | sed "s|^|$file:|")

    # A dist script must not exec a build-tier one: it is not in the bundle.
    local other=""
    for other in ${(k)TIER}; do
      [[ "${TIER[$other]}" == build ]] || continue
      if grep -qE "(zsh|bash|sh|exec|\\\$SCRIPT_DIR/|/)$other\b" "$file" 2>/dev/null \
         && ! grep -qE "^[[:space:]]*#.*$other" <(grep -E "$other" "$file"); then
        fail "gate 2 [dist]: ${file:t} runs build-tier $other, which does not ship"
        found=1
      fi
    done

    (( found )) || dist_clean+=("${file:t}")
  done
  green "  ok    gate 2 [dist]: ${#dist_clean} dist scripts reach for nothing outside macOS"

  # --- Swift: read a file by mapping it, never by slurping it. ---
  #
  # `Data(contentsOf:)` with no options reads the whole file into resident
  # memory. That is fine for a plist and ruinous for what this project actually
  # opens: `ManifestHashPatcher` hashes the `OS` component, which is a ten
  # gigabyte filesystem image, and `DSCLocalSymbolTable` parses
  # dyld_shared_cache_arm64e.symbols, which is 1.17 GB on iOS 27 — it read both
  # tables whole, so every symbol resolver cost over a gigabyte and a test run
  # that built several took the machine down.
  #
  # `.mappedIfSafe` costs address space instead: pages fault in where they are
  # touched and the kernel evicts them again.
  #
  # There IS one case where mapping is wrong, and it is not a matter of taste:
  # a buffer that will be mutated and written back over its own file. The write
  # replaces the file the buffer is mapped from, and the next page fault
  # through that mapping is a SIGBUS — a killed process with no failed
  # assertion, which is how it presented. Those reads say so in the spelling:
  # `Data(contentsOfFileToRewrite:)`, defined once, in
  # sources/FirmwarePatcher/Binary/InPlaceRewrite.swift, with the reason.
  #
  # So the rule for sources/ is: no bare `Data(contentsOf:)`. Either it is
  # mapped, or it names itself as the rewrite case.
  #
  # tests/ is deliberately NOT covered, and that is not laziness. What a test
  # opens is a committed fixture of a few megabytes, so mapping buys nothing —
  # and the fixtures are exactly what the patch tests mutate and write back
  # over, which is the one shape where mapping is wrong. Holding the tests to
  # the production rule would trade a memory problem they do not have for a
  # SIGBUS they would.
  hits=$(grep -rn 'Data(contentsOf:' --include='*.swift' sources/ 2>/dev/null \
         | grep -v 'mappedIfSafe' \
         | grep -vE ':[0-9]+: *//')
  if [[ -n "$hits" ]]; then
    while IFS= read -r line; do
      [[ -z "$line" ]] && continue
      fail "gate 2: unmapped file read — ${line%%:*}:${${line#*:}%%:*} (add options: .mappedIfSafe)"
    done <<< "$hits"
  else
    green "  ok    gate 2: every file read in sources/ is mapped or a declared rewrite"
  fi

  # --- No interpreter, in any tier. ---
  # This is D1's completion gate, and it deliberately does not look for a
  # pattern: it fails on the word `python` wherever this project's own shell can
  # execute it. Looking for `command -v python3` is what would have missed the
  # two `python3 - <<'PY'` heredocs that sat in tests/ long after the venv they
  # were never part of.
  #
  # Two things are not interpreter use here. Comment lines: the repo explains
  # what the Python used to do in a lot of places, and that history is worth
  # keeping. And `echo`/`print` lines, which name a command without running it.
  #
  # check_aux.sh excludes itself, because a scanner that looks for a word
  # necessarily contains it.
  hits=$( { grep -rnE 'python[0-9.]*' --include='*.sh' --include='*.mk' \
              scripts/ tests/ 2>/dev/null
            grep -HnE 'python[0-9.]*' Makefile 2>/dev/null } \
          | grep -vE '^[^:]+:[0-9]+:[[:space:]]*#' \
          | grep -vE '^scripts/check_aux\.sh:' \
          | grep -vE '(echo|print)[[:space:]]' )
  if [[ -n "$hits" ]]; then
    while IFS= read -r line; do
      [[ -z "$line" ]] && continue
      fail "gate 2: interpreter reference — $line"
    done <<< "$hits"
  else
    green "  ok    gate 2: no python reachable from any script, Makefile or test"
  fi
}

# ---------------------------------------------------------------------------
# Gate 3 — restricted-environment smoke test
# ---------------------------------------------------------------------------
# Each entry binary doing the smallest real thing it does, with PATH cut to the
# system directories and no inherited environment.
#
# It catches PATH fallbacks and missing libraries on the path it actually
# walks. It does NOT catch a hardcoded /opt/homebrew/bin/ldid, because `env -i`
# clears variables and that file is still there; and it says nothing about code
# this particular invocation did not reach.
check_smoke() {
  local root="$1"
  local cli="$root/Contents/MacOS/vphone-cli"
  local vm="$root/Contents/MacOS/vphone-vm"
  local tmp; tmp="$(mktemp -d)"

  run_restricted() {
    local label="$1"; shift
    if env -i PATH=/usr/bin:/bin HOME="$tmp" "$@" >/dev/null 2>&1; then
      green "  ok    gate 3: $label"
    else
      fail "gate 3: $label (exit $?)"
    fi
  }

  [[ -x "$cli" ]] && run_restricted "vphone-cli --help" "$cli" --help

  # The one binary whose smallest real job is worth doing here. Packing and
  # unpacking a .tzst with no zstd(1) reachable is the whole reason it exists:
  # both the system tar and GNU tar spawn one for that filter, so this is the
  # difference between a CFW install working on a machine without Homebrew and
  # not.
  local archive="$root/Contents/MacOS/vphone-archive"
  if [[ -x "$archive" ]]; then
    local work="$tmp/smoke"
    mkdir -p "$work/src" "$work/out"
    print "hello" > "$work/src/probe.txt"
    if env -i PATH=/usr/bin:/bin HOME="$tmp" "$archive" \
         create -f "$work/t.tzst" -C "$work/src" --zstd >/dev/null 2>&1 \
       && env -i PATH=/usr/bin:/bin HOME="$tmp" "$archive" \
         extract -f "$work/t.tzst" -C "$work/out" >/dev/null 2>&1 \
       && [[ "$(<"$work/out/probe.txt")" == "hello" ]]; then
      green "  ok    gate 3: vphone-archive round-trips a .tzst with no zstd on PATH"
    else
      fail "gate 3: vphone-archive could not round-trip a .tzst"
    fi
  fi

  # Signing used to be ldid, the one bundled program that linked Homebrew.
  # Round-tripping entitlements through the replacement, with nothing on PATH,
  # is what says the CFW installers can still sign on a clean machine.
  if [[ -x "$cli" && -f "$root/Contents/MacOS/vphone-archive" ]]; then
    cp "$root/Contents/MacOS/vphone-archive" "$tmp/subject"
    if env -i PATH=/usr/bin:/bin HOME="$tmp" "$cli" sign --merge "$tmp/subject" >/dev/null 2>&1 \
       && env -i PATH=/usr/bin:/bin HOME="$tmp" "$cli" dump-entitlements "$tmp/subject" >/dev/null 2>&1; then
      green "  ok    gate 3: vphone-cli sign + dump-entitlements with no ldid on PATH"
    else
      fail "gate 3: vphone-cli could not sign with a restricted PATH"
    fi
  fi

  # The IM4P half of what `ipsw` used to do, round-tripped. Deliberately not
  # `fw aea-key`, `fw urls` or `fw seal-tool`: those three are the other half
  # and every one of them makes a network request, which would turn this gate
  # amber on a train. They are checked by hand — `fw urls` against `ipsw
  # download ipsw --urls`, `fw aea-key` against `ipsw fw aea --key`.
  if [[ -x "$cli" ]]; then
    local im4p="$tmp/im4p"
    mkdir -p "$im4p"
    print "payload" > "$im4p/in.bin"
    if env -i PATH=/usr/bin:/bin HOME="$tmp" "$cli" fw im4p-create \
         --type isys --version 0 -o "$im4p/c.im4p" "$im4p/in.bin" >/dev/null 2>&1 \
       && env -i PATH=/usr/bin:/bin HOME="$tmp" "$cli" fw im4p-extract \
         --output "$im4p/out.bin" "$im4p/c.im4p" >/dev/null 2>&1 \
       && cmp -s "$im4p/in.bin" "$im4p/out.bin"; then
      green "  ok    gate 3: vphone-cli fw im4p-create/extract with no ipsw on PATH"
    else
      fail "gate 3: vphone-cli could not round-trip an IM4P"
    fi
  fi

  # An entitled VM can be refused at exec by this host's AMFI policy, which is
  # independent of the bundle's dependency closure. Check the relocated
  # signature and its two required private entitlements here; a real VM boot
  # is the separate host acceptance test.
  local entitlements="$tmp/vm-entitlements.plist"
  if [[ -x "$vm" ]] \
     && /usr/bin/codesign --verify --strict "$vm" >/dev/null 2>&1 \
     && /usr/bin/codesign -d --entitlements - --xml "$vm" >"$entitlements" 2>/dev/null \
     && [[ "$(/usr/libexec/PlistBuddy -c 'Print :com.apple.private.virtualization' "$entitlements" 2>/dev/null)" == true ]] \
     && [[ "$(/usr/libexec/PlistBuddy -c 'Print :com.apple.private.virtualization.security-research' "$entitlements" 2>/dev/null)" == true ]]; then
    green "  ok    gate 3: relocated vphone-vm signature and PV=3 entitlements"
  else
    fail "gate 3: relocated vphone-vm signature or PV=3 entitlements"
  fi

  rm -rf "$tmp"
}

# ---------------------------------------------------------------------------
# Run
# ---------------------------------------------------------------------------
print -P "%Bvphone-cli admission gates%b"

if [[ ! -d "$BUNDLE" ]]; then
  red "no bundle at $BUNDLE — run 'make bundle' first"
  exit 2
fi

section "Gate 0 · tier declarations"
check_tiers

section "Gate 1 · dependency closure (in place)"
check_closure "$BUNDLE"

section "Gate 1b · relocation test"
# Checking in the build directory is the one place a path bound to the build
# directory also passes. Copy it somewhere else, under a different name, and
# check that.
MOVED="$(mktemp -d)/Relocated.app"
mkdir -p "${MOVED:h}"
cp -R "$BUNDLE" "$MOVED"
check_closure "$MOVED"

section "Gate 1c · bundle contents match the dist manifest"
check_bundle_contents "$MOVED"

section "Gate 2 · source scan, per tier"
check_sources

if (( FAST )); then
  print ""; amber "Gate 3 skipped (--fast). CI must not skip it."
else
  section "Gate 3 · restricted-environment smoke test (on the relocated copy)"
  check_smoke "$MOVED"
fi
rm -rf "${MOVED:h}"

# ---------------------------------------------------------------------------
section "Result"

if (( FAILURES )); then
  red "$FAILURES failure(s). The bundle is not self-contained."
  exit 1
fi
green "No unregistered violations."
print "Note: this is necessary, not sufficient. Only a machine without Homebrew,"
print "running a matrix of real work, can support 'it works elsewhere'."
