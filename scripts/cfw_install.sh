#!/bin/zsh
# vphone-tier: dist
# cfw_install.sh — Install base CFW modifications on vphone.
#
# Installs Cryptexes, patches system binaries, installs jailbreak tools
# and configures LaunchDaemons for persistent SSH/VNC access.
#
# Files are placed directly on the VM's Disk.img volumes, which cfw_install_host.sh
# attaches and mounts on the host; the VM must be off.
#
# Safe to run multiple times — always patches from original .bak files,
# keeps decrypted Cryptex DMGs cached, handles already-mounted filesystems.
#
# Prerequisites:
#   - VM restored (make restore) and powered off
#   - /usr/bin/aea (macOS 12+) — the only external program this script runs
#   - vphone-cli built (make build) — every CFW patcher, the signer, the
#     archive reader and the prebuilt guest binaries come with it
#   - cfw_input/ or resources/cfw_input.tar.zst present
#
# Usage: make cfw_install
set -euo pipefail

# ── Restore caller's PATH — Nix /etc/zshenv resets PATH on zsh startup ─
[[ -n "${_VPHONE_PATH:-}" ]] && export PATH="$_VPHONE_PATH"

VM_DIR="${1:-.}"
SCRIPT_DIR="${0:a:h}"

# Resolve absolute paths
VM_DIR="$(cd "$VM_DIR" && pwd)"

# ── vphone-cli resolver — every CFW patcher this script calls lives in it ─
# Same order as scripts/cfw_install_host.sh and cfw-kit/run.sh: VPHONE_CLI_BIN
# when a vphone-cli subcommand invoked us, otherwise a dev tree or the .app,
# where scripts/ sits in Contents/Resources and the binaries are one level up
# in MacOS. Never `command -v` — the binary has to be the one we built beside
# these scripts, not whatever else is on PATH.
# Resolved up front, before anything is mounted or written: a missing binary
# should stop the run here, not halfway through with volumes attached.
VPHONE_CLI="${VPHONE_CLI_BIN:-}"
if [[ -z "$VPHONE_CLI" ]]; then
    for candidate in "${SCRIPT_DIR:h}/.build/release/vphone-cli" "${SCRIPT_DIR:h:h}/MacOS/vphone-cli"; do
        [[ -x "$candidate" ]] && { VPHONE_CLI="$candidate"; break }
    done
fi
[[ -x "$VPHONE_CLI" ]] || {
    echo "[-] cannot find vphone-cli (the CFW patchers live in it) — run 'make build'" >&2
    exit 1
}

# vphone-archive and vphone-cli are always installed side by side — in
# .build/release during development and in Contents/MacOS in the .app — so a
# sibling of the binary we just resolved is the whole lookup. It replaces the
# GNU tar and zstd this script used to reach for on PATH.
VPHONE_ARCHIVE="${VPHONE_CLI:h}/vphone-archive"
[[ -x "$VPHONE_ARCHIVE" ]] || {
    echo "[-] cannot find vphone-archive beside $VPHONE_CLI — run 'make build'" >&2
    exit 1
}

# The five iOS binaries this install puts in the guest are cross-compiled at
# BUILD time (scripts/guest_binaries.mk) and shipped, because compiling them
# here would make Xcode and the iPhoneOS SDK a requirement for running a VM.
# Contents/Resources/guest in the .app, .build/guest in a dev tree.
GUEST_BIN=""
for candidate in "${SCRIPT_DIR:h}/guest" "${SCRIPT_DIR:h}/.build/guest"; do
    [[ -d "$candidate" ]] && { GUEST_BIN="$candidate"; break }
done

# ── Configuration ───────────────────────────────────────────────
CFW_INPUT="cfw_input"
CFW_ARCHIVE="cfw_input.tar.zst"
TEMP_DIR="$VM_DIR/.cfw_temp"

# ── Helpers ─────────────────────────────────────────────────────
die() {
    echo "[-] $*" >&2
    exit 1
}

