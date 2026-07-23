#!/bin/zsh
# cfw_install_exp.sh — Install base CFW + JB extensions + EXP experimental
# patches on vphone. Files are placed directly on the VM's Disk.img volumes,
# which cfw_install_host.sh attaches and mounts on the host; the VM must be off.
#
# Runs the base CFW installer first (phases 1-7), the JB-specific
# modifications (launchd jetsam patch, dylib injection, procursus bootstrap,
# BaseBin hook deployment, JB-1..JB-5), and additionally the experimental
# phases — labeled `EXP-JB-N` to make their EXP-only scope obvious:
#   - Pre-step      : byte-5 mangle of kern.hv_vmm_present in DSC dylibs
#                     (paired with KernelEXPPatcher's kernel-side rename).
#   - EXP-JB-3.5    : surgical 2-insn patch of watchdogd's hv_vmm cache +
#                     slot re-attest of the standalone Mach-O.
#   - EXP-JB-6      : post-restore DT identity rewrite (root model /
#                     target-type / compatible[0]) inside
#                     $MNT5/.../devicetree.img4.
#   - EXP-JB-7      : optional ProductBuildVersion rewrite in
#                     SystemVersion.plist (gated on the SPOOF_BUILD env var).
#
# Stages JB-1..JB-5 remain genuine jailbreak phases (inherited from the JB
# pipeline). Stages prefixed EXP-JB-* are EXP-exclusive — they do NOT run
# when the JB or DEV install scripts are used. JB and DEV remain on their
# pre-experimental baseline.
#
# Prerequisites (in addition to cfw_install.sh requirements):
#   - cfw_jb_input/ or resources/cfw_jb_input.tar.zst present
#   - zstd (for bootstrap decompression)
#
# Usage: make cfw_install_exp
set -euo pipefail

# ── Restore caller's PATH — Nix /etc/zshenv resets PATH on zsh startup ─
[[ -n "${_VPHONE_PATH:-}" ]] && export PATH="$_VPHONE_PATH"
VM_DIR="${1:-.}"
SCRIPT_DIR="${0:a:h}"

# ── Python resolver — prefer project venv over whatever is in PATH ─
# Resolves to .venv/bin/python3 relative to the project root (parent of
# scripts/), falling back to the system python3 when the venv is absent.
_resolve_python3() {
    local venv_py="${SCRIPT_DIR:h}/.venv/bin/python3"
    if [[ -x "$venv_py" ]]; then
        echo "$venv_py"
    else
        command -v python3 || true
    fi
}
PYTHON3="$(_resolve_python3)"

# ════════════════════════════════════════════════════════════════
# Step 1: Run base CFW install (skip halt — we continue with JB phases)
# ════════════════════════════════════════════════════════════════
echo "[*] cfw_install_exp.sh — Installing CFW + JB extensions + EXP experimental patches..."
echo ""

# ────────────────────────────────────────────────────────────────────
# Pre-step: patch hv_vmm_present user-mode consumers in the SystemOS
# Cryptex's DSC chunks BEFORE running cfw_install.sh.
#
# cfw_install.sh decrypts the SystemOS Cryptex AEA into
# $TEMP_DIR/CryptexSystemOS.dmg and reuses it on subsequent runs. We
# pre-create that decrypted DMG here, mount it, patch the DSC chunks
# in place, unmount, and let cfw_install.sh pick up the cached
# (already-patched) DMG. cfw_install.sh itself is unmodified — this
# is the EXP variant's device-like user-mode patching, kept out of
# the JB install path so JB remains unaffected.
# ────────────────────────────────────────────────────────────────────
VM_DIR_ABS="$(cd "${VM_DIR:-.}" && pwd)"
JB_TEMP_DIR="$VM_DIR_ABS/.cfw_temp"
JB_SYSOS_DMG="$JB_TEMP_DIR/CryptexSystemOS.dmg"
JB_MNT_SYSOS="$JB_TEMP_DIR/mnt_sysos_hv_vmm"
mkdir -p "$JB_TEMP_DIR"

# Find the restore directory (same logic as cfw_install.sh)
JB_RESTORE_DIR=""
for d in "$VM_DIR_ABS"/iPhone*_Restore; do
    [[ -d "$d" ]] && { JB_RESTORE_DIR="$d"; break; }
done

if [[ -z "$JB_RESTORE_DIR" ]]; then
    echo "[!] hv_vmm DSC patch: no restore directory found, skipping"
elif [[ ! -f "$JB_SYSOS_DMG" ]]; then
    # Not yet decrypted — decrypt to the cache location cfw_install.sh expects.
    echo "[*] hv_vmm DSC patch: decrypting SystemOS into cache..."
    JB_CRYPTEX_SYSOS=$("$PYTHON3" "$SCRIPT_DIR/patchers/cfw.py" cryptex-paths "$JB_RESTORE_DIR/iPhone-BuildManifest.plist" | head -1)
    JB_AEA_KEY=$(ipsw fw aea --key "$JB_RESTORE_DIR/$JB_CRYPTEX_SYSOS")
    aea decrypt -i "$JB_RESTORE_DIR/$JB_CRYPTEX_SYSOS" -o "$JB_SYSOS_DMG" -key-value "$JB_AEA_KEY"
fi

