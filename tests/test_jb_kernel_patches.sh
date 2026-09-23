#!/usr/bin/env zsh
# test_jb_kernel_patches.sh — the single test for the JB kernel patch layer.
#
# Runs the WHOLE `kernel-jb` patcher (every JB hook, including all the Sandbox
# MACF ops hooks) over each cloudOS kernel the README lists as supported, and
# requires that every version applies with 0 failures and emits every expected
# patch. This is both the correctness check and the backward-compatibility gate
# (we develop against the newest kernel but must not regress older ones).
#
# The kernel we patch (`kernelcache.research.vphone600`) ships inside the cloudOS
# (PCC) firmware, so "kernel versions" == the cloudOS builds in the README's
# "Tested Environments" table. For each build we resolve its PCC "OS" asset URL
# from `ipsw dl pcc --info`, pull ONLY `kernelcache.research.vphone600` via remote
# extraction (~14 MB, not the full IPSW), run `patch-component --component
# kernel-jb`, and validate. Anything cached under the work dir is reused.
#
#   tests/test_jb_kernel_patches.sh              # all supported cloudOS builds
#   tests/test_jb_kernel_patches.sh --quick      # only the local/newest kernel (fast dev loop)
#   tests/test_jb_kernel_patches.sh 23B85 23D128 # only these builds
#   tests/test_jb_kernel_patches.sh --no-build   # skip rebuilding the patcher
#   BUILDS="23B85 23D128 23E5207q" tests/test_jb_kernel_patches.sh
#
# Exit code: 0 iff EVERY tested kernel applies all expected patches with 0 failures.
set -euo pipefail

HERE=${0:a:h}
ROOT=${HERE:h}            # tests/ lives at the repo root
cd "$ROOT"

WORK=${WORK:-/tmp/vphone_kjb_versions}
BIN=".build/debug/vphone-cli"
README="$ROOT/README.md"
PCC_INFO="$WORK/pcc_info.txt"          # cached `ipsw dl pcc --info` dump
mkdir -p "$WORK"

# Patch IDs that MUST emit on every supported kernel: the P0 sudo hook plus the
# eight routines retargeted for 26.5. If any is missing, that hook silently
# skipped. (The 0-failure gate below additionally catches every OTHER routine —
# including all the Sandbox ops hooks — since the pipeline counts a routine that
# emits nothing as a failure.)
REQUIRED_IDS=(
  jb.hook_cred_label.c23_cave
  task_conversion_eval
  jb.proc_security_policy.mov_x0_0
  jb.proc_pidinfo.nop_guard_a
  jb.io_secure_bsd_root.zero_return
  kernelcache_jb.mac_mount.flag_gate
  kernelcache_jb.spawn_validate_persona.cbz1
  kernelcache_jb.vm_map_protect
  jb.kcall10.sy_call
)

NO_BUILD=0
QUICK=0
ARG_BUILDS=()
for a in "$@"; do
  case "$a" in
    --no-build) NO_BUILD=1 ;;
    --quick) QUICK=1 ;;
    -*) echo "unknown option: $a" >&2; exit 2 ;;
    *) ARG_BUILDS+=("$a") ;;
  esac
done

command -v ipsw >/dev/null 2>&1 || { echo "[-] 'ipsw' CLI not found (brew install blacktop/tap/ipsw)"; exit 2; }

# --- 1. Determine which cloudOS builds to test -------------------------------
# Priority: --quick (local kernel) > CLI args > $BUILDS env > README cloudOS column.
typeset -a BUILD_LIST
if (( QUICK )); then
  BUILD_LIST=(local)
