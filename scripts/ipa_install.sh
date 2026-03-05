#!/bin/zsh
# ipa_install.sh — Install an IPA onto a running vphone JB VM via SSH.
#
# Flow:
#  1) Unpack IPA on host
#  2) Remove old signatures + re-sign Mach-O files with ldid
#  3) Copy app bundle into a new app container on device
#  4) Run uicache for icon registration
#
# Usage:
#   zsh scripts/ipa_install.sh --vm-dir /path/to/vm --ipa /abs/path/app.ipa
# Optional:
#   --bundle-id com.example.newid
#   --ssh-host 127.0.0.1 --ssh-port 22222 --ssh-user root --ssh-pass alpine

set -euo pipefail

SCRIPT_DIR="${0:a:h}"

VM_DIR=""
IPA_PATH=""
BUNDLE_ID_OVERRIDE=""
SSH_HOST="${SSH_HOST:-127.0.0.1}"
SSH_PORT="${SSH_PORT:-22222}"
SSH_USER="${SSH_USER:-root}"
SSH_PASS="${SSH_PASS:-alpine}"
TMP_ROOT="${IPA_TMPDIR:-}"
UICACHE_BIN="/iosbinpack64/usr/bin/uicache"
SKIP_MOBILEINSTALL="${SKIP_MOBILEINSTALL:-0}"

die() {
  echo "[-] $*" >&2
  exit 1
}

usage() {
  cat <<'EOF'
Usage:
  zsh scripts/ipa_install.sh --vm-dir /path/to/vm --ipa /abs/path/app.ipa [options]

Options:
  --bundle-id ID       Override CFBundleIdentifier
  --ssh-host HOST      SSH host (default: 127.0.0.1)
  --ssh-port PORT      SSH port (default: 22222)
  --ssh-user USER      SSH user (default: root)
  --ssh-pass PASS      SSH password (default: alpine)
  --tmp-dir DIR        Host temp work directory (default: <vm-dir>/.ipa_tmp)
  --skip-mobileinstall Skip repack + ideviceinstaller stage (direct rootless install)
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --vm-dir) VM_DIR="$2"; shift 2 ;;
    --ipa) IPA_PATH="$2"; shift 2 ;;
    --bundle-id) BUNDLE_ID_OVERRIDE="$2"; shift 2 ;;
    --ssh-host) SSH_HOST="$2"; shift 2 ;;
    --ssh-port) SSH_PORT="$2"; shift 2 ;;
    --ssh-user) SSH_USER="$2"; shift 2 ;;
    --ssh-pass) SSH_PASS="$2"; shift 2 ;;
    --tmp-dir) TMP_ROOT="$2"; shift 2 ;;
    --skip-mobileinstall) SKIP_MOBILEINSTALL=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "Unknown argument: $1" ;;
  esac
done

[[ -n "$VM_DIR" ]] || die "--vm-dir is required"
[[ -n "$IPA_PATH" ]] || die "--ipa is required"
[[ -f "$IPA_PATH" ]] || die "IPA not found: $IPA_PATH"
[[ "$SKIP_MOBILEINSTALL" =~ ^[01]$ ]] || SKIP_MOBILEINSTALL=0

VM_DIR="$(cd "$VM_DIR" && pwd)"
SIGNCERT="$VM_DIR/cfw_input/signcert.p12"
if [[ -z "$TMP_ROOT" ]]; then
  TMP_ROOT="$VM_DIR/.ipa_tmp"
fi
mkdir -p "$TMP_ROOT"

for tool in unzip zip ldid sshpass ssh uuidgen file find sed awk tar; do
  command -v "$tool" >/dev/null 2>&1 || die "Missing tool: $tool"
done
[[ -x "/usr/libexec/PlistBuddy" ]] || die "Missing /usr/libexec/PlistBuddy"
IDEVICEINSTALLER_BIN="$(command -v ideviceinstaller || true)"

SSH_OPTS=(
  -o StrictHostKeyChecking=no
  -o UserKnownHostsFile=/dev/null
  -o PreferredAuthentications=password
  -o ConnectTimeout=20
  -o LogLevel=ERROR
)

ssh_cmd() {
  sshpass -p "$SSH_PASS" ssh "${SSH_OPTS[@]}" -p "$SSH_PORT" "$SSH_USER@$SSH_HOST" "$@"
}

