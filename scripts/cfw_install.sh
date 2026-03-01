#!/bin/zsh
# cfw_install.sh — Install base CFW modifications on vphone via SSH ramdisk.
#
# Installs Cryptexes, patches system binaries, installs jailbreak tools
# and configures LaunchDaemons for persistent SSH/VNC access.
#
# Safe to run multiple times — always patches from original .bak files,
# keeps decrypted Cryptex DMGs cached, handles already-mounted filesystems.
#
# Prerequisites:
#   - Device booted into SSH ramdisk (make ramdisk_send)
#   - `ipsw` tool installed (brew install blacktop/tap/ipsw)
#   - `aea` tool available (macOS 12+)
#   - Python: make setup_venv && source .venv/bin/activate
#   - cfw_input/ or resources/cfw_input.tar.zst present
#
# Usage: make cfw_install
set -euo pipefail

VM_DIR="${1:-.}"
SCRIPT_DIR="${0:a:h}"
CFW_SKIP_HALT="${CFW_SKIP_HALT:-0}"

# Resolve absolute paths
VM_DIR="$(cd "$VM_DIR" && pwd)"

# ── Configuration ───────────────────────────────────────────────
CFW_INPUT="cfw_input"
CFW_ARCHIVE="cfw_input.tar.zst"
TEMP_DIR="$VM_DIR/.cfw_temp"

SSH_PORT=2222
SSH_PASS="alpine"
SSH_USER="root"
SSH_HOST="localhost"
SSHPASS_BIN=""
SSH_OPTS=(
    -o StrictHostKeyChecking=no
    -o UserKnownHostsFile=/dev/null
    -o PreferredAuthentications=password
    -o ConnectTimeout=30
    -q
)

# ── Helpers ─────────────────────────────────────────────────────
die() { echo "[-] $*" >&2; exit 1; }

is_exec_compatible() {
    local bin="$1"
    local host_arch file_out archs

    [[ -x "$bin" ]] || return 1
    host_arch="$(uname -m)"
    file_out="$(file "$bin" 2>/dev/null || true)"

    # Non Mach-O executables (scripts/wrappers) are accepted.
    if [[ "$file_out" != *"Mach-O"* ]]; then
        return 0
    fi

    if command -v lipo >/dev/null 2>&1; then
        archs="$(lipo -archs "$bin" 2>/dev/null || true)"
        [[ -n "$archs" && " $archs " == *" $host_arch "* ]] && return 0
        return 1
    fi

    [[ "$file_out" == *"$host_arch"* || "$file_out" == *"universal"* ]]
}

resolve_sshpass() {
    local bundled="$VM_DIR/$CFW_INPUT/tools/sshpass"
    local host_sshpass
    host_sshpass="$(command -v sshpass 2>/dev/null || true)"

    if is_exec_compatible "$bundled"; then
        SSHPASS_BIN="$bundled"
        echo "[+] Using bundled sshpass: $SSHPASS_BIN"
        return
    fi

    if [[ -x "$bundled" ]]; then
        echo "[!] Bundled sshpass is not compatible with host arch ($(uname -m)): $bundled"
    fi

    if [[ -n "$host_sshpass" ]] && is_exec_compatible "$host_sshpass"; then
        SSHPASS_BIN="$host_sshpass"
        echo "[+] Using host sshpass: $SSHPASS_BIN"
        return
    fi

    [[ -n "$host_sshpass" ]] && \
        echo "[!] Host sshpass is present but incompatible with host arch: $host_sshpass"
    die "No compatible sshpass found. Install one with: brew install hudochenkov/sshpass/sshpass"
}

_sshpass() {
    "$SSHPASS_BIN" -p "$SSH_PASS" "$@"
}

ssh_cmd() {
    _sshpass ssh "${SSH_OPTS[@]}" -p "$SSH_PORT" "$SSH_USER@$SSH_HOST" "$@"
}

scp_to() {
    _sshpass scp -q "${SSH_OPTS[@]}" -P "$SSH_PORT" -r "$1" "$SSH_USER@$SSH_HOST:$2"
}

scp_from() {
    _sshpass scp -q "${SSH_OPTS[@]}" -P "$SSH_PORT" "$SSH_USER@$SSH_HOST:$1" "$2"
}

remote_file_exists() {
    ssh_cmd "test -f '$1'" 2>/dev/null
}

ldid_sign() {
    local file="$1" bundle_id="${2:-}"
    local args=(-S -M "-K$VM_DIR/$CFW_INPUT/signcert.p12")
    [[ -n "$bundle_id" ]] && args+=("-I$bundle_id")
    "$VM_DIR/$CFW_INPUT/tools/ldid_macosx_arm64" "${args[@]}" "$file"
}

