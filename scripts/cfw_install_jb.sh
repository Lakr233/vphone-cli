#!/bin/zsh
# vphone-tier: dist
# Install the JB-specific system patches after the base CFW and vphoned.
# User package managers, bootstrap payloads, and first-boot installers are out
# of scope: the guest is left empty except for the required daemon.
set -euo pipefail

[[ -n "${_VPHONE_PATH:-}" ]] && export PATH="$_VPHONE_PATH"
SCRIPT_DIR="${0:a:h}"
VM_DIR="${1:-.}"
VM_DIR="$(cd "$VM_DIR" && pwd -P)"

VPHONE_CLI="${VPHONE_CLI_BIN:-}"
if [[ -z "$VPHONE_CLI" ]]; then
    for candidate in "${SCRIPT_DIR:h}/.build/release/vphone-cli" "${SCRIPT_DIR:h:h}/MacOS/vphone-cli"; do
        [[ -x "$candidate" ]] && { VPHONE_CLI="$candidate"; break }
    done
fi
[[ -x "$VPHONE_CLI" ]] || { echo "[-] vphone-cli is missing — run make build" >&2; exit 1; }

echo "[*] Installing JB CFW and vphoned..."
zsh "$SCRIPT_DIR/cfw_install.sh" "$VM_DIR"

: "${CFW_HOST_CONTAINER:?CFW_HOST_CONTAINER unset — run via cfw_install_host.sh}"
HOST_MNT="${CFW_HOST_MNT:-/private/tmp/cfwhost}"
MNT1="$HOST_MNT/mnt1"
TEMP_DIR="$VM_DIR/.cfw_temp"
/bin/mkdir -p "$MNT1" "$TEMP_DIR"
cleanup() {
    /sbin/umount "$MNT1" 2>/dev/null || true
    /bin/rm -rf "$TEMP_DIR"
}
trap cleanup EXIT

if ! /sbin/mount | /usr/bin/grep -q " on $MNT1 "; then
    /sbin/mount_apfs -o rw "/dev/${CFW_HOST_CONTAINER}s1" "$MNT1"
fi

echo "[*] Patching launchd jetsam guard..."
LAUNCHD="$MNT1/sbin/launchd"
[[ -f "$LAUNCHD.bak" ]] || /bin/cp "$LAUNCHD" "$LAUNCHD.bak"
/bin/cp "$LAUNCHD.bak" "$TEMP_DIR/launchd"
"$VPHONE_CLI" dump-entitlements "$TEMP_DIR/launchd" > "$TEMP_DIR/launchd.entitlements" 2>/dev/null || true
"$VPHONE_CLI" cfw patch-launchd-jetsam "$TEMP_DIR/launchd"
if [[ -s "$TEMP_DIR/launchd.entitlements" ]]; then
    "$VPHONE_CLI" sign --entitlements "$TEMP_DIR/launchd.entitlements" --merge "$TEMP_DIR/launchd"
else
    "$VPHONE_CLI" sign --merge "$TEMP_DIR/launchd"
fi
/bin/cp "$TEMP_DIR/launchd" "$LAUNCHD"
/bin/chmod 0755 "$LAUNCHD"

echo "[*] Patching debugserver entitlements..."
DEBUGSERVER="$MNT1/usr/libexec/debugserver"
if [[ -f "$DEBUGSERVER" ]]; then
    /bin/cp "$DEBUGSERVER" "$TEMP_DIR/debugserver"
    "$VPHONE_CLI" dump-entitlements "$TEMP_DIR/debugserver" > "$TEMP_DIR/debugserver.entitlements"
    /usr/bin/plutil -remove seatbelt-profiles "$TEMP_DIR/debugserver.entitlements" 2>/dev/null || true
    /usr/bin/plutil -insert task_for_pid-allow -bool YES "$TEMP_DIR/debugserver.entitlements"
    "$VPHONE_CLI" sign --entitlements "$TEMP_DIR/debugserver.entitlements" --merge "$TEMP_DIR/debugserver"
    /bin/cp "$TEMP_DIR/debugserver" "$DEBUGSERVER"
    /bin/chmod 0755 "$DEBUGSERVER"
else
    echo "[!] debugserver is absent; entitlement patch skipped" >&2
fi

IOS_VERSION=$(/usr/bin/plutil -extract ProductVersion raw -o - \
    "$MNT1/System/Library/CoreServices/SystemVersion.plist" 2>/dev/null || true)
if [[ "$IOS_VERSION" == 27.* ]]; then
    CAMPO="$MNT1/Applications/Campo.app/Campo"
    if [[ -f "$CAMPO" ]]; then
        echo "[*] Patching Campo entitlements for iOS $IOS_VERSION..."
        /bin/cp "$CAMPO" "$TEMP_DIR/Campo"
        "$VPHONE_CLI" dump-entitlements "$TEMP_DIR/Campo" > "$TEMP_DIR/Campo.entitlements" 2>/dev/null || true
        if [[ -s "$TEMP_DIR/Campo.entitlements" ]]; then
            "$VPHONE_CLI" cfw patch-campo-entitlements "$TEMP_DIR/Campo.entitlements"
            "$VPHONE_CLI" sign --entitlements "$TEMP_DIR/Campo.entitlements" "$TEMP_DIR/Campo"
            /bin/cp "$TEMP_DIR/Campo" "$CAMPO"
            /bin/chmod 0755 "$CAMPO"
        else
            echo "[!] Campo has no readable entitlements; patch skipped" >&2
        fi
    fi
fi

echo "[+] JB system patches installed; no bootstrap payload staged."