activate_rootless_prefix() {
  local jb_prefix ts
  local mkdir_bin cp_bin mv_bin ln_bin
  mkdir_bin="/iosbinpack64/bin/mkdir"
  cp_bin="/iosbinpack64/bin/cp"
  mv_bin="/iosbinpack64/bin/mv"
  ln_bin="/iosbinpack64/bin/ln"

  if ssh_cmd "test -x /var/jb/usr/bin/mkdir"; then
    mkdir_bin="/var/jb/usr/bin/mkdir"
    cp_bin="/var/jb/usr/bin/cp"
    mv_bin="/var/jb/usr/bin/mv"
    ln_bin="/var/jb/usr/bin/ln"
  fi

  jb_prefix="$(ssh_cmd 'for d in /private/preboot/*/jb-vphone/procursus; do [ -d "$d" ] && { echo "$d"; break; }; done' 2>/dev/null || true)"
  [[ -n "$jb_prefix" ]] || return 0

  ssh_cmd "$mkdir_bin -p '$jb_prefix/Applications'"
  if ssh_cmd "test -d /var/jb/Applications"; then
    ssh_cmd "$cp_bin -R /var/jb/Applications/. '$jb_prefix/Applications/' 2>/dev/null || true"
  fi

  if ssh_cmd "test -d /var/jb && [ ! -L /var/jb ]"; then
    ts="$(date +%s)"
    ssh_cmd "$mv_bin /var/jb /var/jb._backup.$ts"
  fi
  ssh_cmd "$ln_bin -sfn '$jb_prefix' /var/jb"

  if ssh_cmd "test -x /var/jb/usr/bin/uicache"; then
    UICACHE_BIN="/var/jb/usr/bin/uicache"
  fi
}

copy_dir_to_remote() {
  local src_dir="$1"
  local remote_dir="$2"
  local src_parent src_name remote_tar remote_mkdir
  src_parent="$(dirname "$src_dir")"
  src_name="$(basename "$src_dir")"
  remote_tar="/iosbinpack64/usr/bin/tar"
  remote_mkdir="/iosbinpack64/bin/mkdir"
  if ssh_cmd "test -x /var/jb/usr/bin/tar"; then
    remote_tar="/var/jb/usr/bin/tar"
  fi
  if ssh_cmd "test -x /var/jb/usr/bin/mkdir"; then
    remote_mkdir="/var/jb/usr/bin/mkdir"
  fi
  COPYFILE_DISABLE=1 COPY_EXTENDED_ATTRIBUTES_DISABLE=1 tar --disable-copyfile --no-xattrs -C "$src_parent" -cf - "$src_name" \
    | sshpass -p "$SSH_PASS" ssh "${SSH_OPTS[@]}" -p "$SSH_PORT" "$SSH_USER@$SSH_HOST" \
      "$remote_mkdir -p '$remote_dir' && $remote_tar -xf - -C '$remote_dir'"
}

sign_macho() {
  local bin="$1"
  local ent="$2"
  if [[ -f "$SIGNCERT" ]]; then
    if [[ -s "$ent" ]]; then
      ldid -S"$ent" -M "-K$SIGNCERT" "$bin"
    else
      ldid -S -M "-K$SIGNCERT" "$bin"
    fi
  else
    if [[ -s "$ent" ]]; then
      ldid -S"$ent" "$bin"
    else
      ldid -S "$bin"
    fi
  fi
}

echo "[*] IPA install starting ..."
echo "  VM_DIR : $VM_DIR"
echo "  IPA    : $IPA_PATH"
if [[ "$SKIP_MOBILEINSTALL" -eq 1 ]]; then
  echo "  Stage6 : ideviceinstaller skipped (forced)"
fi
if [[ -f "$SIGNCERT" ]]; then
  echo "  Sign   : $SIGNCERT"
else
  echo "  Sign   : ad-hoc (no signcert found at $SIGNCERT)"
fi