# ldid is gone from this script. `vphone-cli sign` writes the same bytes — the
# same CodeDirectory, the same synthesised designated requirement, no CMS and
# no ad-hoc flag — out of the system frameworks, and it ships inside the .app.
# ldid did not: it links Homebrew's libcrypto.3 and libplist-2.0.4, so a .app
# carrying it worked on the machine that built it and nowhere else.
#
# The three shapes this file ever called it in map one to one:
#     ldid -S -M -K<p12> [-I<id>] f   ->  guest_sign f [id]
#     ldid -S<ent> -M -K<p12> [-I] f  ->  guest_sign_ent f ent [id]
#     ldid -e f                       ->  guest_entitlements f
guest_sign() {
    local file="$1" bundle_id="${2:-}"
    local args=(--merge --pkcs12 "$VM_DIR/$CFW_INPUT/signcert.p12")
    [[ -n "$bundle_id" ]] && args+=(--identifier "$bundle_id")
    "$VPHONE_CLI" sign "${args[@]}" "$file"
}

# Like guest_sign but re-applies an entitlements plist (for binaries whose
# entitlements must survive the re-sign, e.g. diskimagesiod's embedded sandbox
# profile + private DA/apfs entitlements).
guest_sign_ent() {
    local file="$1" ent="$2" bundle_id="${3:-}"
    local args=(--entitlements "$ent" --merge --pkcs12 "$VM_DIR/$CFW_INPUT/signcert.p12")
    [[ -n "$bundle_id" ]] && args+=(--identifier "$bundle_id")
    "$VPHONE_CLI" sign "${args[@]}" "$file"
}

# `ldid -e`: the embedded entitlements of every slice, byte for byte and with
# nothing in between, because the output is redirected into a plist and fed
# straight back to guest_sign_ent.
guest_entitlements() {
    "$VPHONE_CLI" dump-entitlements "$1"
}

# `tar` in every shape this script used it. The compressor is detected from the
# file, so --zstd is not passed and cannot be passed wrongly; --warning= has no
# counterpart because nothing warns.
guest_untar() {   # guest_untar <archive> <dest> [extra flags…]
    local archive="$1" dest="$2"; shift 2
    "$VPHONE_ARCHIVE" extract -f "$archive" -C "$dest" "$@"
}

host_hdiutil() {
    local rc
    # SUDO_PASSWORD flow exports SUDO_ASKPASS: go straight to sudo -A so
    # hdiutil never runs unprivileged first (which triggers an auth prompt).
    [[ -n "${SUDO_ASKPASS:-}" ]] && { sudo -A hdiutil "$@"; return; }

    hdiutil "$@" && return 0
    rc=$?

    if sudo -n true 2>/dev/null; then
        sudo hdiutil "$@"
        return
    fi

    return "$rc"
}

# Detach a DMG mountpoint if currently mounted, ignore errors
safe_detach() {
    local mnt="$1"
    if mount | grep -Fq " on $mnt "; then
        host_hdiutil detach -force "$mnt" 2>/dev/null || true
    fi
}

assert_mount_under_vm() {
    local mnt="$1" label="${2:-mountpoint}"
    local abs_vm abs_mnt

    abs_vm="$(cd "$VM_DIR" && pwd -P)"
    abs_mnt="$(cd "$mnt" && pwd -P)"
    case "$abs_mnt/" in
        "$abs_vm/"*) ;;
        *) die "Unsafe ${label}: ${abs_mnt} (must be inside ${abs_vm})" ;;
    esac
}

# ── Find restore directory ─────────────────────────────────────
find_restore_dir() {
    for dir in "$VM_DIR"/iPhone*_Restore; do
        [[ -f "$dir/BuildManifest.plist" ]] && echo "$dir" && return
    done
    die "No restore directory found in $VM_DIR"
}

# ── Setup input resources ──────────────────────────────────────
setup_cfw_input() {
    [[ -d "$VM_DIR/$CFW_INPUT" ]] && return
    local archive
    for search_dir in "$SCRIPT_DIR/resources" "$SCRIPT_DIR" "$VM_DIR"; do
        archive="$search_dir/$CFW_ARCHIVE"
        if [[ -f "$archive" ]]; then
            echo "  Extracting $CFW_ARCHIVE..."
            guest_untar "$archive" "$VM_DIR"
            return
        fi
    done
    die "Neither $CFW_INPUT/ nor $CFW_ARCHIVE found"
}