elif (( ${#ARG_BUILDS} )); then
  BUILD_LIST=("${ARG_BUILDS[@]}")
elif [[ -n "${BUILDS:-}" ]]; then
  BUILD_LIST=(${=BUILDS})
else
  # cloudOS column entries look like `26.4-23E5207q` (version-dash-build); the
  # iPhone column uses `17,3_26.5_23F77` (commas/underscores), so filter those out.
  #
  # awk, not the `python3 - <<'PY'` heredoc this was until P2.4. A bare `python3`
  # here resolved whatever interpreter happened to be on PATH, which is the exact
  # silent fallback the repo spent D1 removing — and it survived the venv because
  # nothing linked it to the venv in the first place. awk ships with macOS.
  BUILD_LIST=($(awk '
    /^## Tested Environments/ { insec = 1; next }
    insec && /^## /           { exit }
    !insec                    { next }
    {
      rest = $0
      while (match(rest, /`[^`]+`/)) {
        tok  = substr(rest, RSTART + 1, RLENGTH - 2)
        rest = substr(rest, RSTART + RLENGTH)
        if (tok ~ /^[0-9]+\.[0-9][0-9.]*-[0-9A-Za-z]+$/) {
          sub(/^[0-9]+\.[0-9][0-9.]*-/, "", tok)
          if (!(tok in seen)) { seen[tok] = 1; order[++n] = tok }
        }
      }
    }
    END { for (i = 1; i <= n; i++) print order[i] }
  ' "$README"))
fi
[[ ${#BUILD_LIST} -gt 0 ]] || { echo "[-] no cloudOS builds resolved"; exit 2; }
echo "kernel builds to test: ${BUILD_LIST[*]}"

# --- 2. Build the patcher ----------------------------------------------------
if (( ! NO_BUILD )); then
  echo "==> building patcher ..."
  if ! make patcher_build > "$WORK/build.log" 2>&1; then
    echo "[-] patcher build failed:"; tail -20 "$WORK/build.log"; exit 1
  fi
fi
[[ -x "$BIN" ]] || { echo "[-] $BIN missing (run without --no-build)"; exit 1; }

# --- 3. Cache the PCC release index (build -> OS asset URL) ------------------
ensure_pcc_info() {
  [[ -s "$PCC_INFO" ]] && return 0
  echo "==> fetching PCC release index (ipsw dl pcc --info) ..."
  if ! ipsw dl pcc --info > "$PCC_INFO" 2>&1; then
    echo "[-] 'ipsw dl pcc --info' failed:"; tail -5 "$PCC_INFO"; return 1
  fi
}

# Resolve one cloudOS build -> its PCC "OS" asset URL (only releases that still
# carry the vphone600 firmware). Empty output => not found.
# Also awk rather than a python3 heredoc — see the note above BUILD_LIST. The
# release index is a flat text dump, so this walks it as blocks: a numbered
# digest line opens one, and everything up to the next digest line belongs to
# it. A block qualifies only if it advertises vphone firmware, carries a PCC
# asset URL, and mentions the build we were asked about; the first qualifying
# block wins, exactly as the reading of the whole index into a list then
# scanning it in order did.
resolve_url() {
  local build="$1"
  awk -v want="$build" '
    function close_block() {
      if (!found && open && vphone && url != "" && (want in builds)) {
        found = 1
        print url
      }
      open = 0; vphone = 0; url = ""; delete builds
    }
    BEGIN { esc = sprintf("%c", 27) }
    {
      line = $0
      gsub(esc "\\[[0-9;]*m", "", line)          # ipsw colourises its output
    }
    # A release block opens on `<n>) <hex digest>`.
    match(line, /^[0-9]+\)[ \t]+[0-9a-f]+/) {
      digest = substr(line, RSTART, RLENGTH)
      sub(/^[0-9]+\)[ \t]+/, "", digest)
      if (length(digest) >= 16) { close_block(); open = 1; next }
    }
    !open { next }
    {
      if (index(line, "📱 VPHONE") > 0) vphone = 1   # the vphone firmware marker
      if (url == "" \
          && match(line, /https:\/\/updates\.cdn-apple\.com\/private-cloud-compute\/[0-9a-f]+/)) {
        url = substr(line, RSTART, RLENGTH)
      }
      # Build ids (23B85, 24A5380h) as whole words. Splitting on non-word
      # characters is what keeps `17,3_26.5_23F77` out: an id glued to its
      # neighbours by underscores is not a word on its own.
      k = split(line, word, /[^A-Za-z0-9_]+/)
      for (i = 1; i <= k; i++) {
        if (word[i] ~ /^2[0-9][A-Z][0-9A-Za-z]+$/) builds[word[i]] = 1
      }
    }
    END { close_block() }
  ' "$PCC_INFO"
}

# --- 4. Obtain kernelcache.research.vphone600 for a build -------------------
# "local" => reuse the pristine kernelcache already extracted under ipsws/.
# Otherwise reuse an already-extracted copy in the work dir; else remote-extract.
get_kernelcache() {
  local build="$1"
  if [[ "$build" == local ]]; then
    ls ipsws/*/kernelcache.research.vphone600 2>/dev/null | grep -v Restore | head -1
    return
  fi
  local dir="$WORK/$build" kc
  kc=$(find "$dir" -name 'kernelcache.research.vphone600' -type f 2>/dev/null | head -1)
  if [[ -n "$kc" && -f "$kc" ]]; then echo "$kc"; return 0; fi

  ensure_pcc_info || { echo ""; return 1; }
  local url; url=$(resolve_url "$build")
  [[ -n "$url" ]] || { echo ""; return 1; }
  mkdir -p "$dir"
  if ! ipsw extract --kernel --remote "$url" --output "$dir" >> "$WORK/$build.extract.log" 2>&1; then
    echo "" ; return 1
  fi
  find "$dir" -name 'kernelcache.research.vphone600' -type f 2>/dev/null | head -1
}

# --- 5. Run the patcher + validate one kernelcache --------------------------
typeset -A RESULT
overall=0
for build in "${BUILD_LIST[@]}"; do
  echo ""
  echo "──────────── kernel $build ────────────"
  kc=$(get_kernelcache "$build") || true
  if [[ -z "$kc" || ! -f "$kc" ]]; then
    echo "  [-] could not obtain kernelcache (no vphone release / download failed)"
    RESULT[$build]="NO-KERNEL"; overall=1; continue
  fi
  echo "  kernel: $kc"

  out="$WORK/$build"; mkdir -p "$out"
  if ! "$BIN" patch-component --component kernel-jb \
        --input "$kc" --output "$out/kc.patched.bin" --records-out "$out/records.json" \
        > "$out/run.log" 2>&1; then
    echo "  [-] patcher crashed:"; tail -8 "$out/run.log" | sed 's/^/    /'
    RESULT[$build]="CRASH"; overall=1; continue
  fi

  applied=$(grep -oE "applied [0-9]+ patches" "$out/run.log" | grep -oE "[0-9]+" | head -1 || echo "?")
  fails=$(grep -cE "\[-\]" "$out/run.log" || true)
  sandbox=$(grep -oE 'sandbox_ext_[0-9]+' "$out/records.json" 2>/dev/null | sort -u | wc -l | tr -d ' ')

  # Every required patch ID must have emitted.
  missing=()
  for id in "${REQUIRED_IDS[@]}"; do
    grep -q "\"$id\"" "$out/records.json" 2>/dev/null || missing+=("$id")
  done

  echo "  applied: $applied   failures: $fails   sandbox hooks: $sandbox"
  if (( fails == 0 )) && (( ${#missing} == 0 )) && (( sandbox >= 1 )); then
    echo "  ✅ PASS"
    RESULT[$build]="PASS ($applied applied, $sandbox sandbox)"
  else
    echo "  ❌ FAIL"
    (( fails > 0 )) && { echo "    failures:"; grep -E "\[-\]" "$out/run.log" | sed 's/^/      /'; }
    (( ${#missing} )) && echo "    missing patch IDs: ${missing[*]}"
    (( sandbox < 1 )) && echo "    no sandbox hooks emitted"
    RESULT[$build]="FAIL"; overall=1
  fi
done

# --- 6. Summary matrix -------------------------------------------------------
echo ""
echo "════════════════ summary ════════════════"
for build in "${BUILD_LIST[@]}"; do
  printf "  %-12s %s\n" "$build" "${RESULT[$build]:-?}"
done
echo ""
if (( overall == 0 )); then
  echo "ALL KERNELS PASS — every JB hook (incl. Sandbox) applies, backward-compatible."
else
  echo "ONE OR MORE KERNELS FAILED — see above."
fi
exit $overall
