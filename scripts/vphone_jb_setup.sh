#!/bin/bash
# vphone_jb_setup.sh — First-boot JB finalization script.
#
# Deployed to /cores/ during cfw_install_jb.sh (ramdisk phase).
# Runs automatically via LaunchDaemon on first normal boot.
# Idempotent — safe to re-run on subsequent boots.
#
# Logs to /var/log/vphone_jb_setup.log for host-side monitoring
# via vphoned file browser.

set -uo pipefail

LOG="/var/log/vphone_jb_setup.log"
DONE_MARKER="/var/mobile/.vphone_jb_setup_done"

log() { echo "[$(date '+%H:%M:%S')] $*" | tee -a "$LOG"; }
die() { log "FATAL: $*"; exit 1; }

# Redirect all output to log
exec > >(tee -a "$LOG") 2>&1

log "=== vphone_jb_setup.sh starting ==="

# ── Check done marker ────────────────────────────────────────
if [ -f "$DONE_MARKER" ]; then
    log "Already completed (marker exists), exiting."
    exit 0
fi

# ── Environment ──────────────────────────────────────────────
export TERM=xterm-256color
export DEBIAN_FRONTEND=noninteractive

# Discover PATH dynamically
P=""
for d in \
    /var/jb/usr/bin /var/jb/bin /var/jb/sbin /var/jb/usr/sbin \
    /iosbinpack64/bin /iosbinpack64/usr/bin /iosbinpack64/sbin /iosbinpack64/usr/sbin \
    /usr/bin /usr/sbin /bin /sbin; do
    [ -d "$d" ] && P="$P:$d"
done
export PATH="${P#:}"
log "PATH=$PATH"

# ── Find boot manifest hash ─────────────────────────────────
BOOT_HASH=""
for d in /private/preboot/*/; do
    b="${d%/}"; b="${b##*/}"
    if [ "${#b}" = 96 ]; then
        BOOT_HASH="$b"
        break
    fi
done
[ -n "$BOOT_HASH" ] || die "Could not find 96-char boot manifest hash"
log "Boot hash: $BOOT_HASH"

JB_TARGET="/private/preboot/$BOOT_HASH/jb-vphone/procursus"
[ -d "$JB_TARGET" ] || die "Procursus not found at $JB_TARGET"

# ═══════════ 0/7 REPLACE LAUNCHCTL ═════════════════════════════
# Procursus launchctl crashes (missing _launch_active_user_switch symbol).
# iosbinpack64's launchctl talks to launchd fine and always exits 0,
# which is enough for dpkg postinst/prerm script compatibility.
log "[0/8] Linking iosbinpack64 launchctl into procursus..."
IOSBINPACK_LAUNCHCTL=""
for p in /iosbinpack64/bin/launchctl /iosbinpack64/usr/bin/launchctl; do
    [ -f "$p" ] && IOSBINPACK_LAUNCHCTL="$p" && break
done

if [ -n "$IOSBINPACK_LAUNCHCTL" ]; then
    if [ -f "$JB_TARGET/usr/bin/launchctl" ] && [ ! -L "$JB_TARGET/usr/bin/launchctl" ] && [ ! -f "$JB_TARGET/usr/bin/launchctl.procursus" ]; then
        mv "$JB_TARGET/usr/bin/launchctl" "$JB_TARGET/usr/bin/launchctl.procursus"
        log "  procursus original saved as launchctl.procursus"
    fi
    ln -sf "$IOSBINPACK_LAUNCHCTL" "$JB_TARGET/usr/bin/launchctl"
    mkdir -p "$JB_TARGET/bin"
    ln -sf "$IOSBINPACK_LAUNCHCTL" "$JB_TARGET/bin/launchctl"
    log "  linked usr/bin/launchctl + bin/launchctl -> $IOSBINPACK_LAUNCHCTL"
else
    log "  WARNING: iosbinpack64 launchctl not found"
fi

# ═══════════ 1/7 SYMLINK /var/jb ═════════════════════════════
log "[1/8] Creating /private/var/jb symlink..."
CURRENT_LINK=$(readlink /private/var/jb 2>/dev/null || true)
if [ "$CURRENT_LINK" = "$JB_TARGET" ]; then
    log "  Symlink already correct"
else
    ln -sf "$JB_TARGET" /private/var/jb
    log "  /var/jb -> $JB_TARGET"
fi

# ═══════════ 2/7 FIX OWNERSHIP / PERMISSIONS ═════════════════
log "[2/8] Fixing mobile Library ownership..."
mkdir -p /var/jb/var/mobile/Library/Preferences
chown -R 501:501 /var/jb/var/mobile/Library
chmod 0755 /var/jb/var/mobile/Library
chown -R 501:501 /var/jb/var/mobile/Library/Preferences
chmod 0755 /var/jb/var/mobile/Library/Preferences
log "  Ownership set"

# ═══════════ 3/7 RUN prep_bootstrap.sh ═══════════════════════
log "[3/8] Running prep_bootstrap.sh..."
if [ -f /var/jb/prep_bootstrap.sh ]; then
    NO_PASSWORD_PROMPT=1 /var/jb/prep_bootstrap.sh || log "  prep_bootstrap.sh exited with $?"
    log "  prep_bootstrap.sh completed"