# ── Check prerequisites ────────────────────────────────────────
# What used to be here was `command -v ipsw` and `command -v aea`. The first is
# gone: the one thing this script asked ipsw for was the SystemOS AEA key, and
# `vphone-cli fw aea-key` derives it from the archive's own auth data. The
# second stays, because /usr/bin/aea is part of macOS — but it is called by
# absolute path now, so there is nothing left to look up.
require_firmware_tools() {
    [[ -x /usr/bin/aea ]] || die "/usr/bin/aea missing (it ships with macOS 12+)"
    [[ -n "$GUEST_BIN" ]] || die "no prebuilt guest binaries — run 'make build'"
    echo "[*] Patchers: $VPHONE_CLI cfw"
}

# ── Cleanup trap (unmount DMGs on error) ───────────────────────
cleanup_on_exit() {
    safe_detach "$TEMP_DIR/mnt_sysos" 2>/dev/null || true
    safe_detach "$TEMP_DIR/mnt_appos" 2>/dev/null || true
}
trap cleanup_on_exit EXIT

# The VM's Disk.img is attached on the host by cfw_install_host.sh; its APFS
# volumes are mounted here and every file is placed with plain cp/chmod/etc.
# (the VM is off — nothing runs "on the device").
: "${CFW_HOST_CONTAINER:?CFW_HOST_CONTAINER unset — run via cfw_install_host.sh}"
HOST_MNT="${CFW_HOST_MNT:-/private/tmp/cfwhost}"
MNT1="$HOST_MNT/mnt1"   # disk1s1 (System / rootfs)
MNT3="$HOST_MNT/mnt3"   # disk1s3
mkdir -p "$HOST_MNT"

# Mount an APFS volume of the attached image container at a host mount point.
mount_vol() {  # mount_vol <slice, e.g. s1> <mountpoint> [opts]
    local dev="/dev/${CFW_HOST_CONTAINER}$1" mnt="$2" opts="${3:-rw}"
    /bin/mkdir -p "$mnt"
    /sbin/mount | /usr/bin/grep -q " on $mnt " && return 0
    /sbin/mount_apfs -o "$opts" "$dev" "$mnt" 2>/dev/null || true
    /sbin/mount | /usr/bin/grep -q " on $mnt " || die "mount failed: $dev -> $mnt"
}

# ════════════════════════════════════════════════════════════════
# Main
# ════════════════════════════════════════════════════════════════
echo "[*] cfw_install.sh — Installing CFW on vphone..."

require_firmware_tools

RESTORE_DIR=$(find_restore_dir)
echo "[+] Restore directory: $RESTORE_DIR"

setup_cfw_input
INPUT_DIR="$VM_DIR/$CFW_INPUT"
echo "[+] Input resources: $INPUT_DIR"

mkdir -p "$TEMP_DIR"

# ── Parse Cryptex paths from BuildManifest ─────────────────────
echo ""
echo "[*] Parsing iPhone BuildManifest for Cryptex paths..."
CRYPTEX_PATHS=$("$VPHONE_CLI" cfw cryptex-paths "$RESTORE_DIR/iPhone-BuildManifest.plist")
CRYPTEX_SYSOS=$(echo "$CRYPTEX_PATHS" | head -1)
CRYPTEX_APPOS=$(echo "$CRYPTEX_PATHS" | tail -1)
echo "  SystemOS: $CRYPTEX_SYSOS"
echo "  AppOS:    $CRYPTEX_APPOS"

# ═══════════ 1/7 INSTALL CRYPTEX ══════════════════════════════
echo ""
echo "[1/7] Installing Cryptex (SystemOS + AppOS)..."

# Mount the image's System volume first to check existing state
echo "  Mounting rootfs rw..."
mount_vol s1 "$MNT1"

# Check if Cryptexes already exist on the volume (skip the slow copy if so).
# ls only runs when the dir exists, so its failure can't trip set -e/pipefail
# (on a fresh install these dirs don't exist yet → counts stay 0).
CRYPTEX_OS_COUNT=0
CRYPTEX_APP_COUNT=0
[[ -d "$MNT1/System/Cryptexes/OS" ]]  && CRYPTEX_OS_COUNT=$(/bin/ls "$MNT1/System/Cryptexes/OS/"  | /usr/bin/wc -l | tr -d ' ')
[[ -d "$MNT1/System/Cryptexes/App" ]] && CRYPTEX_APP_COUNT=$(/bin/ls "$MNT1/System/Cryptexes/App/" | /usr/bin/wc -l | tr -d ' ')

