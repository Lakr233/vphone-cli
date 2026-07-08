#!/bin/zsh
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
#   - `ipsw` tool installed (brew install blacktop/tap/ipsw)
#   - `aea` tool available (macOS 12+)
#   - Python: make setup_venv && source .venv/bin/activate
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

# ── Python resolver — prefer project venv over whatever is in PATH ─
# Resolves to .venv/bin/python3 relative to the project root (parent of
# scripts/), falling back to the system python3 when the venv is absent.
# Every python3 invocation in this script uses $PYTHON3 so that running
# `make cfw_install` standalone (without setup_machine.sh exporting PATH)
# still uses the correctly set-up venv interpreter.
_resolve_python3() {
    local venv_py="${SCRIPT_DIR:h}/.venv/bin/python3"
    if [[ -x "$venv_py" ]]; then
        echo "$venv_py"
    else
        command -v python3 || true
    fi
}
PYTHON3="$(_resolve_python3)"

# ── Configuration ───────────────────────────────────────────────
CFW_INPUT="cfw_input"
CFW_ARCHIVE="cfw_input.tar.zst"
TEMP_DIR="$VM_DIR/.cfw_temp"

# ── Helpers ─────────────────────────────────────────────────────
die() {
    echo "[-] $*" >&2
    exit 1
}

check_prerequisites() {
    local missing=()
    command -v ldid &>/dev/null || missing+=("ldid (brew install ldid-procursus)")
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
            tar --zstd -xf "$archive" -C "$VM_DIR"
            return
        fi
    done
    die "Neither $CFW_INPUT/ nor $CFW_ARCHIVE found"
}

