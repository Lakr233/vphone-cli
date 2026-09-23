#!/bin/zsh
# vphone-tier: build   (see cfw-kit/run.sh)
# jb/install.sh — fully patched firmware, empty userland.
#
# The firmware layer is jailbroken all the way: run `make fw_patch_jb` first and
# all 127 JB boot-chain patches (iBoot / kernel / TXM / DSC) are already in the
# images this installs onto. This script then applies the FILESYSTEM-layer JB
# work that does not depend on which userland flavour you eventually pick.
#
# The userland is deliberately EMPTY. No BaseBin hooks, no procursus bootstrap,
# no Sileo, no TweakLoader, no first-boot setup. Two flavours are planned —
# rootless and roothide — and they disagree about where things live, so the kit
# ships the interface and neither implementation. See userland/README.md.
#
#   installed here                          left empty (slot)
#   ─────────────────────────────────       ──────────────────────────────
#   everything vanilla installs             BaseBin hooks -> /cores
#   launchd jetsam guard                    /b launchdhook alias + injection
#   debugserver entitlements                procursus bootstrap
#   Campo mach-lookup fix (iOS 27)          Sileo / apt / TrollStore
#   iOS-27 JB DSC + DDI patches             TweakLoader
#                                           first-boot setup daemon
#
# Usage: ../run.sh --variant jb [vm_dir]
#        JB_USERLAND=rootless|roothide|none   (default: none)
# Contract: root, VM off, CFW_HOST_CONTAINER set, $1 = VM dir.
set -euo pipefail

KIT_DIR="${0:a:h:h}"
source "$KIT_DIR/lib/common.sh"
source "$KIT_DIR/lib/base_stages.sh"

VM_DIR="$(cd "${1:-.}" && pwd)"
CFW_INPUT="cfw_input"
CFW_ARCHIVE="cfw_input.tar.zst"
TEMP_DIR="$VM_DIR/.cfw_temp"

JB_USERLAND="${JB_USERLAND:-none}"
FORCE_DSC_MAXSLIDE="${FORCE_DSC_MAXSLIDE:-0}"

REQUIRED_CFW_SUBCOMMANDS=(
    cryptex-paths
    patch-seputil
    patch-mobileactivationd
    patch-iomfb-swapend
    patch-iomfb-force-kern
    patch-dsc-maxslide
    patch-xpc-lwcr
    patch-lockdown-mode
    patch-lsd-embedded-reg
    patch-diskimagesiod
    patch-launchd-jetsam
    # J3's Campo fix. It was a standalone Python script outside the preflight's
    # reach; as a cfw verb it is checked with the rest.
    patch-campo-entitlements
)

REPO_DIR="$(resolve_repo)"
VPHONE_CLI="$(resolve_vphone_cli)"
init_paths

cleanup_on_exit() {
    safe_detach "$TEMP_DIR/mnt_sysos" 2>/dev/null || true
    safe_detach "$TEMP_DIR/mnt_appos" 2>/dev/null || true
}
trap cleanup_on_exit EXIT

echo "[*] custom-firmware-kit — variant: jb (all firmware patches, empty userland)"
echo "[+] repo: $REPO_DIR"
echo "[+] vm:   $VM_DIR"

# ── Userland slot ───────────────────────────────────────────────
# Loaded BEFORE anything is written so a flavour can register hooks and so a
# missing/broken slot fails before the volume is touched.
USERLAND_DIR=""
if [[ "$JB_USERLAND" != "none" ]]; then
    USERLAND_DIR="$KIT_DIR/jb/userland/$JB_USERLAND"
    [[ -d "$USERLAND_DIR" ]] || die "unknown JB_USERLAND '$JB_USERLAND' (expected a dir at $USERLAND_DIR)"
    if [[ -f "$USERLAND_DIR/install.sh" ]]; then
        echo "[+] userland flavour: $JB_USERLAND"
        source "$USERLAND_DIR/install.sh"
    else
        die "JB_USERLAND=$JB_USERLAND but $USERLAND_DIR/install.sh does not exist yet.
    The userland slots are intentionally empty in this kit — see jb/userland/README.md.
    Use JB_USERLAND=none to install the firmware layer only."
    fi