if [[ "${CRYPTEX_OS_COUNT:-0}" -gt 0 && "${CRYPTEX_APP_COUNT:-0}" -gt 0 ]]; then
    echo "  [*] Cryptexes already installed (OS=${CRYPTEX_OS_COUNT} entries, App=${CRYPTEX_APP_COUNT} entries), skipping"

    # Still ensure dyld symlinks exist
    /bin/ln -sf ../../../System/Cryptexes/OS/System/Library/Caches/com.apple.dyld \
        $MNT1/System/Library/Caches/com.apple.dyld
    /bin/ln -sf ../../../../System/Cryptexes/OS/System/DriverKit/System/Library/dyld \
        $MNT1/System/DriverKit/System/Library/dyld

    echo "  [+] Cryptex skipped (already present)"
else
    SYSOS_DMG="$TEMP_DIR/CryptexSystemOS.dmg"
    APPOS_DMG="$TEMP_DIR/CryptexAppOS.dmg"
    MNT_SYSOS="$TEMP_DIR/mnt_sysos"
    MNT_APPOS="$TEMP_DIR/mnt_appos"

    # Decrypt SystemOS AEA (cached — skip if already decrypted)
    if [[ ! -f "$SYSOS_DMG" ]]; then
        echo "  Extracting AEA key..."
        AEA_KEY=$("$VPHONE_CLI" fw aea-key "$RESTORE_DIR/$CRYPTEX_SYSOS")
        echo "  key: $AEA_KEY"
        echo "  Decrypting SystemOS..."
        /usr/bin/aea decrypt -i "$RESTORE_DIR/$CRYPTEX_SYSOS" -o "$SYSOS_DMG" -key-value "$AEA_KEY"
    else
        echo "  Using cached SystemOS DMG"
    fi

    # Copy AppOS (unencrypted, cached)
    if [[ ! -f "$APPOS_DMG" ]]; then
        cp "$RESTORE_DIR/$CRYPTEX_APPOS" "$APPOS_DMG"
    else
        echo "  Using cached AppOS DMG"
    fi

    # Detach any leftover mounts from previous runs
    safe_detach "$MNT_SYSOS"
    safe_detach "$MNT_APPOS"
    mkdir -p "$MNT_SYSOS" "$MNT_APPOS"
    assert_mount_under_vm "$MNT_SYSOS" "SystemOS mountpoint"
    assert_mount_under_vm "$MNT_APPOS" "AppOS mountpoint"

    echo "  Mounting SystemOS..."
    host_hdiutil attach -mountpoint "$MNT_SYSOS" "$SYSOS_DMG" -nobrowse -owners off \
        || die "Failed to mount SystemOS DMG. Run 'sudo -v' in a terminal and retry if hdiutil needs administrator privileges."
    echo "  Mounting AppOS..."
    host_hdiutil attach -mountpoint "$MNT_APPOS" "$APPOS_DMG" -nobrowse -owners off \
        || die "Failed to mount AppOS DMG. Run 'sudo -v' in a terminal and retry if hdiutil needs administrator privileges."

    /bin/rm -rf $MNT1/System/Cryptexes/App $MNT1/System/Cryptexes/OS
    /bin/mkdir -p $MNT1/System/Cryptexes/App $MNT1/System/Cryptexes/OS
    /bin/chmod 0755 $MNT1/System/Cryptexes/App $MNT1/System/Cryptexes/OS

    # Copy Cryptex files onto the volume
    echo "  Copying Cryptexes..."
    cp -R "$MNT_SYSOS/." "$MNT1/System/Cryptexes/OS"
    cp -R "$MNT_APPOS/." "$MNT1/System/Cryptexes/App"

    # Create dyld symlinks (ln -sf is idempotent)
    echo "  Creating dyld symlinks..."
    /bin/ln -sf ../../../System/Cryptexes/OS/System/Library/Caches/com.apple.dyld \
        $MNT1/System/Library/Caches/com.apple.dyld
    /bin/ln -sf ../../../../System/Cryptexes/OS/System/DriverKit/System/Library/dyld \
        $MNT1/System/DriverKit/System/Library/dyld

    # Unmount Cryptex DMGs
    echo "  Unmounting Cryptex DMGs..."
    safe_detach "$MNT_SYSOS"
    safe_detach "$MNT_APPOS"

    echo "  [+] Cryptex installed"
fi

