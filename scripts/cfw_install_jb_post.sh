#!/bin/zsh
# cfw_install_jb_post.sh — Finalize JB bootstrap on a normally-booted vphone.
#
# Runs after `cfw_install_jb` + first normal boot. Connects to the live device
# via SSH and sets up procursus symlinks, markers, Sileo, and apt packages.
#
# Every step is idempotent — safe to re-run at any point.
# All binary paths are discovered dynamically (no hardcoded /bin, /sbin, etc.).
#
# Usage: make cfw_install_jb_finalize [SSH_PORT=22222] [SSH_PASS=alpine]
set -euo pipefail

SCRIPT_DIR="${0:a:h}"

# ── Configuration ───────────────────────────────────────────────
SSH_PORT="${SSH_PORT:-22222}"
SSH_PASS="${SSH_PASS:-alpine}"
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

_sshpass() {
    "$SSHPASS_BIN" -p "$SSH_PASS" "$@"
}

_ssh_retry() {
    local attempt rc label
    label=${2:-cmd}
    for ((attempt = 1; attempt <= SSH_RETRY; attempt++)); do
        "$@" && return 0
        rc=$?
        [[ $rc -ne 255 ]] && return $rc
        echo "  [${label}] connection lost (attempt $attempt/$SSH_RETRY), retrying in 3s..." >&2
        sleep 3
    done
    return 255
}

# Raw ssh — no PATH prefix
ssh_raw() {
    _ssh_retry _sshpass ssh "${SSH_OPTS[@]}" -p "$SSH_PORT" "$SSH_USER@$SSH_HOST" "$@"
}

# ssh with discovered PATH prepended
ssh_cmd() {
    ssh_raw "$RENV $*"
}

# ── Prerequisites ──────────────────────────────────────────────
command -v sshpass &>/dev/null || die "Missing sshpass. Run: make setup_tools"
SSHPASS_BIN="$(command -v sshpass)"

echo "[*] cfw_install_jb_post.sh — Finalizing JB bootstrap..."
echo "    Target: ${SSH_USER}@${SSH_HOST}:${SSH_PORT}"
echo ""

# ── Verify SSH connectivity ────────────────────────────────────
echo "[*] Checking SSH connectivity..."
ssh_raw "echo ready" >/dev/null 2>&1 || die "Cannot reach device on ${SSH_HOST}:${SSH_PORT}. Is the VM booted normally?"
echo "[+] Device reachable"

# ── Discover remote PATH ──────────────────────────────────────
# Uses only shell builtins (test -d, echo) — works with empty PATH.
echo "[*] Discovering remote binary directories..."
DISCOVERED_PATH=$(ssh_raw 'P=""; \
    for d in \
        /var/jb/usr/bin /var/jb/bin /var/jb/sbin /var/jb/usr/sbin \
        /iosbinpack64/bin /iosbinpack64/usr/bin /iosbinpack64/sbin /iosbinpack64/usr/sbin \
        /usr/bin /usr/sbin /bin /sbin; do \
        [ -d "$d" ] && P="$P:$d"; \
    done; \
    echo "${P#:}"')

[[ -n "$DISCOVERED_PATH" ]] || die "Could not discover any binary directories on device"
echo "  PATH=$DISCOVERED_PATH"

# This gets prepended to every ssh_cmd call
RENV="export PATH='$DISCOVERED_PATH' TERM='xterm-256color';"

# Quick sanity: verify we can run ls now
ssh_cmd "ls / >/dev/null" || die "PATH discovery succeeded but 'ls' still not found"
echo "[+] Remote environment ready"

# ═══════════ 1/6 SYMLINK /var/jb ══════════════════════════════
echo ""
echo "[1/6] Creating /private/var/jb symlink..."

# Find 96-char boot manifest hash — use shell glob (no ls dependency)
BOOT_HASH=$(ssh_cmd 'for d in /private/preboot/*/; do \
    b="${d%/}"; b="${b##*/}"; \
    [ "${#b}" = 96 ] && echo "$b" && break; \
done')
[[ -n "$BOOT_HASH" ]] || die "Could not find 96-char boot manifest hash in /private/preboot"
echo "  Boot manifest hash: $BOOT_HASH"