else
    echo "[+] userland flavour: none (slot left empty — firmware layer only)"
fi

# A flavour that rewrites launchd.plist needs the cache-validation NOP too;
# fold it into the preflight list so a missing subcommand is caught before any
# write rather than halfway through the install.
if [[ "${USERLAND_MODIFIES_LAUNCHD_PLIST:-0}" == "1" ]]; then
    echo "[+] slot declares it modifies launchd.plist — launchd_cache_loader patch enabled"
    REQUIRED_CFW_SUBCOMMANDS+=(patch-launchd-cache-loader)
fi

preflight
[[ "${KIT_CHECK_ONLY:-0}" == "1" ]] && { echo "[+] check-only: stopping before any write"; exit 0; }

RESTORE_DIR=$(find_restore_dir)
echo "[+] Restore directory: $RESTORE_DIR"

setup_cfw_input
INPUT_DIR="$VM_DIR/$CFW_INPUT"
echo "[+] Input resources: $INPUT_DIR"
require_signing_tools

mkdir -p "$TEMP_DIR"

echo ""
echo "[*] Parsing iPhone BuildManifest for Cryptex paths..."
CRYPTEX_PATHS=$(cfw_cli cryptex-paths "$RESTORE_DIR/iPhone-BuildManifest.plist")
CRYPTEX_SYSOS=$(echo "$CRYPTEX_PATHS" | head -1)
CRYPTEX_APPOS=$(echo "$CRYPTEX_PATHS" | tail -1)
echo "  SystemOS: $CRYPTEX_SYSOS"
echo "  AppOS:    $CRYPTEX_APPOS"

# ── Base (same code path as vanilla) ────────────────────────────
# The only difference from vanilla's base is the lsd embedded-registration
# gate, on here because a JB userland is what needs it.
stage_cryptex
detect_ios_version
stage_display_and_boot_fixes 1
stage_seputil
stage_gpu
stage_mobileactivationd

# Only needed if the userland slot rewrites launchd.plist. See the stage's
# comment in lib/base_stages.sh for why this is not unconditional.
if [[ "${USERLAND_MODIFIES_LAUNCHD_PLIST:-0}" == "1" ]]; then
    stage_launchd_cache_loader
else
    echo ""
    echo "[base] skip launchd_cache_loader (nothing modifies launchd.plist)"
fi

# ═══════════ J1 PATCH LAUNCHD (JETSAM GUARD) ══════════════════
# The jetsam guard patch is flavour-independent: without it pid 1 panics on
# boot under the JB kernel patches. The launchdhook dylib injection that
# upstream also does here belongs to BaseBin, so it is exposed as a hook the
# userland slot may implement instead of being done unconditionally.
echo ""
echo "[J1] Patching launchd (jetsam guard)..."

if ! [[ -e "$MNT1/sbin/launchd.bak" ]]; then
    echo "  Creating backup..."
    /bin/cp $MNT1/sbin/launchd $MNT1/sbin/launchd.bak
fi
cp "$MNT1/sbin/launchd.bak" "$TEMP_DIR/launchd"

# Original entitlements must survive the re-sign or spawn breaks.
echo "  Extracting original entitlements..."
ldid -e "$TEMP_DIR/launchd" > "$TEMP_DIR/launchd.entitlements" 2>/dev/null || true
if [[ -s "$TEMP_DIR/launchd.entitlements" ]]; then
    echo "  [+] Preserved launchd entitlements"
else
    warn "No entitlements found on original launchd"
fi

# ── slot hook: dylib injection into pid 1 ──
if typeset -f userland_launchd_hook >/dev/null; then
    echo "  Running userland launchd hook ($JB_USERLAND)..."
    userland_launchd_hook "$TEMP_DIR/launchd"
else
    echo "  [*] No userland launchd hook — pid 1 gets no injected dylib"
fi

cfw_cli patch-launchd-jetsam "$TEMP_DIR/launchd"