# Some userland versions send an IOMobileFramebuffer SwapEnd state whose size
# differs from what the PCC vphone600 userclient expects (an exact
# checkStructureInputSize check), so SwapEnd returns kIOReturnBadArgument and
# the host VZ display stays black (guest still renders; visible over VNC).
#
# The accepted size is a property of the BASE KERNEL, not the userland:
#   - 26.1 base: userclient expects 0x560
#   - 26.4 base (xnu-12377, current): userclient expects 0x588
# Reliably reading it from the kernelcache needs the IOMFB userclient dispatch
# table (a blind shape-scan is ambiguous — 8 candidates), so until that dynamic
# detection lands we key the target off the userland version as a proxy for the
# validated base pairing:
#   - 27.x runs on the 26.4 base           -> 0x588
#   - 26.0/26.0.1 and 18.x validated on 26.1 base -> 0x560
# Known userland-sent sizes: 18.x -> 0x514, 26.0/26.0.1 -> 0x548, 27.0 -> 0x6e0.
# Patch only that immediate in the installed DSC; the patcher is semantic +
# idempotent (rewrites the SwapEnd size to the target, no-op if already there).
# NOTE: iOS 27 is NOT handled by the size-truncation path — its swap struct
# (0x6e0) has a new layout, and more fundamentally 27 defaults the paravirt
# display's present to IOMFB's `_virt_*` callback path, which never enters the
# userclient at all (method 5 is never called), so no size change would help.
# iOS 27 instead gets `patch-iomfb-force-kern` below, which retargets IOMFB's
# public Swap* trampolines to their `_kern_*` (method-5) siblings — the path the
# 26.4 paravirt GPU scans out to the host — paired with the KernelJBPatchIomfbSwap
# kernel patches that make the userclient accept 27's native 0x6e0 struct.
IOS_VERSION=$(/usr/bin/plutil -extract ProductVersion raw -o - "$MNT1/System/Library/CoreServices/SystemVersion.plist" 2>/dev/null || true)
DSC_DIR="$MNT1/System/Cryptexes/OS/System/Library/Caches/com.apple.dyld"
case "$IOS_VERSION" in
    26.0*|18.*)
        echo "  [*] Patching IOMobileFramebuffer SwapEnd payload size (iOS $IOS_VERSION -> 0x560)..."
        [[ -d "$DSC_DIR" ]] || die "dyld cache dir missing: $DSC_DIR"
        "$VPHONE_CLI" cfw patch-iomfb-swapend "$DSC_DIR" --target-size 0x560
        ;;
    27.*)
        echo "  [*] Forcing IOMobileFramebuffer present onto the kern (method-5) path (iOS $IOS_VERSION)..."
        [[ -d "$DSC_DIR" ]] || die "dyld cache dir missing: $DSC_DIR"
        "$VPHONE_CLI" cfw patch-iomfb-force-kern "$DSC_DIR"
        ;;
esac

