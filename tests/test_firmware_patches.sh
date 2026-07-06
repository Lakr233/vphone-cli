#!/usr/bin/env zsh
# test_firmware_patches.sh — full-pipeline firmware patch gate across cloudOS versions.
#
# WHY THIS EXISTS (vs test_jb_kernel_patches.sh):
#   test_jb_kernel_patches.sh runs ONLY the `kernel-jb` component. That misses
#   every patcher outside the JB kernel layer — the boot chain (iBSS/iBEC/LLB),
#   the base KernelPatcher (regular-variant kernel patches), TXM, and DeviceTree.
#   Real 26.x builds have shown silent per-patch skips in exactly those layers
#   (e.g. iBEC "bootx precondition", LLB "cmp x8,#0x400", kernel
#   "handle_get_dev_by_role") that the kernel-jb test structurally cannot see.
#
#   This harness runs the WHOLE `patch-firmware` pipeline — every component, for
#   the `jb` and `exp` variants — over each available cloudOS firmware, and fails
#   if ANY component emits a `[-]` line (a skipped/failed sub-patch).
#
# WHY GREP FOR `[-]` (not exit code):
#   FirmwarePipeline.patchAll() only throws when a whole component finds ZERO
#   patches. A patcher whose OTHER sub-patches succeed still returns records, so a
#   single silently-skipped gate never changes the exit code — it only prints a
#   `[-]` line. So the only reliable signal for a partial skip is that line.
#
# INPUTS (no network needed for the README cloudOS builds):
#   Sources are the already-extracted cloudOS firmware trees under `ipsws/<hash>/`
#   (each has BuildManifest.plist, Firmware/, and kernelcache.research.vphone600).
#   We assemble a DISPOSABLE VM dir per (version, variant) — patch-firmware edits
#   firmware in place, so each run gets its own copy — and never touch ipsws/.
#
#   tests/test_firmware_patches.sh                 # all local cloudOS firmwares, variants jb+exp
#   tests/test_firmware_patches.sh --quick         # newest local cloudOS only
#   tests/test_firmware_patches.sh 23B85 23E5207q  # only these cloudOS builds
#   VARIANTS="exp" tests/test_firmware_patches.sh  # only the exp variant
#   tests/test_firmware_patches.sh --no-build      # skip rebuilding the patcher
#
# Exit code: 0 iff EVERY (version, variant) patches with NO `[-]` lines and no crash.
set -euo pipefail

HERE=${0:a:h}
ROOT=${HERE:h}
cd "$ROOT"

WORK=${WORK:-/tmp/vphone_fw_versions}
BIN=".build/debug/vphone-cli"
IPSWS="$ROOT/ipsws"
AVPBOOTER_SRC="/System/Library/Frameworks/Virtualization.framework/Versions/A/Resources/AVPBooter.vresearch1.bin"
VARIANTS=${VARIANTS:-"jb exp"}
mkdir -p "$WORK"

# cloudOS firmware components we must stage into the disposable Restore dir
# (relative paths == the patterns FirmwarePipeline.buildComponentList searches).
typeset -a COMPONENTS=(
  "Firmware/dfu/iBSS.vresearch101.RELEASE.im4p"
  "Firmware/dfu/iBEC.vresearch101.RELEASE.im4p"
  "Firmware/all_flash/LLB.vresearch101.RELEASE.im4p"
  "Firmware/all_flash/DeviceTree.vphone600ap.im4p"
  "Firmware/txm.iphoneos.release.im4p"
  "Firmware/txm.iphoneos.research.im4p"
  "kernelcache.research.vphone600"
  "BuildManifest.plist"
)

NO_BUILD=0
QUICK=0
typeset -a ARG_BUILDS=()
for a in "$@"; do
  case "$a" in
    --no-build) NO_BUILD=1 ;;
    --quick) QUICK=1 ;;
    -*) echo "unknown option: $a" >&2; exit 2 ;;
    *) ARG_BUILDS+=("$a") ;;
  esac
done

[[ -f "$AVPBOOTER_SRC" ]] || { echo "[-] AVPBooter not found at $AVPBOOTER_SRC"; exit 2; }

plist() { /usr/libexec/PlistBuddy -c "Print :$2" "$1" 2>/dev/null || true; }