if [[ -f "$JB_SYSOS_DMG" ]]; then
    # Mount, patch chunks (hv_vmm + camera, same cryptex), unmount.
    # Idempotent: re-running on an already-patched DMG is a no-op
    # (hv_vmm patcher detects already-patched cstrings; camera patcher
    # refuses pre-patched function entries unless --force is passed).
    echo "[*] DSC patches: mounting cached SystemOS DMG..."
    mkdir -p "$JB_MNT_SYSOS"
    sudo ${SUDO_ASKPASS:+-A} hdiutil detach "$JB_MNT_SYSOS" -force 2>/dev/null || true
    sudo ${SUDO_ASKPASS:+-A} hdiutil attach -mountpoint "$JB_MNT_SYSOS" "$JB_SYSOS_DMG" -nobrowse -owners off

    JB_DSC_CHUNKS_DIR="$JB_MNT_SYSOS/System/Library/Caches/com.apple.dyld"
    JB_DSC_HEADER="$JB_DSC_CHUNKS_DIR/dyld_shared_cache_arm64e"
    if [[ -d "$JB_DSC_CHUNKS_DIR" ]]; then
        echo "[*] hv_vmm DSC patch: patching chunks under $JB_DSC_CHUNKS_DIR..."
        "$SCRIPT_DIR/patch_hv_vmm_userland.sh" dsc "$JB_DSC_CHUNKS_DIR"
        echo "[+] hv_vmm DSC patch: chunks patched"

        # Camera DSC patches: (1) short-circuit the NeutrinoCore
        # _NUStyleTransfer*Processor methods so Camera.app's style-
        # thumbnail pipeline doesn't crash on this VM build, and (2)
        # force +[AVCaptureDevice authorizationStatusForMediaType:] =
        # Authorized so apps don't bail at the TCC gate. Both are
        # resolved per-build via `ipsw dyld symaddr` and verified by
        # pacibsp prologue match — version-portable as long as the
        # named ObjC symbols continue to exist. Combined with the
        # /product/camera DT node added at fw_patch time, this lets
        # Camera.app's icon show on Home Screen and the app launch
        # without immediately bailing.
        if [[ -f "$JB_DSC_HEADER" ]]; then
            echo "[*] camera DSC patch: patching chunks under $JB_DSC_CHUNKS_DIR..."
            if "$SCRIPT_DIR/patch_camera_userland.sh" dsc "$JB_DSC_CHUNKS_DIR" "$JB_DSC_HEADER"; then
                echo "[+] camera DSC patch: chunks patched"
            else
                echo "[!] camera DSC patch: failed (likely build-version mismatch); continuing"
            fi
        else
            echo "[-] camera DSC patch: $JB_DSC_HEADER not found, skipping"
        fi
    else
        echo "[-] DSC patches: $JB_DSC_CHUNKS_DIR not found, skipping"
    fi

    sudo ${SUDO_ASKPASS:+-A} hdiutil detach "$JB_MNT_SYSOS" -force
fi

# Now run the regular CFW install. It will see the cached (patched)
# CryptexSystemOS.dmg and use it as-is, so the patched DSC chunks land
# in $MNT1/System/Cryptexes/OS.
zsh "$SCRIPT_DIR/cfw_install.sh" "$VM_DIR"

# ════════════════════════════════════════════════════════════════
# Step 2: JB-specific phases
# ════════════════════════════════════════════════════════════════

# Resolve absolute paths (same as base script)
VM_DIR="$(cd "${VM_DIR}" && pwd)"

# ── Configuration ───────────────────────────────────────────────
CFW_INPUT="cfw_input"
CFW_JB_INPUT="cfw_jb_input"
CFW_JB_ARCHIVE="cfw_jb_input.tar.zst"
TEMP_DIR="$VM_DIR/.cfw_temp"
DISABLE_LAUNCHD_HOOK="${DISABLE_LAUNCHD_HOOK:-0}"

# ── Helpers ─────────────────────────────────────────────────────
die() {
    echo "[-] $*" >&2
    exit 1
}