# ── Check prerequisites ────────────────────────────────────────
check_prereqs() {
    command -v ipsw >/dev/null 2>&1 || die "'ipsw' not found. Install: brew install blacktop/tap/ipsw"
    command -v aea >/dev/null 2>&1 || die "'aea' not found (requires macOS 12+)"
    [[ -x "$PYTHON3" ]] || die "python3 not found (tried: $PYTHON3). Run: make setup_venv"
    echo "[*] Python: $PYTHON3 ($("$PYTHON3" --version 2>&1))"
    local py_err
    py_err="$("$PYTHON3" -c "import capstone, keystone" 2>&1)" || {
        die "Missing Python deps (using $PYTHON3).\n  Error: ${py_err}\n  Fix:   source ${SCRIPT_DIR:h}/.venv/bin/activate && pip install capstone keystone-engine\n  Or:    make setup_venv"
    }
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

# ════════════════════════════════════════════════════════════════
# Main
# ════════════════════════════════════════════════════════════════
echo "[*] cfw_install.sh — Installing CFW on vphone..."

check_prereqs

RESTORE_DIR=$(find_restore_dir)
echo "[+] Restore directory: $RESTORE_DIR"

setup_cfw_input
INPUT_DIR="$VM_DIR/$CFW_INPUT"
echo "[+] Input resources: $INPUT_DIR"
check_prerequisites

mkdir -p "$TEMP_DIR"

# ── Parse Cryptex paths from BuildManifest ─────────────────────
echo ""
echo "[*] Parsing iPhone BuildManifest for Cryptex paths..."
CRYPTEX_PATHS=$("$PYTHON3" "$SCRIPT_DIR/patchers/cfw.py" cryptex-paths "$RESTORE_DIR/iPhone-BuildManifest.plist")
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
        AEA_KEY=$(ipsw fw aea --key "$RESTORE_DIR/$CRYPTEX_SYSOS")
        echo "  key: $AEA_KEY"
        echo "  Decrypting SystemOS..."
        aea decrypt -i "$RESTORE_DIR/$CRYPTEX_SYSOS" -o "$SYSOS_DMG" -key-value "$AEA_KEY"
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

# iOS 26.0 and 26.0.1 IOMobileFramebuffer send the older 0x548-byte SwapEnd
# payload, but the PCC vphone600 userclient rejects anything below the
# 26.1-era 0x560 layout. Patch only that immediate in the installed 26.0 or 26.0.1
# DSC; do not replace frameworks or normalize GPU metadata.
IOS_VERSION=$(/usr/bin/plutil -extract ProductVersion raw -o - "$MNT1/System/Library/CoreServices/SystemVersion.plist" 2>/dev/null || true)
if [[ "$IOS_VERSION" == 26.0* ]]; then
    echo "  [*] Patching 26.0/26.0.1 IOMobileFramebuffer SwapEnd payload size..."
    DSC_DIR="$MNT1/System/Cryptexes/OS/System/Library/Caches/com.apple.dyld"
    [[ -d "$DSC_DIR" ]] || die "dyld cache dir missing: $DSC_DIR"
    "$PYTHON3" "$SCRIPT_DIR/patchers/cfw.py" patch-iomfb-swapend "$DSC_DIR"
fi

# ═══════════ 2/7 PATCH SEPUTIL ════════════════════════════════
echo ""
echo "[2/7] Patching seputil..."

# Always patch from .bak (original unpatched binary)
if ! [[ -e "$MNT1/usr/libexec/seputil.bak" ]]; then
    echo "  Creating backup..."
    /bin/cp $MNT1/usr/libexec/seputil $MNT1/usr/libexec/seputil.bak
fi

cp "$MNT1/usr/libexec/seputil.bak" "$TEMP_DIR/seputil"
"$PYTHON3" "$SCRIPT_DIR/patchers/cfw.py" patch-seputil "$TEMP_DIR/seputil"
ldid_sign "$TEMP_DIR/seputil" "com.apple.seputil"
cp -R "$TEMP_DIR/seputil" "$MNT1/usr/libexec/seputil"
/bin/chmod 0755 $MNT1/usr/libexec/seputil

# Rename gigalocker (mv to same name is fine on re-run)
echo "  Renaming gigalocker..."
mount_vol s3 "$MNT3"
mv "$MNT3"/*.gl(N) "$MNT3/AA.gl" 2>/dev/null || true

echo "  [+] seputil patched"

# ═══════════ 3/7 INSTALL GPU DRIVER ══════════════════════════
echo ""
echo "[3/7] Installing AppleParavirtGPUMetalIOGPUFamily..."

cp -R "$INPUT_DIR/custom/AppleParavirtGPUMetalIOGPUFamily.tar" "$MNT1"
"$TAR" --preserve-permissions --no-overwrite-dir \
    -xf $MNT1/AppleParavirtGPUMetalIOGPUFamily.tar -C $MNT1

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
"$TAR" --preserve-permissions --no-overwrite-dir \
    -xf $MNT1/iosbinpack64.tar -C $MNT1
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
"$PYTHON3" "$SCRIPT_DIR/patchers/cfw.py" patch-launchd-cache-loader "$TEMP_DIR/launchd_cache_loader"
ldid_sign "$TEMP_DIR/launchd_cache_loader" "com.apple.launchd_cache_loader"
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
"$PYTHON3" "$SCRIPT_DIR/patchers/cfw.py" patch-mobileactivationd "$TEMP_DIR/mobileactivationd"
ldid_sign "$TEMP_DIR/mobileactivationd"
cp -R "$TEMP_DIR/mobileactivationd" "$MNT1/usr/libexec/mobileactivationd"
/bin/chmod 0755 $MNT1/usr/libexec/mobileactivationd

echo "  [+] mobileactivationd patched"

# ═══════════ 7/7 LAUNCHDAEMONS + LAUNCHD.PLIST ══════════════
echo ""
echo "[7/7] Installing LaunchDaemons..."

# Install vphoned (vsock HID injector daemon)
VPHONED_SRC="$SCRIPT_DIR/vphoned"
VPHONED_BIN="$VPHONED_SRC/vphoned"
VPHONED_SRCS=("$VPHONED_SRC"/*.m)
needs_vphoned_build=0
if [[ ! -f "$VPHONED_BIN" ]]; then
    needs_vphoned_build=1
else
    for src in "${VPHONED_SRCS[@]}"; do
        if [[ "$src" -nt "$VPHONED_BIN" ]]; then
            needs_vphoned_build=1
            break
        fi
    done
fi
if [[ "$needs_vphoned_build" == "1" ]]; then
    echo "  Building vphoned for arm64..."
    xcrun -sdk iphoneos clang -arch arm64 -Os -fobjc-arc \
        -I"$VPHONED_SRC" \
        -I"$VPHONED_SRC/vendor/libarchive" \
        -o "$VPHONED_BIN" "${VPHONED_SRCS[@]}" \
        -larchive \
        -lsqlite3 \
        -framework Foundation \
        -framework Security \
        -framework CoreServices
fi
cp "$VPHONED_BIN" "$TEMP_DIR/vphoned"
ldid \
    -S"$VPHONED_SRC/entitlements.plist" \
    -M "-K$VM_DIR/$CFW_INPUT/signcert.p12" \
    "$TEMP_DIR/vphoned"
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
        "$PYTHON3" "$SCRIPT_DIR/patchers/cfw.py" patch-dropbear-plist "$plist_src"
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
"$PYTHON3" "$SCRIPT_DIR/patchers/cfw.py" inject-daemons "$TEMP_DIR/launchd.plist" "$INPUT_DIR/jb/LaunchDaemons"
cp -R "$TEMP_DIR/launchd.plist" "$MNT1/System/Library/xpc/launchd.plist"
/bin/chmod 0644 $MNT1/System/Library/xpc/launchd.plist

echo "  [+] LaunchDaemons installed"

# ═══════════ CLEANUP ═════════════════════════════════════════
echo ""
echo "[*] Unmounting image volumes..."
/sbin/umount $MNT1 2>/dev/null || true
/sbin/umount $MNT3 2>/dev/null || true

# Keep .cfw_temp/Cryptex*.dmg cached (slow to re-create)
# Only remove temp binaries
echo "[*] Cleaning up temp binaries..."
rm -f "$TEMP_DIR/seputil" \
    "$TEMP_DIR/launchd_cache_loader" \
    "$TEMP_DIR/mobileactivationd" \
    "$TEMP_DIR/vphoned" \
    "$TEMP_DIR/launchd.plist"

echo ""
echo "[+] CFW installation complete!"
echo "    Boot to apply changes."
echo "    After boot, SSH will be available on port 22222 (password: alpine)"
