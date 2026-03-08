#!/bin/zsh
# cfw_install_jb.sh — Install base CFW + JB extensions on vphone via SSH ramdisk.
#
# Runs the base CFW installer first (phases 1-7), then applies JB-specific
# modifications: launchd jetsam patch, dylib injection, procursus bootstrap,
# and BaseBin hook deployment.
#
# Prerequisites (in addition to cfw_install.sh requirements):
#   - cfw_jb_input/ or resources/cfw_jb_input.tar.zst present
#   - zstd (for bootstrap decompression)
#
# Usage: make cfw_install_jb
set -euo pipefail

VM_DIR="${1:-.}"
SCRIPT_DIR="${0:a:h}"

# ════════════════════════════════════════════════════════════════
# Step 1: Run base CFW install (skip halt — we continue with JB phases)
# ════════════════════════════════════════════════════════════════
echo "[*] cfw_install_jb.sh — Installing CFW + JB extensions..."
echo ""
CFW_SKIP_HALT=1 zsh "$SCRIPT_DIR/cfw_install.sh" "$VM_DIR"

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

SSH_PORT="${SSH_PORT:-2222}"
SSH_PASS="alpine"
SSH_USER="root"
SSH_HOST="localhost"
SSH_RETRY="${SSH_RETRY:-3}"
SSHPASS_BIN=""
SSH_OPTS=(
    -o StrictHostKeyChecking=no
    -o UserKnownHostsFile=/dev/null
    -o PreferredAuthentications=password
    -o ConnectTimeout=30
    -q
)

# ── Helpers ─────────────────────────────────────────────────────
die() {
    echo "[-] $*" >&2
    exit 1
}