check_prerequisites() {
    local missing=()
    command -v ldid &>/dev/null || missing+=("ldid (brew install ldid-procursus)")
    command -v xcrun &>/dev/null || missing+=("xcrun (Xcode command line tools)")
    if ((${#missing[@]} > 0)); then
        die "Missing required tools: ${missing[*]}. Run: make setup_tools"
    fi
}

ldid_sign() {
    local file="$1" bundle_id="${2:-}"
    local args=(-S -M "-K$VM_DIR/$CFW_INPUT/signcert.p12")
    [[ -n "$bundle_id" ]] && args+=("-I$bundle_id")
    ldid "${args[@]}" "$file"
}

ldid_sign_ent() {
    local file="$1" entitlements_plist="$2" bundle_id="${3:-}"
    local args=("-S$entitlements_plist" "-K$VM_DIR/$CFW_INPUT/signcert.p12")
    [[ -n "$bundle_id" ]] && args+=("-I$bundle_id")
    ldid "${args[@]}" "$file"
}

build_tweakloader() {
    local src="$SCRIPT_DIR/tweakloader/TweakLoader.m"
    local out="$TEMP_DIR/TweakLoader.dylib"
    local sdk cc

    [[ -f "$src" ]] || die "Missing tweak loader source at $src"

    sdk="$(xcrun --sdk iphoneos --show-sdk-path)"
    cc="$(xcrun --sdk iphoneos -f clang)"

    "$cc" -isysroot "$sdk" \
        -arch arm64 -arch arm64e \
        -miphoneos-version-min=15.0 \
        -dynamiclib \
        -fobjc-arc -O3 \
        -framework Foundation \
        -o "$out" \
        "$src"

    ldid_sign "$out"
    echo "$out"
}

# Build vpregister — registers JB apps via the containerized LaunchServices API on
# iOS 27, where -[LSApplicationWorkspace registerApplicationDictionary:] (uicache -a)
# is a deprecated no-op stub. Needs the lsd embedded-reg gate patch
# (cfw_patch_lsd_embedded_reg, applied by cfw_install.sh). Deployed to /cores and
# invoked by vphone_jb_setup.sh at first boot.
build_vpregister() {
    local src="$SCRIPT_DIR/vpregister/vpregister.m"
    local out="$TEMP_DIR/vpregister"
    local sdk cc

    [[ -f "$src" ]] || die "Missing vpregister source at $src"

    sdk="$(xcrun --sdk iphoneos --show-sdk-path)"
    cc="$(xcrun --sdk iphoneos -f clang)"

    "$cc" -isysroot "$sdk" \
        -arch arm64e \
        -miphoneos-version-min=15.0 \
        -fobjc-arc -Os \
        -framework Foundation \
        -Wl,-undefined,dynamic_lookup \
        -o "$out" \
        "$src"

    ldid_sign_ent "$out" "$SCRIPT_DIR/vphoned/entitlements.plist"
    echo "$out"
}

# Builds the libvcamcaptured.dylib injected into /usr/libexec/cameracaptured
# via the TweakLoader allowlist. Output goes to TEMP_DIR; caller copies the
# binary + companion plist to procursus/Library/MobileSubstrate/DynamicLibraries.
build_libvcamcaptured() {
    local src="$SCRIPT_DIR/vcamcaptured/libvcamcaptured.m"
    local out="$TEMP_DIR/libvcamcaptured.dylib"
    local sdk cc

    [[ -f "$src" ]] || die "Missing libvcamcaptured source at $src"

    sdk="$(xcrun --sdk iphoneos --show-sdk-path)"
    cc="$(xcrun --sdk iphoneos -f clang)"

    "$cc" -isysroot "$sdk" \
        -arch arm64e \
        -miphoneos-version-min=15.0 \
        -dynamiclib \
        -fobjc-arc -Os \
        -install_name /var/jb/usr/lib/libvcamcaptured.dylib \
        -framework CoreMedia \
        -framework CoreVideo \
        -framework Foundation \
        -o "$out" \
        "$src"

    ldid_sign "$out"
    echo "$out"
}

# Builds the libcamfix.dylib substrate plugin. Loaded into every process
# that links AVFoundation via TweakLoader's Filter.Frameworks key —
# Camera.app, third-party apps, anywhere the
# documented capture interface is used. Implements the photo-delivery
# path through CAMCaptureEngine + the preview/state guards that keep
# the viewfinder live on the virtual camera.
build_libcamfix() {
    local src="$SCRIPT_DIR/camfix/libcamfix.m"
    local out="$TEMP_DIR/libcamfix.dylib"
    local sdk cc

    [[ -f "$src" ]] || die "Missing libcamfix source at $src"

    sdk="$(xcrun --sdk iphoneos --show-sdk-path)"
    cc="$(xcrun --sdk iphoneos -f clang)"

    "$cc" -isysroot "$sdk" \
        -arch arm64e \
        -miphoneos-version-min=15.0 \
        -dynamiclib \
        -fobjc-arc -Os \
        -install_name /var/jb/Library/MobileSubstrate/DynamicLibraries/libcamfix.dylib \
        -framework AVFoundation \
        -framework CoreImage \
        -framework CoreGraphics \
        -framework CoreMedia \
        -framework CoreVideo \
        -framework Foundation \
        -framework ImageIO \
        -framework IOSurface \
        -framework MobileCoreServices \
        -framework Photos \
        -framework QuartzCore \
        -framework UIKit \
        -o "$out" \
        "$src"

    ldid_sign "$out"
    echo "$out"
}

get_boot_manifest_hash() {
    /bin/ls $MNT5 2>/dev/null | awk 'length($0)==96{print; exit}'
}

# ── Setup JB input resources ──────────────────────────────────
setup_cfw_jb_input() {
    [[ -d "$VM_DIR/$CFW_JB_INPUT" ]] && return
    local archive
    for search_dir in "$SCRIPT_DIR/resources" "$SCRIPT_DIR" "$VM_DIR"; do
        archive="$search_dir/$CFW_JB_ARCHIVE"
        if [[ -f "$archive" ]]; then
            echo "  Extracting $CFW_JB_ARCHIVE..."
            tar --zstd -xf "$archive" -C "$VM_DIR"
            return
        fi
    done
    die "JB mode: neither $CFW_JB_INPUT/ nor $CFW_JB_ARCHIVE found"
}

# ── Apply dev overlay (replace rpcserver_ios in iosbinpack64) ──
apply_dev_overlay() {
    local dev_bin
    for search_dir in "$SCRIPT_DIR/resources/cfw_dev" "$SCRIPT_DIR/cfw_dev"; do
        dev_bin="$search_dir/rpcserver_ios"
        if [[ -f "$dev_bin" ]]; then
            echo "  Applying dev overlay (rpcserver_ios)..."
            local iosbinpack="$VM_DIR/$CFW_INPUT/jb/iosbinpack64.tar"
            local tmpdir="$VM_DIR/.iosbinpack_tmp"
            mkdir -p "$tmpdir"
            tar -xf "$iosbinpack" -C "$tmpdir"
            cp "$dev_bin" "$tmpdir/iosbinpack64/usr/local/bin/rpcserver_ios"
            (cd "$tmpdir" && tar -cf "$iosbinpack" iosbinpack64)
            rm -rf "$tmpdir"
            return
        fi
    done
    die "Dev overlay not found (cfw_dev/rpcserver_ios)"
}

# The VM's Disk.img is attached on the host by cfw_install_host.sh; its APFS
# volumes are mounted here and every file is placed with plain cp/chmod/etc.
# (the VM is off — nothing runs "on the device").
: "${CFW_HOST_CONTAINER:?CFW_HOST_CONTAINER unset — run via cfw_install_host.sh}"
HOST_MNT="${CFW_HOST_MNT:-/private/tmp/cfwhost}"
MNT1="$HOST_MNT/mnt1"   # disk1s1 (System / rootfs)
MNT3="$HOST_MNT/mnt3"   # disk1s3
MNT5="$HOST_MNT/mnt5"   # disk1s5 (per-boot-manifest OS dir / procursus bootstrap)
TAR="$(command -v gtar 2>/dev/null || echo /opt/homebrew/bin/gtar)"  # macOS bsdtar lacks GNU tar flags
mkdir -p "$HOST_MNT"

# Mount an APFS volume of the attached image container at a host mount point.
mount_vol() {  # mount_vol <slice, e.g. s1> <mountpoint> [opts]
    local dev="/dev/${CFW_HOST_CONTAINER}$1" mnt="$2" opts="${3:-rw}"
    /bin/mkdir -p "$mnt"
    /sbin/mount | /usr/bin/grep -q " on $mnt " && return 0
    /sbin/mount_apfs -o "$opts" "$dev" "$mnt" 2>/dev/null || true
    /sbin/mount | /usr/bin/grep -q " on $mnt " || die "mount failed: $dev -> $mnt"
}

# ── Check JB prerequisites ────────────────────────────────────
command -v zstd >/dev/null 2>&1 || die "'zstd' not found (required for JB bootstrap phase)"

setup_cfw_jb_input
JB_INPUT_DIR="$VM_DIR/$CFW_JB_INPUT"
echo ""
echo "[+] JB input resources: $JB_INPUT_DIR"
check_prerequisites

mkdir -p "$TEMP_DIR"

# Mount the image's System volume (may already be mounted from base install)
mount_vol s1 "$MNT1"

# ═══════════ JB-1 PATCH LAUNCHD (JETSAM + DYLIB INJECTION) ════
echo ""
echo "[JB-1] Patching launchd (jetsam guard + hook injection)..."

if ! [[ -e "$MNT1/sbin/launchd.bak" ]]; then
    echo "  Creating backup..."
    /bin/cp $MNT1/sbin/launchd $MNT1/sbin/launchd.bak
fi

cp "$MNT1/sbin/launchd.bak" "$TEMP_DIR/launchd"

# Extract original entitlements before patching (must preserve for spawn permissions)
echo "  Extracting original entitlements..."
ldid -e "$TEMP_DIR/launchd" > "$TEMP_DIR/launchd.entitlements" 2>/dev/null || true
if [[ -s "$TEMP_DIR/launchd.entitlements" ]]; then
    echo "  [+] Preserved launchd entitlements"
else
    echo "  [!] No entitlements found on original launchd"
fi

# Injecting launchdhook into pid 1 is on by default. This boot-critical hook
# path has produced boot-analysis failures; set DISABLE_LAUNCHD_HOOK=1 to keep
# BaseBin deployed without loading /b from launchd.
if [[ "$DISABLE_LAUNCHD_HOOK" == "1" ]]; then
    echo "  [*] Skipping launchdhook dylib injection (DISABLE_LAUNCHD_HOOK=1)"
elif [[ -d "$JB_INPUT_DIR/basebin" ]]; then
    echo "  Injecting weak dylib load for /b (short launchdhook alias)..."
    "$PYTHON3" "$SCRIPT_DIR/patchers/cfw.py" inject-dylib "$TEMP_DIR/launchd" "/b"
else
    echo "  [!] BaseBin is missing; skipping launchdhook injection"
fi

"$PYTHON3" "$SCRIPT_DIR/patchers/cfw.py" patch-launchd-jetsam "$TEMP_DIR/launchd"

# Re-sign with original entitlements to avoid "operation not permitted" on spawn
if [[ -s "$TEMP_DIR/launchd.entitlements" ]]; then
    ldid -S"$TEMP_DIR/launchd.entitlements" -M "-K$VM_DIR/$CFW_INPUT/signcert.p12" "$TEMP_DIR/launchd"
else
    ldid_sign "$TEMP_DIR/launchd"
fi
cp -R "$TEMP_DIR/launchd" "$MNT1/sbin/launchd"
/bin/chmod 0755 $MNT1/sbin/launchd

echo "  [+] launchd patched"

# ═══════════ JB-2 INSTALL IOSBINPACK64 ════════════════════════
echo ""
echo "[JB-2] Installing iosbinpack64..."

apply_dev_overlay
cp -R "$VM_DIR/$CFW_INPUT/jb/iosbinpack64.tar" "$MNT1"
"$TAR" --preserve-permissions --no-overwrite-dir \
    -xf $MNT1/iosbinpack64.tar -C $MNT1
/bin/rm -f $MNT1/iosbinpack64.tar

echo "  [+] iosbinpack64 installed"

# ═══════════ JB-3 PATCH debugserver entitlements ════
echo ""
echo "[JB-3] Patching debugserver entitlements..."

cp "$MNT1/usr/libexec/debugserver" "$TEMP_DIR/debugserver"
ldid -e "$TEMP_DIR/debugserver" > "$TEMP_DIR/debugserver-entitlements.plist"
plutil -remove seatbelt-profiles "$TEMP_DIR/debugserver-entitlements.plist" || true
plutil -insert task_for_pid-allow -bool YES "$TEMP_DIR/debugserver-entitlements.plist" || true
ldid_sign_ent "$TEMP_DIR/debugserver" "$TEMP_DIR/debugserver-entitlements.plist"
cp -R "$TEMP_DIR/debugserver" "$MNT1/usr/libexec/debugserver"
/bin/chmod 0755 $MNT1/usr/libexec/debugserver

echo "  [+] debugserver entitlements patched"


# ═══════════ JB-3b CAMPO SANDBOX FIX (iOS 27 only) ════════════
# Grant Campo the backboard/frontboard mach-lookups the 26.4 temporary-sandbox denies (see 0_binary_patch_comparison.md #14).
# 27-gated on the mounted rootfs SystemVersion.plist: 26.x userlands don't need it and Campo.app exists there too.
CAMPO_BIN="$MNT1/Applications/Campo.app/Campo"
CAMPO_BASE_IOS=$(/usr/bin/plutil -extract ProductVersion raw -o - "$MNT1/System/Library/CoreServices/SystemVersion.plist" 2>/dev/null || true)
case "$CAMPO_BASE_IOS" in
27.*)
    if [[ -f "$CAMPO_BIN" ]]; then
        echo ""
        echo "[JB-3b] Granting Campo backboard/frontboard mach-lookup exceptions (iOS $CAMPO_BASE_IOS)..."
        cp "$CAMPO_BIN" "$TEMP_DIR/Campo"
        ldid -e "$TEMP_DIR/Campo" > "$TEMP_DIR/Campo.entitlements" 2>/dev/null || true
        if [[ -s "$TEMP_DIR/Campo.entitlements" ]]; then
            "$PYTHON3" "$SCRIPT_DIR/patchers/campo_mach_lookup_exceptions.py" "$TEMP_DIR/Campo.entitlements"
            ldid_sign_ent "$TEMP_DIR/Campo" "$TEMP_DIR/Campo.entitlements"
            cp -R "$TEMP_DIR/Campo" "$CAMPO_BIN"
            /bin/chmod 0755 "$CAMPO_BIN"
            echo "  [+] Campo re-signed with backboard/frontboard mach-lookup exceptions"
        else
            echo "  [!] Could not read Campo entitlements; skipping Campo sandbox fix"
        fi
    else
        echo "[JB-3b] Campo.app not present in this OS image; skipping Campo sandbox fix"
    fi
    ;;
*)
    echo "[JB-3b] skip Campo sandbox fix (base iOS ${CAMPO_BASE_IOS:-unknown} — 27-only)"
    ;;
esac


# ═══════════ EXP-JB-3.5 PATCH watchdogd hv_vmm_present cache ══
#
# Background: the kernel-side OID rename (KernelEXPPatchHvVmmRename)
# makes sysctlbyname("kern.hv_vmm_present", ...) return ENOENT on this
# image. watchdogd caches that answer at startup and uses it to decide
# whether to look for the IOWatchdog kext. The unpatched flow takes
# the "not on a VM" branch on ENOENT, fails to find the kext (it
# doesn't exist on the VM), calls _os_crash -> brk #1, and launchd's
# `_PanicOnCrash` knob in com.apple.watchdogd.plist escalates the
# resulting SIGTRAP to a kernel panic.
#
# Patch shape: two-instruction surgical edit at every site in
# watchdogd that has the canonical
#   adrp/add(kern.hv_vmm_present) -> bl _sysctlbyname -> cbnz w0,skip
#       -> cset wN,ne -> strb wN,[global]
# shape. The edit forces the cached byte to 1 regardless of the
# sysctl result, so the downstream branch at +0x58e0 takes watchdogd's
# pre-existing "detected virtual machine environment" clean-exit path.
# The patcher also recomputes the affected CodeDirectory slot hashes
# (cfw_macho_codesign) so TXM still accepts the modified pages on
# demand-page-in. We deliberately do NOT re-sign with ldid — the
# Apple-issued code-signing identifier ("com.apple.watchdogd") must be
# preserved for launchd boot-task identity validation.
echo ""
echo "[EXP-JB-3.5] Patching watchdogd hv_vmm_present cache..."

cp "$MNT1/usr/libexec/watchdogd" "$TEMP_DIR/watchdogd"
"$SCRIPT_DIR/patch_hv_vmm_userland.sh" watchdogd "$TEMP_DIR/watchdogd"
cp -R "$TEMP_DIR/watchdogd" "$MNT1/usr/libexec/watchdogd"
/bin/chmod 0755 $MNT1/usr/libexec/watchdogd

echo "  [+] watchdogd patched"


# ═══════════ JB-4 INSTALL PROCURSUS BOOTSTRAP ══════════════════
echo ""
echo "[JB-4] Installing procursus bootstrap..."

mount_vol s5 "$MNT5"
BOOT_HASH="$(get_boot_manifest_hash)"
[[ -n "$BOOT_HASH" ]] || die "Could not find 96-char boot manifest hash in $MNT5"
echo "  Boot manifest hash: $BOOT_HASH"

BOOTSTRAP_ZST="$JB_INPUT_DIR/jb/bootstrap-iphoneos-arm64.tar.zst"
SILEO_DEB="$JB_INPUT_DIR/jb/org.coolstar.sileo_2.5.1_iphoneos-arm64.deb"
[[ -f "$BOOTSTRAP_ZST" ]] || die "Missing $BOOTSTRAP_ZST"

BOOTSTRAP_TAR="$TEMP_DIR/bootstrap-iphoneos-arm64.tar"
zstd -d -f "$BOOTSTRAP_ZST" -o "$BOOTSTRAP_TAR"

cp -R "$BOOTSTRAP_TAR" "$MNT5/$BOOT_HASH/bootstrap-iphoneos-arm64.tar"
if [[ -f "$SILEO_DEB" ]]; then
    cp -R "$SILEO_DEB" "$MNT5/$BOOT_HASH/org.coolstar.sileo_2.5.1_iphoneos-arm64.deb"
fi

# ── Extra debs: download from manifest, then stage the whole cache ──────
echo "  Fetching extra debs..."
zsh "$SCRIPT_DIR/fetch_debs.sh" || true
DEBS_CACHE="${SCRIPT_DIR:h}/debs"
DEBS_DEST="$MNT5/$BOOT_HASH/debs"
/bin/rm -rf "$DEBS_DEST"
deb_count=0
for deb in "$DEBS_CACHE"/*.deb(N); do
    (( deb_count == 0 )) && /bin/mkdir -p "$DEBS_DEST"
    cp -R "$deb" "$DEBS_DEST/"
    deb_count=$((deb_count + 1))
done
if (( deb_count > 0 )); then
    echo "  [+] Staged $deb_count extra deb(s) for first-boot install"
else
    echo "  [=] No extra debs to stage"
fi

JB_DIR_NAME="jb-vphone"
/bin/rm -rf $MNT5/$BOOT_HASH/jb
/bin/rm -rf $MNT5/$BOOT_HASH/$JB_DIR_NAME
/bin/mkdir -p $MNT5/$BOOT_HASH/$JB_DIR_NAME
/bin/chmod 0755 $MNT5/$BOOT_HASH/$JB_DIR_NAME
/usr/sbin/chown 0:0 $MNT5/$BOOT_HASH/$JB_DIR_NAME
"$TAR" --preserve-permissions -xf $MNT5/$BOOT_HASH/bootstrap-iphoneos-arm64.tar \
    -C $MNT5/$BOOT_HASH/$JB_DIR_NAME/
/bin/mv $MNT5/$BOOT_HASH/$JB_DIR_NAME/var $MNT5/$BOOT_HASH/$JB_DIR_NAME/procursus
mv "$MNT5/$BOOT_HASH/$JB_DIR_NAME/procursus/jb"/*(N) "$MNT5/$BOOT_HASH/$JB_DIR_NAME/procursus" 2>/dev/null || true
/bin/rm -rf $MNT5/$BOOT_HASH/$JB_DIR_NAME/procursus/jb
/bin/rm -f $MNT5/$BOOT_HASH/bootstrap-iphoneos-arm64.tar
rm -f "$BOOTSTRAP_TAR"

# NOTE: /var/jb symlink is created on first normal boot by vphone_jb_setup.sh
# (Data volume is encrypted and not mountable at install time).

echo "  [+] procursus bootstrap installed"

# ═══════════ JB-4 DEPLOY BASEBIN HOOKS ═════════════════════════
BASEBIN_DIR="$JB_INPUT_DIR/basebin"

if [[ -d "$BASEBIN_DIR" ]]; then
    echo ""
    echo "[JB-4] Deploying BaseBin hooks to /cores/..."

    # Clean previous dylibs before re-uploading
    echo "  Cleaning old /cores/ dylibs..."
    /bin/rm -rf $MNT1/cores
    /bin/mkdir -p $MNT1/cores
    /bin/chmod 0755 $MNT1/cores

    # Install all pre-built dylibs from basebin payload
    for dylib in "$BASEBIN_DIR"/*.dylib; do
        [[ -f "$dylib" ]] || continue
        dylib_name="$(basename "$dylib")"
        echo "  Installing $dylib_name..."
        ldid_sign "$dylib"
        cp -R "$dylib" "$MNT1/cores/$dylib_name"
        /bin/chmod 0755 $MNT1/cores/$dylib_name
    done

    # Short alias for launchdhook (header space is tight)
    if [[ -f "$BASEBIN_DIR/launchdhook.dylib" ]]; then
        echo "  Installing short launchdhook alias at /b..."
        cp "$BASEBIN_DIR/launchdhook.dylib" "$TEMP_DIR/b"
        ldid_sign "$TEMP_DIR/b"
        /bin/rm -f $MNT1/b
        cp -R "$TEMP_DIR/b" "$MNT1/b"
        /bin/chmod 0755 $MNT1/b
    fi

    echo "  [+] BaseBin hooks deployed"
fi

# ═══════════ JB-4 INSTALL TWEAKLOADER ════════════════════════════
echo ""
echo "[JB-4] Building and installing TweakLoader..."

TWEAKLOADER_OUT="$(build_tweakloader)"
/bin/mkdir -p $MNT5/$BOOT_HASH/$JB_DIR_NAME/procursus/usr/lib
cp -R "$TWEAKLOADER_OUT" "$MNT5/$BOOT_HASH/$JB_DIR_NAME/procursus/usr/lib/TweakLoader.dylib"
/usr/sbin/chown 0:0 $MNT5/$BOOT_HASH/$JB_DIR_NAME/procursus/usr/lib/TweakLoader.dylib
/bin/chmod 0755 $MNT5/$BOOT_HASH/$JB_DIR_NAME/procursus/usr/lib/TweakLoader.dylib

echo "  [+] TweakLoader installed to procursus/usr/lib/TweakLoader.dylib"

# ═══════════ JB-4.1 INSTALL libvcamcaptured ═════════════════════════
# Inject dylib loaded into /usr/libexec/cameracaptured (via TweakLoader
# allowlist in TweakLoader.m's kVPhoneAllowedDaemonPaths). Hosts the
# synthetic FigCaptureSource + shm-frame reader paired with vphoned's
# vsock 1338 listener on the guest side.
echo ""
echo "[JB-4.1] Building and installing libvcamcaptured..."
LIBVCAM_OUT="$(build_libvcamcaptured)"
LIBVCAM_DIR="$MNT5/$BOOT_HASH/$JB_DIR_NAME/procursus/Library/MobileSubstrate/DynamicLibraries"
/bin/mkdir -p $LIBVCAM_DIR
cp -R "$LIBVCAM_OUT" "$LIBVCAM_DIR/libvcamcaptured.dylib"
/usr/sbin/chown 0:0 $LIBVCAM_DIR/libvcamcaptured.dylib
/bin/chmod 0755 $LIBVCAM_DIR/libvcamcaptured.dylib

# The plist tells TweakLoader to load the dylib only inside cameracaptured
# (Filter.Executables = ["cameracaptured"]); keep it next to the dylib.
LIBVCAM_PLIST="$SCRIPT_DIR/vcamcaptured/libvcamcaptured.plist"
if [[ -f "$LIBVCAM_PLIST" ]]; then
    cp -R "$LIBVCAM_PLIST" "$LIBVCAM_DIR/libvcamcaptured.plist"
    /bin/chmod 0644 $LIBVCAM_DIR/libvcamcaptured.plist
fi
echo "  [+] libvcamcaptured installed to procursus/Library/MobileSubstrate/DynamicLibraries/"

# ═══════════ JB-4.2 INSTALL libcamfix ═══════════════════════════════
# Substrate plugin loaded by TweakLoader into every process that links
# AVFoundation. The companion plist's Filter.Frameworks = ["AVFoundation"]
# tells TweakLoader to defer the dlopen until AVFoundation actually
# appears in the loaded image list (via _dyld_register_func_for_add_image),
# so processes that don't use AVF don't pay any cost.
echo ""
echo "[JB-4.2] Building and installing libcamfix..."
LIBCAMFIX_OUT="$(build_libcamfix)"
cp -R "$LIBCAMFIX_OUT" "$LIBVCAM_DIR/libcamfix.dylib"
/usr/sbin/chown 0:0 $LIBVCAM_DIR/libcamfix.dylib
/bin/chmod 0755 $LIBVCAM_DIR/libcamfix.dylib

LIBCAMFIX_PLIST="$SCRIPT_DIR/camfix/libcamfix.plist"
if [[ -f "$LIBCAMFIX_PLIST" ]]; then
    cp -R "$LIBCAMFIX_PLIST" "$LIBVCAM_DIR/libcamfix.plist"
    /bin/chmod 0644 $LIBVCAM_DIR/libcamfix.plist
fi
echo "  [+] libcamfix installed to procursus/Library/MobileSubstrate/DynamicLibraries/"

# ═══════════ JB-5 DEPLOY FIRST-BOOT SETUP ══════════════════════
echo ""
echo "[JB-5] Deploying first-boot setup..."

# Deploy first-boot JB setup script + LaunchDaemon
SETUP_SCRIPT="$SCRIPT_DIR/vphone_jb_setup.sh"
SETUP_PLIST="$SCRIPT_DIR/vphone_jb_setup.plist"
if [[ -f "$SETUP_SCRIPT" ]]; then
    cp -R "$SETUP_SCRIPT" "$MNT1/cores/vphone_jb_setup.sh"
    /bin/chmod 0755 $MNT1/cores/vphone_jb_setup.sh
    echo "  [+] vphone_jb_setup.sh -> /cores/"
fi
# vpregister: registers JB apps via the containerized LS API at first boot (uicache -a's
# registerApplicationDictionary is a deprecated no-op on iOS 27). Deployed ONLY on a 27
# base — it needs the 27-only lsd embedded-reg gate, and on 26.x/18.x uicache registers
# apps normally. Its /cores presence IS the runtime gate in vphone_jb_setup.sh (that
# script must NOT version-check on guest sw_vers — the hybrid guest does not reliably
# report the 27 userland version at first boot). Version read from the mounted rootfs
# SystemVersion.plist, the same source cfw_install.sh gates its 27 patches on.
JB_BASE_IOS=$(/usr/bin/plutil -extract ProductVersion raw -o - "$MNT1/System/Library/CoreServices/SystemVersion.plist" 2>/dev/null || true)
case "$JB_BASE_IOS" in
    27.*)
        VPREGISTER="$(build_vpregister)"
        if [[ -f "$VPREGISTER" ]]; then
            cp -R "$VPREGISTER" "$MNT1/cores/vpregister"
            /bin/chmod 0755 $MNT1/cores/vpregister
            echo "  [+] vpregister -> /cores/ (iOS $JB_BASE_IOS)"
        fi
        ;;
    *)
        echo "  [skip] vpregister (base iOS ${JB_BASE_IOS:-unknown} — 27-only; uicache registers apps on older bases)"
        ;;
esac
if [[ -f "$SETUP_PLIST" ]]; then
    cp -R "$SETUP_PLIST" "$MNT1/System/Library/LaunchDaemons/com.vphone.jb-setup.plist"
    /bin/chmod 0644 $MNT1/System/Library/LaunchDaemons/com.vphone.jb-setup.plist

    # Inject into launchd.plist so launchd starts it at boot
    echo "  Injecting com.vphone.jb-setup into launchd.plist..."
    cp "$MNT1/System/Library/xpc/launchd.plist" "$TEMP_DIR/launchd.plist"
    "$PYTHON3" -c "
import plistlib, sys
with open(sys.argv[1], 'rb') as f:
    target = plistlib.load(f)
with open(sys.argv[2], 'rb') as f:
    daemon = plistlib.load(f)
target.setdefault('LaunchDaemons', {})['/System/Library/LaunchDaemons/com.vphone.jb-setup.plist'] = daemon
with open(sys.argv[1], 'wb') as f:
    plistlib.dump(target, f, sort_keys=False)
" "$TEMP_DIR/launchd.plist" "$SETUP_PLIST"
    cp -R "$TEMP_DIR/launchd.plist" "$MNT1/System/Library/xpc/launchd.plist"
    /bin/chmod 0644 $MNT1/System/Library/xpc/launchd.plist
    echo "  [+] com.vphone.jb-setup.plist injected into launchd.plist"
fi

# ═══════════ EXP-JB-6 POST-RESTORE DT IDENTITY REWRITE ════════
#
# Apply the three restore-unsafe DT property edits that broke earlier
# attempts when applied at fw_patch time:
#   root/model        iPhone99,11 -> iPhone17,3
#   root/target-type  VPHONE600   -> D47
#   root/compatible   reordered to [D47AP, VPHONE600AP, AppleVirtualPlatformARM]
#
# These are restore-time-fatal (restored_external / iBoot's restore mode
# cross-checks model+target-type against the BuildManifest's signed
# identity) but NOT boot-time-fatal — the existing iBSS/iBEC/LLB
# image4_validate_property_callback bypass patches accept any IM4P
# contents on subsequent boots.
#
# $MNT5 is still mounted at this point in the install flow (the umount
# happens in the CLEANUP block below). We copy the live devicetree.img4
# out, patch it on the host, copy it back. Next boot, iBoot loads the
# modified DT, kernel populates machine_info from the new values, and
# sysctl hw.machine / hw.product / hw.model flip to iPhone17,3 / D47 /
# (whatever IOPlatformExpert resolves from compatible[0]=D47AP).
echo ""
echo "[EXP-JB-6] Post-restore DT identity rewrite..."

if [[ -z "$BOOT_HASH" ]]; then
    BOOT_HASH="$(get_boot_manifest_hash)"
fi
if [[ -z "$BOOT_HASH" ]]; then
    echo "  [-] BOOT_HASH not discoverable, skipping EXP-JB-6"
else
    JB6_DT_REMOTE="$MNT5/$BOOT_HASH/usr/standalone/firmware/devicetree.img4"
    JB6_DT_LOCAL="$TEMP_DIR/devicetree.img4"
    if [[ -e "$JB6_DT_REMOTE" ]]; then
        cp "$JB6_DT_REMOTE" "$JB6_DT_LOCAL"
        "$PYTHON3" "$SCRIPT_DIR/patchers/cfw_patch_post_restore_dt.py" "$JB6_DT_LOCAL"
        cp -R "$JB6_DT_LOCAL" "$JB6_DT_REMOTE"
        /usr/sbin/chown 0:0 $JB6_DT_REMOTE
        /bin/chmod 0644 $JB6_DT_REMOTE
        echo "  [+] devicetree.img4 rewritten in place"
    else
        echo "  [-] $JB6_DT_REMOTE not found, skipping EXP-JB-6"
    fi
fi

# ═══════════ EXP-JB-7 BUILD-VERSION REWRITE (SystemVersion.plist) ══
#
# OPT-IN. Only runs when SPOOF_BUILD is set in the environment (e.g.
# `make setup_machine JB=1 SPOOF_BUILD=23F77` or `make cfw_install_jb
# SPOOF_BUILD=23F77`). When SPOOF_BUILD is unset/empty the step is
# skipped entirely and the build identifier stays at whatever the IPSW
# shipped.
#
# What it does (when enabled): flips ProductBuildVersion in the two
# SystemVersion.plist files iOS reads for "Build" display and
# MGCopyAnswer("BuildVersion"):
#   /System/Library/CoreServices/SystemVersion.plist                       (rootfs)
#   /private/preboot/Cryptexes/OS/System/Library/CoreServices/SystemVersion.plist (Cryptex)
#
# Both are plain plist files (no Apple signature on individual plists),
# so no image4 / cdHash / TXM concerns. Both volumes are writable at
# install time:
#   $MNT1 (rootfs)  — writable before the install-time seal is established
#   $MNT5 (preboot) — apfs writable
#
# After this, Settings -> About -> Build, MG BuildVersion key, and every
# framework that reads SystemVersion.plist see the new identifier.
# `sysctl kern.osversion` still reports the kernel image's own build
# (e.g. 23B78 from the PCC vphone600/vresearch101 kernel) — that comes
# from a kernel global populated at boot from boot args, not from this
# plist.
if [[ -n "${SPOOF_BUILD:-}" ]]; then
    echo ""
    echo "[EXP-JB-7] Rewriting ProductBuildVersion to $SPOOF_BUILD in SystemVersion plists..."

    for jb7_remote in \
        "$MNT1/System/Library/CoreServices/SystemVersion.plist" \
        "$MNT5/Cryptexes/OS/System/Library/CoreServices/SystemVersion.plist"
    do
        if [[ -e "$jb7_remote" ]]; then
            jb7_local="$TEMP_DIR/$(echo "$jb7_remote" | tr '/' '_').plist"
            cp "$jb7_remote" "$jb7_local"
            "$PYTHON3" "$SCRIPT_DIR/patchers/cfw_patch_build_version.py" \
                "$jb7_local" "$SPOOF_BUILD"
            cp -R "$jb7_local" "$jb7_remote"
        else
            echo "  [-] $jb7_remote not found, skipping"
        fi
    done
else
    echo ""
    echo "[EXP-JB-7] Skipped — SPOOF_BUILD not set (pass SPOOF_BUILD=<id> to enable)"
fi

# ═══════════ CLEANUP ═════════════════════════════════════════
echo ""
echo "[*] Unmounting image volumes..."
/sbin/umount $MNT1 2>/dev/null || true
/sbin/umount $MNT3 2>/dev/null || true
/sbin/umount $MNT5 2>/dev/null || true

echo "[*] Cleaning up temp binaries..."
rm -f "$TEMP_DIR/launchd" \
    "$TEMP_DIR/bootstrap-iphoneos-arm64.tar"

echo ""
echo "[+] CFW + JB + EXP installation complete!"
echo "    Boot to apply changes."
echo "    After boot, SSH will be available on port 22222 (password: alpine)"