JB_TARGET="/private/preboot/$BOOT_HASH/jb-vphone/procursus"
ssh_cmd "test -d '$JB_TARGET'" || die "Procursus directory not found at $JB_TARGET. Run cfw_install_jb first."

CURRENT_LINK=$(ssh_cmd "readlink /private/var/jb 2>/dev/null || true")
if [[ "$CURRENT_LINK" == "$JB_TARGET" ]]; then
    echo "  [*] Symlink already correct, skipping"
else
    ssh_cmd "ln -sf '$JB_TARGET' /private/var/jb"
    echo "  [+] /private/var/jb -> $JB_TARGET"
fi

# ═══════════ 2/6 FIX OWNERSHIP / PERMISSIONS ═════════════════
echo ""
echo "[2/6] Fixing mobile Library ownership..."

ssh_cmd "mkdir -p /var/jb/var/mobile/Library/Preferences"
ssh_cmd "chown -R 501:501 /var/jb/var/mobile/Library"
ssh_cmd "chmod 0755 /var/jb/var/mobile/Library"
ssh_cmd "chown -R 501:501 /var/jb/var/mobile/Library/Preferences"
ssh_cmd "chmod 0755 /var/jb/var/mobile/Library/Preferences"

echo "  [+] Ownership set"

# ═══════════ 3/6 RUN prep_bootstrap.sh ════════════════════════
echo ""
echo "[3/6] Running prep_bootstrap.sh..."

if ssh_cmd "test -f /var/jb/prep_bootstrap.sh"; then
    # Skip interactive password prompt (uses uialert GUI — not usable over SSH)
    ssh_cmd "NO_PASSWORD_PROMPT=1 /var/jb/prep_bootstrap.sh"
    echo "  [+] prep_bootstrap.sh completed"
    echo "  [!] Terminal password was NOT set (automated mode)."
    echo "      To set it manually: ssh in and run: passwd"
else
    echo "  [*] prep_bootstrap.sh already ran (deleted itself), skipping"
fi

# Re-discover PATH after prep_bootstrap.sh may have changed the login shell.
# The shell switch (chsh) can alter which profile scripts run on subsequent SSH
# sessions, so we must refresh RENV to ensure dpkg/apt/uicache are reachable.
echo "[*] Re-discovering remote PATH after bootstrap prep..."
DISCOVERED_PATH=$(ssh_raw 'P=""; \
    for d in \
        /var/jb/usr/bin /var/jb/bin /var/jb/sbin /var/jb/usr/sbin \
        /iosbinpack64/bin /iosbinpack64/usr/bin /iosbinpack64/sbin /iosbinpack64/usr/sbin \
        /usr/bin /usr/sbin /bin /sbin; do \
        [ -d "$d" ] && P="$P:$d"; \
    done; \
    echo "${P#:}"')
RENV="export PATH='$DISCOVERED_PATH' TERM='xterm-256color';"
echo "  PATH=$DISCOVERED_PATH"

# Fix interactive SSH environment.
# dropbear uses --shell /iosbinpack64/bin/bash and ignores /etc/passwd.
# /iosbinpack64/etc/profile spawns a non-login subshell that only reads ~/.bashrc.
# prep_bootstrap.sh's chsh has no effect because dropbear doesn't consult passwd.
# Create ~/.bashrc so the interactive subshell sources /var/jb/etc/profile (full PATH).
echo "[*] Setting up shell profile for interactive SSH..."
if ! ssh_cmd "test -f /var/root/.bashrc"; then
    ssh_cmd "printf '%s\n' '# Source JB environment' '[ -r /var/jb/etc/profile ] && . /var/jb/etc/profile' > /var/root/.bashrc"
    echo "  [+] /var/root/.bashrc created"
else
    echo "  [*] /var/root/.bashrc already exists, skipping"
fi

# ═══════════ 4/6 CREATE MARKER FILES ═════════════════════════
echo ""
echo "[4/6] Creating marker files..."

for marker in .procursus_strapped .installed_dopamine; do
    if ssh_cmd "test -f /var/jb/$marker"; then
        echo "  [*] $marker already exists, skipping"
    else
        ssh_cmd ": > /var/jb/$marker && chown 0:0 /var/jb/$marker && chmod 0644 /var/jb/$marker"
        echo "  [+] $marker created"
    fi
done