# iOS-27-only DSC patches (hard-gated — a 26.x/18.x base applies neither).
#  - maxSlide: iOS 27's dyld shared cache nearly fills the vphone600 26.x kernel's
#    fixed 6 GiB shared region. The kernel reserves the cache's mapped span PLUS the
#    cache-header maxSlide (512 MiB); iOS 27.0 (~5.95 GiB span + 512 MiB) overflows
#    0x180000000, so _shared_region_map_and_slide returns ENOMEM, dyld cannot map
#    libSystem, and launchd (pid 1) panics at boot. Zero maxSlide so the cache maps
#    at slide 0. (The patcher also self-gates on the actual span, but older userlands
#    fit with full slide and never need it — so it is not run there at all.)
#  - lsd embedded-registration gate: opens lsd's containerized-registration path so
#    the iOS-27 vpregister first-boot tool can register JB apps (uicache's
#    registerApplicationDictionary is a no-op stub on 27). Not needed on 26.x/18.x,
#    where uicache registers apps normally.
#  - xpc LWCR self-check: iOS 27's libxpc brk-aborts when its Lightweight Code
#    Requirement matcher returns the contradictory (matched=0, error_code=MATCH) pair
#    that our JB code-signing environment produces. That crash-loops every daemon which
#    pins an entitlement peer-requirement (intelligencetasksd/searchpartyd/transparencyd/
#    bluetoothd/...). Absent on 26.x/18.x libxpc (self-gating patcher no-ops there).
# FORCE_DSC_MAXSLIDE=1 (default 0): opt in to zeroing maxSlide on non-27 bases,
# whose caches fit and would otherwise self-gate to a no-op (--force bypasses that).
FORCE_DSC_MAXSLIDE="${FORCE_DSC_MAXSLIDE:-0}"
case "$IOS_VERSION" in
    27.*)
        if [[ -d "$DSC_DIR" ]]; then
            echo "  [*] Checking dyld cache maxSlide vs kernel shared region..."
            "$VPHONE_CLI" cfw patch-dsc-maxslide "$DSC_DIR"
            echo "  [*] Patching lsd embedded-registration gate (iOS 27 app registration)..."
            "$VPHONE_CLI" cfw patch-lsd-embedded-reg "$DSC_DIR"
            echo "  [*] Patching libxpc LWCR self-check (iOS 27 daemon crash-loop)..."
            "$VPHONE_CLI" cfw patch-xpc-lwcr "$DSC_DIR"
            echo "  [*] Patching os_lockdown_mode_enabled (missing MAC sysctl -> launchd abort)..."
            "$VPHONE_CLI" cfw patch-lockdown-mode "$DSC_DIR"
        fi
        ;;
    *)
        if [[ "$FORCE_DSC_MAXSLIDE" == "1" && -d "$DSC_DIR" ]]; then
            echo "  [*] Forcing dyld cache maxSlide=0 (opt-in FORCE_DSC_MAXSLIDE=1; base iOS ${IOS_VERSION:-unknown})..."
            "$VPHONE_CLI" cfw patch-dsc-maxslide "$DSC_DIR" --force
        fi
        ;;
esac

# ═══════════ 2/7 PATCH SEPUTIL ════════════════════════════════
echo ""
echo "[2/7] Patching seputil..."

# Always patch from .bak (original unpatched binary)
if ! [[ -e "$MNT1/usr/libexec/seputil.bak" ]]; then
    echo "  Creating backup..."
    /bin/cp $MNT1/usr/libexec/seputil $MNT1/usr/libexec/seputil.bak
fi

cp "$MNT1/usr/libexec/seputil.bak" "$TEMP_DIR/seputil"
"$VPHONE_CLI" cfw patch-seputil "$TEMP_DIR/seputil"
guest_sign "$TEMP_DIR/seputil" "com.apple.seputil"
cp -R "$TEMP_DIR/seputil" "$MNT1/usr/libexec/seputil"
/bin/chmod 0755 $MNT1/usr/libexec/seputil

# ── DDI (/System/Developer) auto-mount — diskimagesiod (iOS 27 only) ──
# Force -[DIDiskArb isMountCompleteWithExpectedCount:diskTracker:] → YES so
# MobileStorageMounter proceeds to mount the iOS-27 personalized DDI (its
# waitForDAMount otherwise hangs forever on the 26.4 vphone600 hybrid: only some
# IOMedia appear to diskimagesiod's DA session + DA never auto-mounts). Pairs
# with the DiskImages2 ABI + sandbox mac_policy_ops[124] JB kernel patches.
# Entitlements (embedded sandbox profile + private DA/apfs) preserved on re-sign.
# Gated to 27.*: on a version-matched userland the native waitForDAMount completes
# correctly, and forcing the wait to return early could race the real mount — so
# it is NOT applied there (uses the same $IOS_VERSION as the DSC patches above).
case "$IOS_VERSION" in
    27.*)
        echo "  Patching diskimagesiod (DDI auto-mount, iOS $IOS_VERSION)..."
        if ! [[ -e "$MNT1/usr/libexec/diskimagesiod.bak" ]]; then
            /bin/cp "$MNT1/usr/libexec/diskimagesiod" "$MNT1/usr/libexec/diskimagesiod.bak"
        fi
        guest_entitlements "$MNT1/usr/libexec/diskimagesiod.bak" > "$TEMP_DIR/diskimagesiod.ent.plist"
        cp "$MNT1/usr/libexec/diskimagesiod.bak" "$TEMP_DIR/diskimagesiod"
        "$VPHONE_CLI" cfw patch-diskimagesiod "$TEMP_DIR/diskimagesiod"
        guest_sign_ent "$TEMP_DIR/diskimagesiod" "$TEMP_DIR/diskimagesiod.ent.plist" "com.apple.diskimagesiod"
        cp -R "$TEMP_DIR/diskimagesiod" "$MNT1/usr/libexec/diskimagesiod"
        /bin/chmod 0755 "$MNT1/usr/libexec/diskimagesiod"
        ;;
