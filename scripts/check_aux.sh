#!/bin/zsh
# check_aux.sh — the self-containment admission gates.
#
# The rule: every host executable vphone-cli ships or reaches for at runtime
# must depend only on /usr/lib/* and /System/Library/*. Anything under
# /opt/homebrew, /usr/local, or any other absolute path means the .app works
# here and nowhere else.
#
# Three gates, each strictly stronger than the last, and NONE of them proves
# self-containment on its own:
#
#   1  dependency closure   recursive otool -L, plus a relocation test
#   2  source scan          the PATH lookups otool cannot see
#   3  restricted smoke     each entry binary doing its smallest real job
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
typeset -a REMAINING   # known, registered, not yet removed

red()   { print -P "%F{red}$*%f" }
green() { print -P "%F{green}$*%f" }
amber() { print -P "%F{yellow}$*%f" }
fail()  { red "  FAIL  $*"; (( FAILURES++ )) }
note()  { REMAINING+=("$1"); amber "  todo  $1" }

section() { print ""; print -P "%B== $* ==%b" }

# ---------------------------------------------------------------------------
# Registered remaining dependencies
# ---------------------------------------------------------------------------
# Programs we still reach for that do NOT yet satisfy the rule. Registering one
# here turns a hard failure into a reported item, so the gate is usable while
# the migration is in flight — and the list shrinking is the migration's
# progress bar. It must be EMPTY before a release.
#
# Anything not on this list and not in the system whitelist fails.
typeset -a REGISTERED_REMAINING=(
  ldid      # -> VPhoneSign (P0.5). Bundled today and NOT self-contained.
  python3   # -> restore backend only (scripts/pymobiledevice3_bridge.py); gone at P2.4
  gtar      # -> vphone-archive (P0.5)
  zstd      # -> vphone-archive (P0.5)
  unzip     # -> vphone-archive (P0.5)
  bsdtar    # -> vphone-archive (P0.5)
  tar       # -> vphone-archive (P0.5); the system one shells out for --zstd
  aria2c    # -> deleted, curl fallback already exists (P0.5)
  ipsw      # allowed to stay: Go, statically linked, passes the rule
  sshpass   # JB environment only, frozen
)

# Programs macOS ships that we depend on and intend to keep. This is the
# honest boundary of "zero dependencies" — widening it means editing this file,
# which is the point.
typeset -a SYSTEM_WHITELIST=(
  aa plutil ditto hdiutil diskutil mount_apfs curl sudo
  codesign otool lsof awk find file sed grep readlink
  shasum sha256sum wget aea xattr stat xcrun
  zsh sh cp mv rm mkdir chmod chown ln
)

is_registered() {
  local needle="$1"
  # python3.13, python3.14 and friends are all the same dependency.
  [[ "$needle" == python3* ]] && needle=python3
  for r in $REGISTERED_REMAINING; do [[ "$r" == "$needle" ]] && return 0; done
  return 1
}

is_system_program() {
  local needle="$1"
  for r in $SYSTEM_WHITELIST; do [[ "$r" == "$needle" ]] && return 0; done
  return 1
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
          # vphoned.signed is iOS arm64 and never runs on the host.
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
          if is_registered "${dep:t:r}" || is_registered "${dep:t}"; then
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
}

# ---------------------------------------------------------------------------
# Gate 2 — source scan
# ---------------------------------------------------------------------------
# otool describes link time. These are the runtime lookups it cannot see: the
# `command -v python3` fallbacks, and a `tar --zstd` that quietly spawns a
# zstd(1) from PATH. Both are real in this repo and neither shows up in gate 1.
check_sources() {
  local hits="" line="" prog=""

  # Swift: a path into a package prefix that names something -- .../bin/ipsw,
  # .../opt/keystone/lib. Requiring a name after bin|opt|lib is what keeps the
  # guest PATH string in VPhoneBootPatterns out of this: it contains
  # "/usr/local/bin:" as a PATH element, which is a directory in the GUEST, not
  # a program on this host.
  hits=$(grep -rnE '(opt/homebrew|usr/local)/(bin|opt|lib|sbin)/[A-Za-z0-9_.-]+' \
           --include='*.swift' sources/ 2>/dev/null | grep -v ':[0-9]*: *//')
  if [[ -n "$hits" ]]; then
    while IFS= read -r line; do
      [[ -z "$line" ]] && continue
      # Report against whichever registered program the path names, if any.
      prog=""
      for r in $REGISTERED_REMAINING; do
        [[ "$line" == *"/$r"* ]] && { prog="$r"; break }
      done
      if [[ -n "$prog" ]]; then
        note "gate 2: hardcoded path to '$prog' — ${line%%:*}:${${line#*:}%%:*}"
      else
        fail "gate 2: hardcoded prefix — $line"
      fi
    done <<< "$hits"
  fi

  # Shell: this has to be a command, not the English word "which". Requiring a
  # command position -- line start, or after | ; && || ( $( ! if -- and dropping
  # comment lines is the difference between a gate people read and one they
  # learn to ignore. `which is enough for...` in a comment is not a PATH lookup.
  hits=$(grep -rnE '^[^#]*(^|[;&|(]|\$\(|`|! |if )[[:space:]]*(command -v|which)[[:space:]]+[A-Za-z0-9_.-]+' \
           --include='*.sh' scripts/ cfw-kit/ 2>/dev/null \
         | grep -vE '^scripts/(build|check_aux|setup_venv|setup_venv_linux|setup_tools)\.sh' \
         | grep -v 'vphone_jb_setup.sh')
  if [[ -n "$hits" ]]; then
    while IFS= read -r line; do
      [[ -z "$line" ]] && continue
      prog=$(print -r -- "$line" | sed -E 's/.*(command -v|which)[[:space:]]+([A-Za-z0-9_.-]+).*/\2/')
      if is_registered "$prog" || is_system_program "$prog"; then
        note "gate 2: PATH lookup for '$prog' — ${line%%:*}"
      else
        fail "gate 2: unregistered PATH lookup for '$prog' — $line"
      fi
    done <<< "$hits"
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
  local letmein="$root/Contents/MacOS/vphone-letmein"
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
  [[ -x "$letmein" ]] && {
    # Expected to refuse without root; what matters is that it starts.
    env -i PATH=/usr/bin:/bin HOME="$tmp" "$letmein" status >/dev/null 2>&1
    (( $? == 1 )) && green "  ok    gate 3: vphone-letmein starts and refuses without root" \
                  || fail "gate 3: vphone-letmein did not start cleanly"
  }
  # vphone-vm is deliberately NOT smoke-tested here: amfid refuses it unless a
  # window is open, so its exit code says something about the host, not about
  # self-containment.
  [[ -x "$vm" ]] && note "gate 3: vphone-vm skipped (amfid gates it; see boot_host_preflight.sh)"

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

section "Gate 2 · source scan"
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
if (( ${#REMAINING} )); then
  amber "${#REMAINING} registered item(s) still to remove:"
  for r in $REMAINING; do print "    - $r"; done
  print ""
  amber "These are tracked, not ignored. A release requires this list to be empty."
fi

if (( FAILURES )); then
  red "$FAILURES failure(s). The bundle is not self-contained."
  exit 1
fi
green "No unregistered violations."
print "Note: this is necessary, not sufficient. Only a machine without Homebrew,"
print "running a matrix of real work, can support 'it works elsewhere'."