check_prerequisites() {
    local missing=()
    command -v sshpass &>/dev/null || missing+=("sshpass")
    command -v ldid &>/dev/null || missing+=("ldid (brew install ldid-procursus)")
    if ((${#missing[@]} > 0)); then
        die "Missing required tools: ${missing[*]}. Run: make setup_tools"
    fi
    SSHPASS_BIN="$(command -v sshpass)"
}

_sshpass() {
    "$SSHPASS_BIN" -p "$SSH_PASS" "$@"
}

_ssh_retry() {
    local attempt rc label
    label=${2:-cmd}
    for ((attempt = 1; attempt <= SSH_RETRY; attempt++)); do
        "$@" && return 0
        rc=$?
        [[ $rc -ne 255 ]] && return $rc # real command failure — don't retry
        echo "  [${label}] connection lost (attempt $attempt/$SSH_RETRY), retrying in 3s..." >&2
        sleep 3
    done
    return 255
}

ssh_cmd() {
    _ssh_retry _sshpass ssh "${SSH_OPTS[@]}" -p "$SSH_PORT" "$SSH_USER@$SSH_HOST" "$@"
}
scp_to() {
    _ssh_retry _sshpass scp -q "${SSH_OPTS[@]}" -P "$SSH_PORT" -r "$1" "$SSH_USER@$SSH_HOST:$2"
}
scp_from() {
    _ssh_retry _sshpass scp -q "${SSH_OPTS[@]}" -P "$SSH_PORT" "$SSH_USER@$SSH_HOST:$1" "$2"
}

remote_file_exists() {
    ssh_cmd "test -f '$1'" 2>/dev/null
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

remote_mount() {
    local dev="$1" mnt="$2" opts="${3:-rw}"
    ssh_cmd "/bin/mkdir -p $mnt"
    if ssh_cmd "/sbin/mount | /usr/bin/grep -q ' on $mnt '"; then
        return 0
    fi
    ssh_cmd "/sbin/mount_apfs -o $opts $dev $mnt 2>/dev/null || true"
    if ! ssh_cmd "/sbin/mount | /usr/bin/grep -q ' on $mnt '"; then
        die "Failed to mount $dev at $mnt (opts=$opts). Make sure the ramdisk was booted with the expected patched kernel."
    fi
}

get_boot_manifest_hash() {
    ssh_cmd "/bin/ls /mnt5 2>/dev/null" | awk 'length($0)==96{print; exit}'
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

# ── Check JB prerequisites ────────────────────────────────────
command -v zstd >/dev/null 2>&1 || die "'zstd' not found (required for JB bootstrap phase)"

setup_cfw_jb_input
JB_INPUT_DIR="$VM_DIR/$CFW_JB_INPUT"
echo ""
echo "[+] JB input resources: $JB_INPUT_DIR"
check_prerequisites

mkdir -p "$TEMP_DIR"

# Mount device rootfs (may already be mounted from base install)
remote_mount /dev/disk1s1 /mnt1

# ═══════════ JB-1 PATCH LAUNCHD (JETSAM + DYLIB INJECTION) ════
echo ""
echo "[JB-1] Patching launchd (jetsam guard + hook injection)..."

if ! remote_file_exists "/mnt1/sbin/launchd.bak"; then
    echo "  Creating backup..."
    ssh_cmd "/bin/cp /mnt1/sbin/launchd /mnt1/sbin/launchd.bak"
fi

scp_from "/mnt1/sbin/launchd.bak" "$TEMP_DIR/launchd"

# Extract original entitlements before patching (must preserve for spawn permissions)
echo "  Extracting original entitlements..."
ldid -e "$TEMP_DIR/launchd" > "$TEMP_DIR/launchd.entitlements" 2>/dev/null || true
if [[ -s "$TEMP_DIR/launchd.entitlements" ]]; then
    echo "  [+] Preserved launchd entitlements"
else
    echo "  [!] No entitlements found on original launchd"
fi

# Inject launchdhook via short root alias to avoid Mach-O header overflow.
# Keep the full /cores/launchdhook.dylib copy on disk for compatibility, but
# load /b from launchd because this launchd sample only has room for a short
# LC_LOAD_DYLIB command after stripping LC_CODE_SIGNATURE.
if [[ -d "$JB_INPUT_DIR/basebin" ]]; then
    echo "  Injecting LC_LOAD_DYLIB for /b (short launchdhook alias)..."
    python3 "$SCRIPT_DIR/patchers/cfw.py" inject-dylib "$TEMP_DIR/launchd" "/b"
fi

python3 "$SCRIPT_DIR/patchers/cfw.py" patch-launchd-jetsam "$TEMP_DIR/launchd"

# Re-sign with original entitlements to avoid "operation not permitted" on spawn
if [[ -s "$TEMP_DIR/launchd.entitlements" ]]; then
    ldid -S"$TEMP_DIR/launchd.entitlements" -M "-K$VM_DIR/$CFW_INPUT/signcert.p12" "$TEMP_DIR/launchd"
else
    ldid_sign "$TEMP_DIR/launchd"
fi
scp_to "$TEMP_DIR/launchd" "/mnt1/sbin/launchd"
ssh_cmd "/bin/chmod 0755 /mnt1/sbin/launchd"

echo "  [+] launchd patched"

# ═══════════ JB-2 INSTALL IOSBINPACK64 ════════════════════════
echo ""
echo "[JB-2] Installing iosbinpack64..."

scp_to "$VM_DIR/$CFW_INPUT/jb/iosbinpack64.tar" "/mnt1"
ssh_cmd "/usr/bin/tar --preserve-permissions --no-overwrite-dir \
    -xf /mnt1/iosbinpack64.tar -C /mnt1"
ssh_cmd "/bin/rm -f /mnt1/iosbinpack64.tar"
apply_dev_overlay

echo "  [+] iosbinpack64 installed"

# ═══════════ JB-3 PATCH debugserver entitlements ════
echo ""
echo "[JB-3] Patching debugserver entitlements..."

scp_from "/mnt1/usr/libexec/debugserver" "$TEMP_DIR/debugserver"
ldid -e "$TEMP_DIR/debugserver" > "$TEMP_DIR/debugserver-entitlements.plist"
plutil -remove seatbelt-profiles "$TEMP_DIR/debugserver-entitlements.plist" || true
plutil -insert task_for_pid-allow -bool YES "$TEMP_DIR/debugserver-entitlements.plist" || true
ldid_sign_ent "$TEMP_DIR/debugserver" "$TEMP_DIR/debugserver-entitlements.plist"
scp_to "$TEMP_DIR/debugserver" "/mnt1/usr/libexec/debugserver"
ssh_cmd "/bin/chmod 0755 /mnt1/usr/libexec/debugserver"

echo "  [+] debugserver entitlements patched"


# ═══════════ JB-4 INSTALL PROCURSUS BOOTSTRAP ══════════════════
echo ""
echo "[JB-4] Installing procursus bootstrap..."

remote_mount /dev/disk1s5 /mnt5
BOOT_HASH="$(get_boot_manifest_hash)"
[[ -n "$BOOT_HASH" ]] || die "Could not find 96-char boot manifest hash in /mnt5"
echo "  Boot manifest hash: $BOOT_HASH"

BOOTSTRAP_ZST="$JB_INPUT_DIR/jb/bootstrap-iphoneos-arm64.tar.zst"
SILEO_DEB="$JB_INPUT_DIR/jb/org.coolstar.sileo_2.5.1_iphoneos-arm64.deb"
[[ -f "$BOOTSTRAP_ZST" ]] || die "Missing $BOOTSTRAP_ZST"

BOOTSTRAP_TAR="$TEMP_DIR/bootstrap-iphoneos-arm64.tar"
zstd -d -f "$BOOTSTRAP_ZST" -o "$BOOTSTRAP_TAR"

scp_to "$BOOTSTRAP_TAR" "/mnt5/$BOOT_HASH/bootstrap-iphoneos-arm64.tar"
if [[ -f "$SILEO_DEB" ]]; then
    scp_to "$SILEO_DEB" "/mnt5/$BOOT_HASH/org.coolstar.sileo_2.5.1_iphoneos-arm64.deb"
fi

JB_DIR_NAME="jb-vphone"
ssh_cmd "/bin/rm -rf /mnt5/$BOOT_HASH/jb"
ssh_cmd "/bin/rm -rf /mnt5/$BOOT_HASH/$JB_DIR_NAME"
ssh_cmd "/bin/mkdir -p /mnt5/$BOOT_HASH/$JB_DIR_NAME"
ssh_cmd "/bin/chmod 0755 /mnt5/$BOOT_HASH/$JB_DIR_NAME"
ssh_cmd "/usr/sbin/chown 0:0 /mnt5/$BOOT_HASH/$JB_DIR_NAME"
ssh_cmd "/usr/bin/tar --preserve-permissions -xf /mnt5/$BOOT_HASH/bootstrap-iphoneos-arm64.tar \
    -C /mnt5/$BOOT_HASH/$JB_DIR_NAME/"
ssh_cmd "/bin/mv /mnt5/$BOOT_HASH/$JB_DIR_NAME/var /mnt5/$BOOT_HASH/$JB_DIR_NAME/procursus"
ssh_cmd "/bin/mv /mnt5/$BOOT_HASH/$JB_DIR_NAME/procursus/jb/* /mnt5/$BOOT_HASH/$JB_DIR_NAME/procursus 2>/dev/null || true"
ssh_cmd "/bin/rm -rf /mnt5/$BOOT_HASH/$JB_DIR_NAME/procursus/jb"
ssh_cmd "/bin/rm -f /mnt5/$BOOT_HASH/bootstrap-iphoneos-arm64.tar"
rm -f "$BOOTSTRAP_TAR"

# NOTE: /var/jb symlink is created at runtime by launchdhook.dylib
# (Data volume is encrypted and not mountable from ramdisk).

echo "  [+] procursus bootstrap installed"

# ═══════════ JB-4 DEPLOY BASEBIN HOOKS ═════════════════════════
BASEBIN_DIR="$JB_INPUT_DIR/basebin"

if [[ -d "$BASEBIN_DIR" ]]; then
    echo ""
    echo "[JB-4] Deploying BaseBin hooks to /cores/..."

    # Clean previous dylibs before re-uploading
    echo "  Cleaning old /cores/ dylibs..."
    ssh_cmd "/bin/rm -rf /mnt1/cores"
    ssh_cmd "/bin/mkdir -p /mnt1/cores"
    ssh_cmd "/bin/chmod 0755 /mnt1/cores"

    # Install all pre-built dylibs from basebin payload
    for dylib in "$BASEBIN_DIR"/*.dylib; do
        [[ -f "$dylib" ]] || continue
        dylib_name="$(basename "$dylib")"
        echo "  Installing $dylib_name..."
        ldid_sign "$dylib"
        scp_to "$dylib" "/mnt1/cores/$dylib_name"
        ssh_cmd "/bin/chmod 0755 /mnt1/cores/$dylib_name"
    done

    # Short alias for launchdhook (header space is tight)
    if [[ -f "$BASEBIN_DIR/launchdhook.dylib" ]]; then
        echo "  Installing short launchdhook alias at /b..."
        cp "$BASEBIN_DIR/launchdhook.dylib" "$TEMP_DIR/b"
        ldid_sign "$TEMP_DIR/b"
        ssh_cmd "/bin/rm -f /mnt1/b"
        scp_to "$TEMP_DIR/b" "/mnt1/b"
        ssh_cmd "/bin/chmod 0755 /mnt1/b"
    fi

    echo "  [+] BaseBin hooks deployed"
fi

# ═══════════ JB-5 DEPLOY FIRST-BOOT SETUP ══════════════════════
echo ""
echo "[JB-5] Deploying first-boot setup..."

# Deploy first-boot JB setup script + LaunchDaemon
SETUP_SCRIPT="$SCRIPT_DIR/vphone_jb_setup.sh"
SETUP_PLIST="$SCRIPT_DIR/vphone_jb_setup.plist"
if [[ -f "$SETUP_SCRIPT" ]]; then
    scp_to "$SETUP_SCRIPT" "/mnt1/cores/vphone_jb_setup.sh"
    ssh_cmd "/bin/chmod 0755 /mnt1/cores/vphone_jb_setup.sh"
    echo "  [+] vphone_jb_setup.sh -> /cores/"
fi
if [[ -f "$SETUP_PLIST" ]]; then
    scp_to "$SETUP_PLIST" "/mnt1/System/Library/LaunchDaemons/com.vphone.jb-setup.plist"
    ssh_cmd "/bin/chmod 0644 /mnt1/System/Library/LaunchDaemons/com.vphone.jb-setup.plist"

    # Inject into launchd.plist so launchd starts it at boot
    echo "  Injecting com.vphone.jb-setup into launchd.plist..."
    scp_from "/mnt1/System/Library/xpc/launchd.plist" "$TEMP_DIR/launchd.plist"
    python3 -c "
import plistlib, sys
with open(sys.argv[1], 'rb') as f:
    target = plistlib.load(f)
with open(sys.argv[2], 'rb') as f:
    daemon = plistlib.load(f)
target.setdefault('LaunchDaemons', {})['/System/Library/LaunchDaemons/com.vphone.jb-setup.plist'] = daemon
with open(sys.argv[1], 'wb') as f:
    plistlib.dump(target, f, sort_keys=False)
" "$TEMP_DIR/launchd.plist" "$SETUP_PLIST"
    scp_to "$TEMP_DIR/launchd.plist" "/mnt1/System/Library/xpc/launchd.plist"
    ssh_cmd "/bin/chmod 0644 /mnt1/System/Library/xpc/launchd.plist"
    echo "  [+] com.vphone.jb-setup.plist injected into launchd.plist"
fi

# ═══════════ CLEANUP ═════════════════════════════════════════
echo ""
echo "[*] Unmounting device filesystems..."
ssh_cmd "/sbin/umount /mnt1 2>/dev/null || true"
ssh_cmd "/sbin/umount /mnt3 2>/dev/null || true"
ssh_cmd "/sbin/umount /mnt5 2>/dev/null || true"

echo "[*] Cleaning up temp binaries..."
rm -f "$TEMP_DIR/launchd" \
    "$TEMP_DIR/bootstrap-iphoneos-arm64.tar"

echo ""
echo "[+] CFW + JB installation complete!"
echo "    Reboot the device for changes to take effect."
echo "    After boot, SSH will be available on port 22222 (password: alpine)"

ssh_cmd "/sbin/halt" || true