# Detach a DMG mountpoint if currently mounted, ignore errors
safe_detach() {
    local mnt="$1"
    if mount | grep -q "$mnt"; then
        sudo hdiutil detach -force "$mnt" 2>/dev/null || true
    fi
}

# Mount device filesystem, tolerate already-mounted
remote_mount() {
    local dev="$1" mnt="$2" opts="${3:-rw}"
    ssh_cmd "/sbin/mount_apfs -o $opts $dev $mnt 2>/dev/null || true"
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
    command -v ipsw  >/dev/null 2>&1 || die "'ipsw' not found. Install: brew install blacktop/tap/ipsw"
    command -v aea   >/dev/null 2>&1 || die "'aea' not found (requires macOS 12+)"
    command -v python3 >/dev/null 2>&1 || die "python3 not found"
    python3 -c "import capstone, keystone" 2>/dev/null \
        || die "Missing Python deps. Install: pip install capstone keystone-engine"
}

# ── Cleanup trap (unmount DMGs on error) ───────────────────────
cleanup_on_exit() {
    safe_detach "$TEMP_DIR/mnt_sysos"
    safe_detach "$TEMP_DIR/mnt_appos"
}
trap cleanup_on_exit EXIT

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
resolve_sshpass

mkdir -p "$TEMP_DIR"

# ── Parse Cryptex paths from BuildManifest ─────────────────────
echo ""
echo "[*] Parsing iPhone BuildManifest for Cryptex paths..."
CRYPTEX_PATHS=$(python3 "$SCRIPT_DIR/patchers/cfw.py" cryptex-paths "$RESTORE_DIR/BuildManifest-iPhone.plist")
CRYPTEX_SYSOS=$(echo "$CRYPTEX_PATHS" | head -1)
CRYPTEX_APPOS=$(echo "$CRYPTEX_PATHS" | tail -1)
echo "  SystemOS: $CRYPTEX_SYSOS"
echo "  AppOS:    $CRYPTEX_APPOS"

# ═══════════ 1/7 INSTALL CRYPTEX ══════════════════════════════
echo ""
echo "[1/7] Installing Cryptex (SystemOS + AppOS)..."

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

echo "  Mounting SystemOS..."
sudo hdiutil attach -mountpoint "$MNT_SYSOS" "$SYSOS_DMG" -owners off
echo "  Mounting AppOS..."
sudo hdiutil attach -mountpoint "$MNT_APPOS" "$APPOS_DMG" -owners off

# Mount device rootfs (tolerate already-mounted)
echo "  Mounting device rootfs rw..."
remote_mount /dev/disk1s1 /mnt1

# Rename APFS update snapshot to orig-fs (idempotent)
echo "  Checking APFS snapshots..."
SNAP_LIST=$(ssh_cmd "snaputil -l /mnt1 2>/dev/null" || true)
if echo "$SNAP_LIST" | grep -q "^orig-fs$"; then
    echo "  Snapshot 'orig-fs' already exists, skipping rename"
else
    UPDATE_SNAP=$(echo "$SNAP_LIST" | grep "^com\.apple\.os\.update-" | head -1)
    if [[ -n "$UPDATE_SNAP" ]]; then
        echo "  Renaming snapshot: $UPDATE_SNAP -> orig-fs"
        ssh_cmd "snaputil -n '$UPDATE_SNAP' orig-fs /mnt1"
        # Verify rename succeeded
        if ! ssh_cmd "snaputil -l /mnt1 2>/dev/null" | grep -q "^orig-fs$"; then
            die "Failed to rename snapshot to orig-fs"
        fi
        echo "  Snapshot renamed, remounting..."
        ssh_cmd "/sbin/umount /mnt1"
        remote_mount /dev/disk1s1 /mnt1
        echo "  [+] Snapshot renamed to orig-fs"
    else
        echo "  No com.apple.os.update- snapshot found, skipping"
    fi
fi

ssh_cmd "/bin/rm -rf /mnt1/System/Cryptexes/App /mnt1/System/Cryptexes/OS"
ssh_cmd "/bin/mkdir -p /mnt1/System/Cryptexes/App /mnt1/System/Cryptexes/OS"
ssh_cmd "/bin/chmod 0755 /mnt1/System/Cryptexes/App /mnt1/System/Cryptexes/OS"

# Copy Cryptex files to device
echo "  Copying Cryptexes to device (this takes ~3 minutes)..."
scp_to "$MNT_SYSOS/." "/mnt1/System/Cryptexes/OS"
scp_to "$MNT_APPOS/." "/mnt1/System/Cryptexes/App"