# --- 1. Discover cloudOS firmware sources (ver, build, dir) -------------------
# A valid source is any ipsws/<hash>/ with both a vphone600 research kernel and
# the Firmware/ tree. Version/build come from SystemVersion.plist.
typeset -a SRC_DIRS SRC_VERS SRC_BUILDS
for d in "$IPSWS"/*/; do
  [[ -f "$d/kernelcache.research.vphone600" && -d "$d/Firmware" ]] || continue
  ver=$(plist "$d/SystemVersion.plist" ProductVersion)
  build=$(plist "$d/SystemVersion.plist" ProductBuildVersion)
  [[ -n "$ver" && -n "$build" ]] || continue
  SRC_DIRS+=("${d%/}"); SRC_VERS+=("$ver"); SRC_BUILDS+=("$build")
done
[[ ${#SRC_DIRS} -gt 0 ]] || { echo "[-] no extracted cloudOS firmware found under $IPSWS (need kernelcache.research.vphone600 + Firmware/)"; exit 2; }

# Filter to requested builds, or --quick (highest version), if asked.
typeset -a IDX=({1..${#SRC_DIRS}})
if (( ${#ARG_BUILDS} )); then
  typeset -a keep=()
  for i in "${IDX[@]}"; do
    for b in "${ARG_BUILDS[@]}"; do [[ "${SRC_BUILDS[$i]}" == "$b" ]] && keep+=("$i"); done
  done
  IDX=("${keep[@]}")
  [[ ${#IDX} -gt 0 ]] || { echo "[-] none of the requested builds (${ARG_BUILDS[*]}) found locally"; exit 2; }
elif (( QUICK )); then
  best=${IDX[1]}
  for i in "${IDX[@]}"; do
    hi=$(printf '%s\n%s\n' "${SRC_VERS[$i]}" "${SRC_VERS[$best]}" | sort -V | tail -1)
    [[ "$hi" == "${SRC_VERS[$i]}" ]] && best=$i
  done
  IDX=("$best")
fi

echo "cloudOS firmwares to test:"
for i in "${IDX[@]}"; do echo "  ${SRC_VERS[$i]}-${SRC_BUILDS[$i]}  (${SRC_DIRS[$i]:t})"; done
echo "variants: ${VARIANTS}"

# Warn about README-listed cloudOS builds that are not present locally.
README_BUILDS=(23B85 23D128 23E5207q)
for rb in "${README_BUILDS[@]}"; do
  found=0; for i in "${IDX[@]}"; do [[ "${SRC_BUILDS[$i]}" == "$rb" ]] && found=1; done
  (( found )) || echo "  [!] README cloudOS build $rb not available locally — NOT tested (prepare it to cover it)"
done

# --- 2. Build the patcher ----------------------------------------------------
if (( ! NO_BUILD )); then
  echo "==> building patcher ..."
  if ! make patcher_build > "$WORK/build.log" 2>&1; then
    echo "[-] patcher build failed:"; tail -20 "$WORK/build.log"; exit 1
  fi
fi
[[ -x "$BIN" ]] || { echo "[-] $BIN missing (run without --no-build)"; exit 1; }

# --- 3. Assemble a disposable VM dir and run patch-firmware ------------------
typeset -A RESULT
overall=0

run_one() {
  local src="$1" ver="$2" build="$3" variant="$4"
  local key="$ver-$build/$variant"
  local vm="$WORK/$build/$variant/vm"
  local restore="$vm/iPhone17,3_${ver}_${build}_Restore"
  rm -rf "$vm"; mkdir -p "$restore"

  # AVPBooter lives in the VM root and is patched for every non-less variant.
  cp -f "$AVPBOOTER_SRC" "$vm/AVPBooter.vresearch1.bin"; chmod u+w "$vm/AVPBooter.vresearch1.bin"

  # Stage cloudOS components (clone-on-write where supported; falls back to copy).
  local rel
  for rel in "${COMPONENTS[@]}"; do
    [[ -f "$src/$rel" ]] || { echo "  [-] source missing: $rel"; RESULT[$key]="NO-INPUT"; overall=1; return; }
    mkdir -p "$restore/${rel:h}"
    cp -c "$src/$rel" "$restore/$rel" 2>/dev/null || cp -f "$src/$rel" "$restore/$rel"
    chmod u+w "$restore/$rel"
  done

  local log="$WORK/$build/$variant/run.log"
  if ! "$BIN" patch-firmware --vm-directory "$vm" --variant "$variant" > "$log" 2>&1; then
    echo "  ❌ $key — patch-firmware exited nonzero:"; tail -6 "$log" | sed 's/^/      /'
    RESULT[$key]="CRASH"; overall=1; return
  fi

  # Partial skips never change the exit code — they only print `[-]` lines.
  local fails
  fails=$(grep -nE "\[-\]" "$log" || true)
  if [[ -n "$fails" ]]; then
    echo "  ❌ $key — $(print -r -- "$fails" | grep -c .) skipped sub-patch(es):"
    print -r -- "$fails" | sed 's/^/      /'
    RESULT[$key]="FAIL"; overall=1; return
  fi

  if ! grep -q "components patched successfully" "$log"; then
    echo "  ❌ $key — pipeline did not report success"; RESULT[$key]="INCOMPLETE"; overall=1; return
  fi

  local applied; applied=$(grep -oE "\([0-9]+ total patches\)" "$log" | grep -oE "[0-9]+" | head -1 || echo "?")
  echo "  ✅ $key — $applied patches, 0 skips"
  RESULT[$key]="PASS ($applied patches)"
}

for i in "${IDX[@]}"; do
  echo ""
  echo "──────────── ${SRC_VERS[$i]}-${SRC_BUILDS[$i]} ────────────"
  for variant in ${=VARIANTS}; do
    run_one "${SRC_DIRS[$i]}" "${SRC_VERS[$i]}" "${SRC_BUILDS[$i]}" "$variant"
  done
done

# --- 4. Summary matrix -------------------------------------------------------
echo ""
echo "════════════════ summary ════════════════"
for i in "${IDX[@]}"; do
  for variant in ${=VARIANTS}; do
    key="${SRC_VERS[$i]}-${SRC_BUILDS[$i]}/$variant"
    printf "  %-22s %s\n" "$key" "${RESULT[$key]:-?}"
  done
done
echo ""
if (( overall == 0 )); then
  echo "ALL FIRMWARES PASS — every component patches cleanly (0 skipped sub-patches)."
else
  echo "ONE OR MORE FIRMWARES FAILED — a component skipped a sub-patch (see [-] lines above)."
fi
exit $overall
