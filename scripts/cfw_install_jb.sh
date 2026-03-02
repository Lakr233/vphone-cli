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

SSH_PORT=2222
SSH_PASS="alpine"
SSH_USER="root"
SSH_HOST="localhost"
SSH_OPTS=(
    -o StrictHostKeyChecking=no
    -o UserKnownHostsFile=/dev/null
    -o PreferredAuthentications=password
    -o ConnectTimeout=30
    -q
)

# ── Helpers ─────────────────────────────────────────────────────
die() { echo "[-] $*" >&2; exit 1; }

_sshpass() {
    "sshpass" -p "$SSH_PASS" "$@"
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

remote_mount() {
    local dev="$1" mnt="$2" opts="${3:-rw}"
    ssh_cmd "/sbin/mount_apfs -o $opts $dev $mnt 2>/dev/null || true"
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

# ── Check JB prerequisites ────────────────────────────────────
command -v zstd >/dev/null 2>&1 || die "'zstd' not found (required for JB bootstrap phase)"

setup_cfw_jb_input
JB_INPUT_DIR="$VM_DIR/$CFW_JB_INPUT"
echo ""
echo "[+] JB input resources: $JB_INPUT_DIR"

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

# Inject launchdhook.dylib load command (idempotent — skips if already present)
if [[ -d "$JB_INPUT_DIR/basebin" ]]; then
    echo "  Injecting LC_LOAD_DYLIB for /cores/launchdhook.dylib..."
    python3 "$SCRIPT_DIR/patchers/cfw.py" inject-dylib "$TEMP_DIR/launchd" "/cores/launchdhook.dylib"
fi

python3 "$SCRIPT_DIR/patchers/cfw.py" patch-launchd-jetsam "$TEMP_DIR/launchd"
ldid_sign "$TEMP_DIR/launchd"
scp_to "$TEMP_DIR/launchd" "/mnt1/sbin/launchd"
ssh_cmd "/bin/chmod 0755 /mnt1/sbin/launchd"

echo "  [+] launchd patched"

# ═══════════ JB-2 INSTALL PROCURSUS BOOTSTRAP ══════════════════
echo ""
echo "[JB-2] Installing procursus bootstrap..."

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

ssh_cmd "/bin/mkdir -p /mnt5/$BOOT_HASH/jb-vphone"
ssh_cmd "/bin/chmod 0755 /mnt5/$BOOT_HASH/jb-vphone"
ssh_cmd "/usr/sbin/chown 0:0 /mnt5/$BOOT_HASH/jb-vphone"
ssh_cmd "/usr/bin/tar --preserve-permissions -xkf /mnt5/$BOOT_HASH/bootstrap-iphoneos-arm64.tar \
    -C /mnt5/$BOOT_HASH/jb-vphone/"
ssh_cmd "/bin/mv /mnt5/$BOOT_HASH/jb-vphone/var /mnt5/$BOOT_HASH/jb-vphone/procursus"
ssh_cmd "/bin/mkdir -p /mnt5/$BOOT_HASH/jb-vphone/procursus"
ssh_cmd "/bin/mv /mnt5/$BOOT_HASH/jb-vphone/procursus/jb/* /mnt5/$BOOT_HASH/jb-vphone/procursus 2>/dev/null || true"
ssh_cmd "/bin/rm -rf /mnt5/$BOOT_HASH/jb-vphone/procursus/jb"
ssh_cmd "/bin/rm -f /mnt5/$BOOT_HASH/bootstrap-iphoneos-arm64.tar"
rm -f "$BOOTSTRAP_TAR"

echo "  [+] procursus bootstrap installed"

# ═══════════ JB-3 DEPLOY BASEBIN HOOKS ═════════════════════════
BASEBIN_DIR="$JB_INPUT_DIR/basebin"
if [[ -d "$BASEBIN_DIR" ]]; then
    echo ""
    echo "[JB-3] Deploying BaseBin hooks to /cores/..."

    ssh_cmd "/bin/mkdir -p /mnt1/cores"
    ssh_cmd "/bin/chmod 0755 /mnt1/cores"

    for dylib in "$BASEBIN_DIR"/*.dylib; do
        [[ -f "$dylib" ]] || continue
        dylib_name="$(basename "$dylib")"
        echo "  Installing $dylib_name..."
        # Re-sign with our certificate before deploying
        ldid_sign "$dylib"
        scp_to "$dylib" "/mnt1/cores/$dylib_name"
        ssh_cmd "/bin/chmod 0755 /mnt1/cores/$dylib_name"
    done

    echo "  [+] BaseBin hooks deployed"
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