if [[ -s "$TEMP_DIR/launchd.entitlements" ]]; then
    ldid -S"$TEMP_DIR/launchd.entitlements" -M "-K$VM_DIR/$CFW_INPUT/signcert.p12" "$TEMP_DIR/launchd"
else
    ldid_sign "$TEMP_DIR/launchd"
fi
cp -R "$TEMP_DIR/launchd" "$MNT1/sbin/launchd"
/bin/chmod 0755 $MNT1/sbin/launchd

echo "  [+] launchd patched"

# ═══════════ J2 DEBUGSERVER ENTITLEMENTS ══════════════════════
echo ""
echo "[J2] Patching debugserver entitlements..."

if [[ -f "$MNT1/usr/libexec/debugserver" ]]; then
    cp "$MNT1/usr/libexec/debugserver" "$TEMP_DIR/debugserver"
    ldid -e "$TEMP_DIR/debugserver" > "$TEMP_DIR/debugserver-entitlements.plist"
    plutil -remove seatbelt-profiles "$TEMP_DIR/debugserver-entitlements.plist" || true
    plutil -insert task_for_pid-allow -bool YES "$TEMP_DIR/debugserver-entitlements.plist" || true
    ldid_sign_ent "$TEMP_DIR/debugserver" "$TEMP_DIR/debugserver-entitlements.plist"
    cp -R "$TEMP_DIR/debugserver" "$MNT1/usr/libexec/debugserver"
    /bin/chmod 0755 $MNT1/usr/libexec/debugserver
    echo "  [+] debugserver entitlements patched"
else
    warn "debugserver not present in this OS image; skipping"
fi

# ═══════════ J3 CAMPO SANDBOX FIX (iOS 27 only) ═══════════════
# Grants Campo the backboard/frontboard mach-lookups the 26.4 temporary sandbox
# denies. 27-gated on the mounted rootfs SystemVersion.plist.
CAMPO_BIN="$MNT1/Applications/Campo.app/Campo"
case "$IOS_VERSION" in
27.*)
    if [[ -f "$CAMPO_BIN" ]]; then
        echo ""
        echo "[J3] Granting Campo backboard/frontboard mach-lookup exceptions (iOS $IOS_VERSION)..."
        cp "$CAMPO_BIN" "$TEMP_DIR/Campo"
        ldid -e "$TEMP_DIR/Campo" > "$TEMP_DIR/Campo.entitlements" 2>/dev/null || true
        if [[ -s "$TEMP_DIR/Campo.entitlements" ]]; then
            cfw_cli patch-campo-entitlements "$TEMP_DIR/Campo.entitlements"
            ldid_sign_ent "$TEMP_DIR/Campo" "$TEMP_DIR/Campo.entitlements"
            cp -R "$TEMP_DIR/Campo" "$CAMPO_BIN"
            /bin/chmod 0755 "$CAMPO_BIN"
            echo "  [+] Campo re-signed"
        else
            warn "Could not read Campo entitlements; skipping Campo sandbox fix"
        fi
    else
        echo "[J3] Campo.app not present in this OS image; skipping"
    fi
    ;;
*)
    echo "[J3] skip Campo sandbox fix (base iOS ${IOS_VERSION:-unknown} — 27-only)"
    ;;
esac

# ═══════════ J4 USERLAND SLOT ═════════════════════════════════
echo ""
if typeset -f userland_install >/dev/null; then
    echo "[J4] Installing userland flavour: $JB_USERLAND..."
    userland_install
    echo "  [+] userland installed"
else
    echo "[J4] Userland slot is empty — nothing installed."
    echo "     No /cores hooks, no bootstrap, no package manager, no tweak loader."
    echo "     Fill jb/userland/{rootless,roothide}/install.sh to change that."
fi

stage_unmount

echo ""
echo "[+] jb CFW installation complete (firmware layer fully patched)."
if ! typeset -f userland_install >/dev/null; then
    echo "    Userland slot empty: the guest boots a jailbroken KERNEL with a"
    echo "    stock userland. That is expected for JB_USERLAND=none."
fi