TMP_DIR="$(mktemp -d "$TMP_ROOT/vphone-ipa.XXXXXX")"
cleanup() {
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

echo ""
echo "[1] Unpacking IPA..."
unzip -q "$IPA_PATH" -d "$TMP_DIR/unpack"

APP_CANDIDATES=("$TMP_DIR"/unpack/Payload/*.app(N))
(( ${#APP_CANDIDATES[@]} > 0 )) || die "No .app found in Payload/"
APP_DIR="$APP_CANDIDATES[1]"
APP_NAME="$(basename "$APP_DIR")"
INFO_PLIST="$APP_DIR/Info.plist"
[[ -f "$INFO_PLIST" ]] || die "Missing Info.plist: $INFO_PLIST"

ORIG_BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$INFO_PLIST" 2>/dev/null || true)"
APP_EXEC="$(
  /usr/libexec/PlistBuddy -c 'Print CFBundleExecutable' "$INFO_PLIST" 2>/dev/null || true
)"
MAIN_BIN="$APP_DIR/$APP_EXEC"

if [[ -n "$BUNDLE_ID_OVERRIDE" ]]; then
  /usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $BUNDLE_ID_OVERRIDE" "$INFO_PLIST" \
    || /usr/libexec/PlistBuddy -c "Add :CFBundleIdentifier string $BUNDLE_ID_OVERRIDE" "$INFO_PLIST"
  echo "  Bundle ID override: $ORIG_BUNDLE_ID -> $BUNDLE_ID_OVERRIDE"
fi

echo ""
echo "[2] Cleaning old signatures..."
find "$APP_DIR" -type d -name "_CodeSignature" -prune -exec rm -rf {} + || true
find "$APP_DIR" -type f -name "embedded.mobileprovision" -delete || true

echo ""
echo "[3] Re-signing Mach-O files..."
typeset -a MACHO_FILES
while IFS= read -r -d '' f; do
  if file -b "$f" | grep -q "Mach-O"; then
    MACHO_FILES+=("$f")
  fi
done < <(find "$APP_DIR" -type f -print0)

(( ${#MACHO_FILES[@]} > 0 )) || die "No Mach-O files found in app bundle"

echo "  Found ${#MACHO_FILES[@]} Mach-O files"
for bin in "${MACHO_FILES[@]}"; do
  [[ -f "$bin" ]] || continue
  [[ "$bin" == "$MAIN_BIN" ]] && continue
  ent="$TMP_DIR/ent.$(basename "$bin").plist"
  rm -f "$ent"
  ldid -e "$bin" > "$ent" 2>/dev/null || true
  sign_macho "$bin" "$ent"
done

if [[ -n "$APP_EXEC" && -f "$MAIN_BIN" ]]; then
  ent="$TMP_DIR/ent.main.plist"
  rm -f "$ent"
  ldid -e "$MAIN_BIN" > "$ent" 2>/dev/null || true
  sign_macho "$MAIN_BIN" "$ent"
else
  echo "  [!] Main executable not found via CFBundleExecutable, continuing."
fi

echo ""
echo "[4] Checking SSH connectivity..."
ssh_cmd "echo VM_SSH_OK" >/dev/null || die "SSH connection failed ($SSH_HOST:$SSH_PORT)"
activate_rootless_prefix

REPACKED_IPA="$TMP_DIR/repacked_signed.ipa"
if [[ "$SKIP_MOBILEINSTALL" -eq 0 ]]; then
  # Repacking needs extra free space (roughly >= 2x IPA size).
  IPA_BYTES="$(stat -f%z "$IPA_PATH" 2>/dev/null || echo 0)"
  FREE_BYTES="$(df -Pk "$TMP_ROOT" | awk 'NR==2{print $4 * 1024}')"
  if [[ "$IPA_BYTES" -gt 0 && "$FREE_BYTES" -gt 0 && "$FREE_BYTES" -lt $((IPA_BYTES * 2)) ]]; then
    echo ""
    echo "[5] Low host free space; skipping repack + ideviceinstaller."
    echo "    free=${FREE_BYTES}B, ipa=${IPA_BYTES}B"
    SKIP_MOBILEINSTALL=1
  fi
fi

if [[ "$SKIP_MOBILEINSTALL" -eq 0 ]]; then
  echo ""
  echo "[5] Repacking signed IPA..."
  if ! (
    cd "$TMP_DIR/unpack"
    COPYFILE_DISABLE=1 COPY_EXTENDED_ATTRIBUTES_DISABLE=1 zip -qry "$REPACKED_IPA" Payload
  ); then
    echo "  [!] Repack failed; continuing with rootless install path."
    SKIP_MOBILEINSTALL=1
  fi
fi

if [[ "$SKIP_MOBILEINSTALL" -eq 0 && -n "$IDEVICEINSTALLER_BIN" ]]; then
  echo ""
  echo "[6] Trying MobileInstallation via ideviceinstaller..."
  if "$IDEVICEINSTALLER_BIN" install "$REPACKED_IPA"; then
    NEW_BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$INFO_PLIST" 2>/dev/null || true)"
    echo ""
    echo "[+] Done"
    echo "  Install mode        : mobileinstallation"
    echo "  Bundle identifier  : ${NEW_BUNDLE_ID:-unknown}"
    echo "  App name           : $APP_NAME"
    exit 0
  else
    echo "  [!] ideviceinstaller install failed; falling back to rootless copy path."
  fi
else
  echo ""
  if [[ "$SKIP_MOBILEINSTALL" -eq 1 ]]; then
    echo "[6] MobileInstallation stage skipped; using rootless copy path."
  else
    echo "[6] ideviceinstaller not found; using rootless copy path."
  fi
fi

REMOTE_UUID="$(uuidgen | tr '[:lower:]' '[:upper:]')"
REMOTE_BASE="/private/var/containers/Bundle/Application/$REMOTE_UUID"
REMOTE_APP_PATH="$REMOTE_BASE/$APP_NAME"
INSTALL_MODE="container"
REMOTE_MKDIR_BIN="/iosbinpack64/bin/mkdir"
REMOTE_CHMOD_BIN="/iosbinpack64/bin/chmod"
REMOTE_CHOWN_BIN=""

if ssh_cmd "test -x /var/jb/usr/bin/mkdir"; then
  REMOTE_MKDIR_BIN="/var/jb/usr/bin/mkdir"
fi
if ssh_cmd "test -x /var/jb/usr/bin/chmod"; then
  REMOTE_CHMOD_BIN="/var/jb/usr/bin/chmod"
fi
if ssh_cmd "test -x /var/jb/usr/bin/chown"; then
  REMOTE_CHOWN_BIN="/var/jb/usr/bin/chown"
elif ssh_cmd "test -x /usr/sbin/chown"; then
  REMOTE_CHOWN_BIN="/usr/sbin/chown"
fi

echo ""
echo "[7] Uploading app to VM..."
if ! ssh_cmd "$REMOTE_MKDIR_BIN -p '$REMOTE_BASE'"; then
  echo "  [!] Container path is not writable, falling back to /var/jb/Applications"
  INSTALL_MODE="rootless"
  REMOTE_BASE="/var/jb/Applications"
  REMOTE_APP_PATH="$REMOTE_BASE/$APP_NAME"
  ssh_cmd "$REMOTE_MKDIR_BIN -p '$REMOTE_BASE'"
fi
copy_dir_to_remote "$APP_DIR" "$REMOTE_BASE"

if [[ "$INSTALL_MODE" == "container" ]]; then
  # Match container ownership conventions where possible.
  if [[ -n "$REMOTE_CHOWN_BIN" ]]; then
    ssh_cmd "$REMOTE_CHOWN_BIN -R _installd:_installd '$REMOTE_BASE' 2>/dev/null || true"
  fi
  ssh_cmd "$REMOTE_CHMOD_BIN -R 0755 '$REMOTE_BASE' 2>/dev/null || true"
else
  if [[ -n "$REMOTE_CHOWN_BIN" ]]; then
    ssh_cmd "$REMOTE_CHOWN_BIN -R root:wheel '$REMOTE_APP_PATH' 2>/dev/null || true"
  fi
  ssh_cmd "$REMOTE_CHMOD_BIN -R 0755 '$REMOTE_APP_PATH' 2>/dev/null || true"
fi

echo ""
echo "[8] Refreshing icon cache..."
ssh_cmd "$UICACHE_BIN -p '$REMOTE_APP_PATH' || $UICACHE_BIN -a"

NEW_BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$INFO_PLIST" 2>/dev/null || true)"

echo ""
echo "[+] Done"
echo "  Install mode        : $INSTALL_MODE"
echo "  Installed app path : $REMOTE_APP_PATH"
echo "  Bundle identifier  : ${NEW_BUNDLE_ID:-unknown}"
echo "  App name           : $APP_NAME"