# Create dyld symlinks (ln -sf is idempotent)
echo "  Creating dyld symlinks..."
ssh_cmd "/bin/ln -sf ../../../System/Cryptexes/OS/System/Library/Caches/com.apple.dyld \
    /mnt1/System/Library/Caches/com.apple.dyld"
ssh_cmd "/bin/ln -sf ../../../../System/Cryptexes/OS/System/DriverKit/System/Library/dyld \
    /mnt1/System/DriverKit/System/Library/dyld"

# Unmount Cryptex DMGs
echo "  Unmounting Cryptex DMGs..."
safe_detach "$MNT_SYSOS"
safe_detach "$MNT_APPOS"

echo "  [+] Cryptex installed"

# ═══════════ 2/7 PATCH SEPUTIL ════════════════════════════════
echo ""
echo "[2/7] Patching seputil..."

# Always patch from .bak (original unpatched binary)
if ! remote_file_exists "/mnt1/usr/libexec/seputil.bak"; then
    echo "  Creating backup..."
    ssh_cmd "/bin/cp /mnt1/usr/libexec/seputil /mnt1/usr/libexec/seputil.bak"
fi

scp_from "/mnt1/usr/libexec/seputil.bak" "$TEMP_DIR/seputil"
python3 "$SCRIPT_DIR/patchers/cfw.py" patch-seputil "$TEMP_DIR/seputil"
ldid_sign "$TEMP_DIR/seputil" "com.apple.seputil"
scp_to "$TEMP_DIR/seputil" "/mnt1/usr/libexec/seputil"
ssh_cmd "/bin/chmod 0755 /mnt1/usr/libexec/seputil"

# Rename gigalocker (mv to same name is fine on re-run)
echo "  Renaming gigalocker..."
remote_mount /dev/disk1s3 /mnt3
ssh_cmd '/bin/mv /mnt3/*.gl /mnt3/AA.gl 2>/dev/null || true'

echo "  [+] seputil patched"

# ═══════════ 3/7 INSTALL GPU DRIVER ══════════════════════════
echo ""
echo "[3/7] Installing AppleParavirtGPUMetalIOGPUFamily..."

scp_to "$INPUT_DIR/custom/AppleParavirtGPUMetalIOGPUFamily.tar" "/mnt1"
ssh_cmd "/usr/bin/tar --preserve-permissions --no-overwrite-dir \
    -xf /mnt1/AppleParavirtGPUMetalIOGPUFamily.tar -C /mnt1"

BUNDLE="/mnt1/System/Library/Extensions/AppleParavirtGPUMetalIOGPUFamily.bundle"
# Clean macOS resource fork files (._* files from tar xattrs)
ssh_cmd "find $BUNDLE -name '._*' -delete 2>/dev/null || true"
ssh_cmd "/usr/sbin/chown -R 0:0 $BUNDLE"
ssh_cmd "/bin/chmod 0755 $BUNDLE"
ssh_cmd "/bin/chmod 0755 $BUNDLE/libAppleParavirtCompilerPluginIOGPUFamily.dylib"
ssh_cmd "/bin/chmod 0755 $BUNDLE/AppleParavirtGPUMetalIOGPUFamily"
ssh_cmd "/bin/chmod 0755 $BUNDLE/_CodeSignature"
ssh_cmd "/bin/chmod 0644 $BUNDLE/_CodeSignature/CodeResources"
ssh_cmd "/bin/chmod 0644 $BUNDLE/Info.plist"
ssh_cmd "/bin/rm -f /mnt1/AppleParavirtGPUMetalIOGPUFamily.tar"

echo "  [+] GPU driver installed"

# ═══════════ 4/7 INSTALL IOSBINPACK64 ════════════════════════
echo ""
echo "[4/7] Installing iosbinpack64..."

scp_to "$INPUT_DIR/jb/iosbinpack64.tar" "/mnt1"
ssh_cmd "/usr/bin/tar --preserve-permissions --no-overwrite-dir \
    -xf /mnt1/iosbinpack64.tar -C /mnt1"
ssh_cmd "/bin/rm -f /mnt1/iosbinpack64.tar"

echo "  [+] iosbinpack64 installed"

# ═══════════ 5/7 PATCH LAUNCHD_CACHE_LOADER ══════════════════
echo ""
echo "[5/7] Patching launchd_cache_loader..."