esac

# Rename gigalocker (mv to same name is fine on re-run)
echo "  Renaming gigalocker..."
mount_vol s3 "$MNT3"
mv "$MNT3"/*.gl(N) "$MNT3/AA.gl" 2>/dev/null || true

echo "  [+] seputil patched"

# ═══════════ 3/7 INSTALL GPU DRIVER ══════════════════════════
echo ""
echo "[3/7] Installing AppleParavirtGPUMetalIOGPUFamily..."

cp -R "$INPUT_DIR/custom/AppleParavirtGPUMetalIOGPUFamily.tar" "$MNT1"
guest_untar "$MNT1/AppleParavirtGPUMetalIOGPUFamily.tar" "$MNT1" \
    --preserve-permissions --no-overwrite-dir

BUNDLE="$MNT1/System/Library/Extensions/AppleParavirtGPUMetalIOGPUFamily.bundle"
# Clean macOS resource fork files (._* files from tar xattrs)
find $BUNDLE -name '._*' -delete 2>/dev/null || true
/usr/sbin/chown -R 0:0 $BUNDLE
/bin/chmod 0755 $BUNDLE
/bin/chmod 0755 $BUNDLE/libAppleParavirtCompilerPluginIOGPUFamily.dylib
/bin/chmod 0755 $BUNDLE/AppleParavirtGPUMetalIOGPUFamily
/bin/chmod 0755 $BUNDLE/_CodeSignature
/bin/chmod 0644 $BUNDLE/_CodeSignature/CodeResources
/bin/chmod 0644 $BUNDLE/Info.plist
/bin/rm -f $MNT1/AppleParavirtGPUMetalIOGPUFamily.tar

echo "  [+] GPU driver installed"

# ═══════════ 4/7 INSTALL IOSBINPACK64 ════════════════════════
echo ""
echo "[4/7] Installing iosbinpack64..."

cp -R "$INPUT_DIR/jb/iosbinpack64.tar" "$MNT1"
guest_untar "$MNT1/iosbinpack64.tar" "$MNT1" --preserve-permissions --no-overwrite-dir
/bin/rm -f $MNT1/iosbinpack64.tar

# dropbear host keys are generated on first boot by dropbear -R; just ensure
# the key directory exists for it to write into.
/bin/mkdir -p $MNT3/dropbear

echo "  [+] iosbinpack64 installed"

# ═══════════ 5/7 PATCH LAUNCHD_CACHE_LOADER ══════════════════
echo ""
echo "[5/7] Patching launchd_cache_loader..."

# Always patch from .bak (original unpatched binary)
if ! [[ -e "$MNT1/usr/libexec/launchd_cache_loader.bak" ]]; then
    echo "  Creating backup..."
    /bin/cp $MNT1/usr/libexec/launchd_cache_loader $MNT1/usr/libexec/launchd_cache_loader.bak
fi

cp "$MNT1/usr/libexec/launchd_cache_loader.bak" "$TEMP_DIR/launchd_cache_loader"
"$VPHONE_CLI" cfw patch-launchd-cache-loader "$TEMP_DIR/launchd_cache_loader"
guest_sign "$TEMP_DIR/launchd_cache_loader" "com.apple.launchd_cache_loader"
cp -R "$TEMP_DIR/launchd_cache_loader" "$MNT1/usr/libexec/launchd_cache_loader"
/bin/chmod 0755 $MNT1/usr/libexec/launchd_cache_loader

echo "  [+] launchd_cache_loader patched"

# ═══════════ 6/7 PATCH MOBILEACTIVATIOND ═════════════════════
echo ""
echo "[6/7] Patching mobileactivationd..."

# Always patch from .bak (original unpatched binary)
if ! [[ -e "$MNT1/usr/libexec/mobileactivationd.bak" ]]; then
    echo "  Creating backup..."
    /bin/cp $MNT1/usr/libexec/mobileactivationd $MNT1/usr/libexec/mobileactivationd.bak
fi

cp "$MNT1/usr/libexec/mobileactivationd.bak" "$TEMP_DIR/mobileactivationd"
"$VPHONE_CLI" cfw patch-mobileactivationd "$TEMP_DIR/mobileactivationd"
guest_sign "$TEMP_DIR/mobileactivationd"
cp -R "$TEMP_DIR/mobileactivationd" "$MNT1/usr/libexec/mobileactivationd"
/bin/chmod 0755 $MNT1/usr/libexec/mobileactivationd

echo "  [+] mobileactivationd patched"

# ═══════════ 7/7 LAUNCHDAEMONS + LAUNCHD.PLIST ══════════════
echo ""
echo "[7/7] Installing LaunchDaemons..."

# Install vphoned (vsock HID injector daemon).
#
# It used to be cross-compiled right here, out of .m sources shipped inside the
# .app, whenever they looked newer than the binary — which made Xcode and the
# iPhoneOS SDK a requirement for installing CFW onto a VM. It is built at build
# time now (scripts/guest_binaries.mk) and shipped compiled. Signing stays here,
# because it uses this VM's own cfw_input/signcert.p12.
VPHONED_SRC="$SCRIPT_DIR/vphoned"
VPHONED_BIN="$GUEST_BIN/vphoned"
[[ -f "$VPHONED_BIN" ]] || die "missing prebuilt vphoned at $VPHONED_BIN — run 'make build'"
cp "$VPHONED_BIN" "$TEMP_DIR/vphoned"
guest_sign_ent "$TEMP_DIR/vphoned" "$VPHONED_SRC/entitlements.plist"
cp -R "$TEMP_DIR/vphoned" "$MNT1/usr/bin/vphoned"
/bin/chmod 0755 $MNT1/usr/bin/vphoned
# Keep a copy of the signed binary for host-side auto-update
cp "$TEMP_DIR/vphoned" "$VM_DIR/.vphoned.signed"
echo "  [+] vphoned installed (signed copy at .vphoned.signed)"

# Send daemon plists (overwrite on re-run)
for plist in bash.plist dropbear.plist trollvnc.plist rpcserver_ios.plist; do
    plist_src="$INPUT_DIR/jb/LaunchDaemons/$plist"
    if [[ "$plist" == "dropbear.plist" ]]; then
        plist_src="$TEMP_DIR/dropbear.plist"
        cp "$INPUT_DIR/jb/LaunchDaemons/dropbear.plist" "$plist_src"
        "$VPHONE_CLI" cfw patch-dropbear-plist "$plist_src"
    fi
    cp -R "$plist_src" "$MNT1/System/Library/LaunchDaemons/"
    /bin/chmod 0644 $MNT1/System/Library/LaunchDaemons/$plist
done
cp -R "$VPHONED_SRC/vphoned.plist" "$MNT1/System/Library/LaunchDaemons/"
/bin/chmod 0644 $MNT1/System/Library/LaunchDaemons/vphoned.plist

# Always patch launchd.plist from .bak (original)
echo "  Patching launchd.plist..."
if ! [[ -e "$MNT1/System/Library/xpc/launchd.plist.bak" ]]; then
    echo "  Creating backup..."
    /bin/cp $MNT1/System/Library/xpc/launchd.plist $MNT1/System/Library/xpc/launchd.plist.bak
fi

cp "$MNT1/System/Library/xpc/launchd.plist.bak" "$TEMP_DIR/launchd.plist"
cp "$VPHONED_SRC/vphoned.plist" "$INPUT_DIR/jb/LaunchDaemons/"
"$VPHONE_CLI" cfw inject-daemons "$TEMP_DIR/launchd.plist" "$INPUT_DIR/jb/LaunchDaemons"
cp -R "$TEMP_DIR/launchd.plist" "$MNT1/System/Library/xpc/launchd.plist"
/bin/chmod 0644 $MNT1/System/Library/xpc/launchd.plist

echo "  [+] LaunchDaemons installed"

# ═══════════ CLEANUP ═════════════════════════════════════════
echo ""
echo "[*] Unmounting image volumes..."
/sbin/umount $MNT1 2>/dev/null || true
/sbin/umount $MNT3 2>/dev/null || true

echo "[*] Cleaning up temp..."
rm -rf "$TEMP_DIR"

echo ""
echo "[+] CFW installation complete!"
echo "    Boot to apply changes."
echo "    After boot, SSH will be available on port 22222 (password: alpine)"