# ═══════════ 5/6 INSTALL SILEO ══════════════════════════════
echo ""
echo "[5/6] Installing Sileo..."

SILEO_DEB_PATH="/private/preboot/$BOOT_HASH/org.coolstar.sileo_2.5.1_iphoneos-arm64.deb"

if ssh_cmd "dpkg -s org.coolstar.sileo >/dev/null 2>&1"; then
    echo "  [*] Sileo already installed, skipping"
else
    ssh_cmd "test -f '$SILEO_DEB_PATH'" || die "Sileo deb not found at $SILEO_DEB_PATH. Was it uploaded by cfw_install_jb?"
    ssh_cmd "dpkg -i '$SILEO_DEB_PATH'"
    echo "  [+] Sileo installed"
fi

ssh_cmd "uicache -a 2>/dev/null || true"
echo "  [+] uicache refreshed"

# ═══════════ 6/7 APT SETUP ═════════════════════════════════
echo ""
echo "[6/7] Running apt setup..."

HAVOC_LIST="/var/jb/etc/apt/sources.list.d/havoc.list"
if ssh_cmd "test -d /etc/apt/sources.list.d && test ! -d /var/jb/etc/apt/sources.list.d"; then
    HAVOC_LIST="/etc/apt/sources.list.d/havoc.list"
fi

HAVOC_SOURCES="$(ssh_cmd "grep -RIl 'havoc.app' /etc/apt /var/jb/etc/apt 2>/dev/null || true")"
if [[ -n "$HAVOC_SOURCES" ]]; then
    echo "  [*] Havoc source already present:"
    echo "$HAVOC_SOURCES" | sed 's/^/      - /'

    OTHER_HAVOC_SOURCES="$(printf '%s\n' "$HAVOC_SOURCES" | grep -Fvx "$HAVOC_LIST" || true)"
    if [[ -n "$OTHER_HAVOC_SOURCES" ]] && ssh_cmd "test -f '$HAVOC_LIST' && grep -q 'https://havoc.app/' '$HAVOC_LIST'"; then
        ssh_cmd "rm -f '$HAVOC_LIST'"
        echo "  [+] Removed duplicate autogenerated Havoc source: $HAVOC_LIST"
    fi
else
    ssh_cmd "mkdir -p '${HAVOC_LIST:h}'"
    ssh_cmd "printf '%s\n' 'deb [trusted=yes] https://havoc.app/ ./' > '$HAVOC_LIST'"
    echo "  [+] Havoc source added: $HAVOC_LIST"
fi

echo "  [*] Allowing unsigned third-party repos during automated apt refresh"
ssh_cmd "DEBIAN_FRONTEND=noninteractive apt-get -o Acquire::AllowInsecureRepositories=true -o Acquire::AllowDowngradeToInsecureRepositories=true update -qq"
ssh_cmd "DEBIAN_FRONTEND=noninteractive apt-get -o APT::Get::AllowUnauthenticated=true install -y -qq libkrw0-tfp0 2>/dev/null || true"
echo "  [+] apt update + libkrw0-tfp0 done"

ssh_cmd "DEBIAN_FRONTEND=noninteractive apt-get -o APT::Get::AllowUnauthenticated=true upgrade -y -qq 2>/dev/null || true"
echo "  [+] apt upgrade done"

# ═══════════ 7/7 INSTALL TROLLSTORE LITE ═══════════════════
echo ""
echo "[7/7] Installing TrollStore Lite..."

if ssh_cmd "dpkg -s com.opa334.trollstorelite >/dev/null 2>&1"; then
    echo "  [*] TrollStore Lite already installed, skipping"
else
    ssh_cmd "DEBIAN_FRONTEND=noninteractive apt-get -o APT::Get::AllowUnauthenticated=true install -y -qq com.opa334.trollstorelite"
    echo "  [+] TrollStore Lite installed"
fi

ssh_cmd "uicache -a 2>/dev/null || true"
echo "  [+] uicache refreshed"

# ═══════════ DONE ═══════════════════════════════════════════
echo ""
echo "[+] JB finalization complete!"
echo "    TrollStore Lite is installed automatically during finalization."
echo "    Next: open Sileo on device, add source https://ellekit.space, install ElleKit"
echo "    Then reboot the device for full JB environment."