# Always patch from .bak (original unpatched binary)
if ! remote_file_exists "/mnt1/usr/libexec/launchd_cache_loader.bak"; then
    echo "  Creating backup..."
    ssh_cmd "/bin/cp /mnt1/usr/libexec/launchd_cache_loader /mnt1/usr/libexec/launchd_cache_loader.bak"
fi

scp_from "/mnt1/usr/libexec/launchd_cache_loader.bak" "$TEMP_DIR/launchd_cache_loader"
python3 "$SCRIPT_DIR/patchers/cfw.py" patch-launchd-cache-loader "$TEMP_DIR/launchd_cache_loader"
ldid_sign "$TEMP_DIR/launchd_cache_loader" "com.apple.launchd_cache_loader"
scp_to "$TEMP_DIR/launchd_cache_loader" "/mnt1/usr/libexec/launchd_cache_loader"
ssh_cmd "/bin/chmod 0755 /mnt1/usr/libexec/launchd_cache_loader"

echo "  [+] launchd_cache_loader patched"

# ═══════════ 6/7 PATCH MOBILEACTIVATIOND ═════════════════════
echo ""
echo "[6/7] Patching mobileactivationd..."

# Always patch from .bak (original unpatched binary)
if ! remote_file_exists "/mnt1/usr/libexec/mobileactivationd.bak"; then
    echo "  Creating backup..."
    ssh_cmd "/bin/cp /mnt1/usr/libexec/mobileactivationd /mnt1/usr/libexec/mobileactivationd.bak"
fi

scp_from "/mnt1/usr/libexec/mobileactivationd.bak" "$TEMP_DIR/mobileactivationd"
python3 "$SCRIPT_DIR/patchers/cfw.py" patch-mobileactivationd "$TEMP_DIR/mobileactivationd"
ldid_sign "$TEMP_DIR/mobileactivationd"
scp_to "$TEMP_DIR/mobileactivationd" "/mnt1/usr/libexec/mobileactivationd"
ssh_cmd "/bin/chmod 0755 /mnt1/usr/libexec/mobileactivationd"

echo "  [+] mobileactivationd patched"

# ═══════════ 7/7 LAUNCHDAEMONS + LAUNCHD.PLIST ══════════════
echo ""
echo "[7/7] Installing LaunchDaemons..."

# Send daemon plists (overwrite on re-run)
for plist in bash.plist dropbear.plist trollvnc.plist; do
    scp_to "$INPUT_DIR/jb/LaunchDaemons/$plist" "/mnt1/System/Library/LaunchDaemons/"
    ssh_cmd "/bin/chmod 0644 /mnt1/System/Library/LaunchDaemons/$plist"
done

# Always patch launchd.plist from .bak (original)
echo "  Patching launchd.plist..."
if ! remote_file_exists "/mnt1/System/Library/xpc/launchd.plist.bak"; then
    echo "  Creating backup..."
    ssh_cmd "/bin/cp /mnt1/System/Library/xpc/launchd.plist /mnt1/System/Library/xpc/launchd.plist.bak"
fi

scp_from "/mnt1/System/Library/xpc/launchd.plist.bak" "$TEMP_DIR/launchd.plist"
python3 "$SCRIPT_DIR/patchers/cfw.py" inject-daemons "$TEMP_DIR/launchd.plist" "$INPUT_DIR/jb/LaunchDaemons"
scp_to "$TEMP_DIR/launchd.plist" "/mnt1/System/Library/xpc/launchd.plist"
ssh_cmd "/bin/chmod 0644 /mnt1/System/Library/xpc/launchd.plist"

echo "  [+] LaunchDaemons installed"

# ═══════════ CLEANUP ═════════════════════════════════════════
echo ""
echo "[*] Unmounting device filesystems..."
ssh_cmd "/sbin/umount /mnt1 2>/dev/null || true"
ssh_cmd "/sbin/umount /mnt3 2>/dev/null || true"

# Keep .cfw_temp/Cryptex*.dmg cached (slow to re-create)
# Only remove temp binaries
echo "[*] Cleaning up temp binaries..."
rm -f "$TEMP_DIR/seputil" \
      "$TEMP_DIR/launchd_cache_loader" \
      "$TEMP_DIR/mobileactivationd" \
      "$TEMP_DIR/launchd.plist"

echo ""
echo "[+] CFW installation complete!"
echo "    Reboot the device for changes to take effect."
echo "    After boot, SSH will be available on port 22222 (password: alpine)"

if [[ "$CFW_SKIP_HALT" == "1" ]]; then
    echo "[*] CFW_SKIP_HALT=1, skipping halt."
else
    ssh_cmd "/sbin/halt" || true
fi