else
    log "  prep_bootstrap.sh already ran (deleted itself), skipping"
fi

# Re-discover PATH after prep_bootstrap
P=""
for d in \
    /var/jb/usr/bin /var/jb/bin /var/jb/sbin /var/jb/usr/sbin \
    /iosbinpack64/bin /iosbinpack64/usr/bin /iosbinpack64/sbin /iosbinpack64/usr/sbin \
    /usr/bin /usr/sbin /bin /sbin; do
    [ -d "$d" ] && P="$P:$d"
done
export PATH="${P#:}"
log "  PATH=$PATH"

# ═══════════ 4/7 CREATE MARKER FILES ═════════════════════════
log "[4/8] Creating marker files..."
for marker in .procursus_strapped .installed_dopamine; do
    if [ -f "/var/jb/$marker" ]; then
        log "  $marker already exists"
    else
        : > "/var/jb/$marker"
        chown 0:0 "/var/jb/$marker"
        chmod 0644 "/var/jb/$marker"
        log "  $marker created"
    fi
done

# ═══════════ 5/7 INSTALL SILEO ═══════════════════════════════
log "[5/8] Installing Sileo..."
SILEO_DEB_PATH="/private/preboot/$BOOT_HASH/org.coolstar.sileo_2.5.1_iphoneos-arm64.deb"

if dpkg -s org.coolstar.sileo >/dev/null 2>&1; then
    log "  Sileo already installed"
else
    if [ -f "$SILEO_DEB_PATH" ]; then
        dpkg -i "$SILEO_DEB_PATH" || log "  dpkg -i sileo exited with $?"
        log "  Sileo installed"
    else
        log "  WARNING: Sileo deb not found at $SILEO_DEB_PATH"
    fi
fi

uicache -a 2>/dev/null || true
log "  uicache refreshed"

# ═══════════ 6/7 APT SETUP ══════════════════════════════════
log "[6/8] Running apt setup..."

# Determine apt sources directory
HAVOC_LIST="/var/jb/etc/apt/sources.list.d/havoc.list"
if [ -d /etc/apt/sources.list.d ] && [ ! -d /var/jb/etc/apt/sources.list.d ]; then
    HAVOC_LIST="/etc/apt/sources.list.d/havoc.list"
fi

if ! grep -rIl 'havoc.app' /etc/apt /var/jb/etc/apt 2>/dev/null | grep -q .; then
    mkdir -p "$(dirname "$HAVOC_LIST")"
    printf '%s\n' 'deb https://havoc.app/ ./' > "$HAVOC_LIST"
    log "  Havoc source added: $HAVOC_LIST"
else
    log "  Havoc source already present"
fi

apt-get -o Acquire::AllowInsecureRepositories=true \
    -o Acquire::AllowDowngradeToInsecureRepositories=true \
    update -qq 2>&1 || log "  apt update exited with $?"
log "  apt update done"

apt-get -o APT::Get::AllowUnauthenticated=true \
    install -y -qq libkrw0-tfp0 2>/dev/null || true
log "  libkrw0-tfp0 done"

apt-get -o APT::Get::AllowUnauthenticated=true \
    upgrade -y -qq 2>/dev/null || true
log "  apt upgrade done"

# ═══════════ 7/7 INSTALL TROLLSTORE LITE ═════════════════════
log "[7/8] Installing TrollStore Lite..."
if dpkg -s com.opa334.trollstorelite >/dev/null 2>&1; then
    log "  TrollStore Lite already installed"
else
    apt-get -o APT::Get::AllowUnauthenticated=true \
        install -y -qq com.opa334.trollstorelite 2>&1
    trollstore_rc=$?
    if [ "$trollstore_rc" -ne 0 ]; then
        die "TrollStore Lite apt install failed with exit code $trollstore_rc"
    fi
    if dpkg -s com.opa334.trollstorelite >/dev/null 2>&1; then
        log "  TrollStore Lite installed"
    else
        die "TrollStore Lite install completed without registering package"
    fi
fi

uicache -a 2>/dev/null || true
log "  uicache refreshed"

# ═══════════ 8/8 SHELL PROFILES FOR SSH ═══════════════════════
log "[8/8] Setting up shell profiles for SSH..."
# .bashrc  — non-login interactive shells (dropbear default)
# .bash_profile — login shells (some SSH configurations)
# Both source /var/jb/etc/profile to get the full JB PATH.
for profile in /var/root/.bashrc /var/root/.bash_profile; do
    if [ ! -f "$profile" ]; then
        printf '%s\n' '# Source JB environment' '[ -r /var/jb/etc/profile ] && . /var/jb/etc/profile' > "$profile"
        log "  $profile created"
    else
        log "  $profile already exists, skipping"
    fi
done

# ═══════════ DONE ════════════════════════════════════════════
: > "$DONE_MARKER"
log "=== vphone_jb_setup.sh complete ==="
