#!/bin/zsh
# cfw_install_jb.sh — Install base CFW + JB extensions on vphone.
#
# Runs the base CFW installer first (phases 1-7), then applies JB-specific
# modifications: launchd jetsam patch, dylib injection, procursus bootstrap,
# and BaseBin hook deployment. Files are placed directly on the VM's Disk.img
# volumes, which cfw_install_host.sh attaches and mounts on the host; VM off.
#
# Prerequisites (in addition to cfw_install.sh requirements):
#   - cfw_jb_input/ or resources/cfw_jb_input.tar.zst present
#   - zstd (for bootstrap decompression)
#
# Usage: make cfw_install_jb
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
# Step 1: Run base CFW install, then continue with JB phases
# ════════════════════════════════════════════════════════════════
echo "[*] cfw_install_jb.sh — Installing CFW + JB extensions..."
echo ""
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

get_boot_manifest_hash() {
    /bin/ls $MNT5 2>/dev/null | awk 'length($0)==96{print; exit}'
}

find_patched_txm_src() {
    local dir txm
    for dir in "$VM_DIR"/iPhone*_Restore; do
        txm="$dir/Firmware/txm.iphoneos.release.im4p"
        [[ -f "$txm" ]] && { echo "$txm"; return 0; }
    done
    return 1
}

install_patched_preboot_txm() {
    local txm_src
    txm_src="$(find_patched_txm_src)" || die "Missing patched release TXM (run make fw_patch_jb before cfw_install_jb)"

    local txm_dir="$MNT5/$BOOT_HASH/usr/standalone/firmware/FUD"
    local txm_dst="$txm_dir/Ap,TrustedExecutionMonitor.img4"
    local txm_backup="$txm_dst.pre-vphone"
    local txm_local="$TEMP_DIR/Ap,TrustedExecutionMonitor.img4"

    echo "  Installing patched TXM into Preboot..."
    /bin/mkdir -p "$txm_dir" "$TEMP_DIR"
    [[ -f "$txm_dst" ]] || die "Missing live Preboot TXM at $txm_dst"
    if [[ ! -f "$txm_backup" ]]; then
        /bin/cp "$txm_dst" "$txm_backup"
    fi
    /bin/cp "$txm_backup" "$txm_local"
    "$PYTHON3" "$SCRIPT_DIR/patchers/cfw_patch_preboot_txm.py" "$txm_local" "$txm_src"
    /bin/cp "$txm_local" "$txm_dst"
    /usr/sbin/chown 0:0 "$txm_dst"
    /bin/chmod 0644 "$txm_dst"
    echo "  [+] Preboot TXM patched"
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


# ═══════════ JB-4 INSTALL PROCURSUS BOOTSTRAP ══════════════════
echo ""
echo "[JB-4] Installing procursus bootstrap..."

mount_vol s5 "$MNT5"
BOOT_HASH="$(get_boot_manifest_hash)"
[[ -n "$BOOT_HASH" ]] || die "Could not find 96-char boot manifest hash in $MNT5"
echo "  Boot manifest hash: $BOOT_HASH"
install_patched_preboot_txm

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
echo "[+] CFW + JB installation complete!"
echo "    Boot to apply changes."
echo "    After boot, SSH will be available on port 22222 (password: alpine)"
