#!/bin/zsh
# Build the separate CMIO Camera Installer app and its nested System Extension.
# The installer is deliberately separate from the VM host, because the VM
# host's Virtualization entitlement boundary must not be coupled to the normal
# System Extension provisioning boundary.
set -euo pipefail

SCRIPT_DIR="${0:A:h}"
PROJECT_ROOT="${SCRIPT_DIR:h}"
cd "$PROJECT_ROOT"

INSTALLER_APP="${CAMERA_INSTALLER_BUNDLE:-.build/vphone-cli-camera-installer.app}"
APP_BUNDLE_ID="${APP_BUNDLE_ID:-com.vphone.cli}"
EXT_ID="${CAMERA_BUNDLE_ID:-${APP_BUNDLE_ID}.camera}"
INSTALLER_ID="${CAMERA_INSTALLER_BUNDLE_ID:-${APP_BUNDLE_ID}.camera-installer}"
EXT_DIR="$INSTALLER_APP/Contents/Library/SystemExtensions/${EXT_ID}.systemextension"
EXT_BIN=".build/release/vphone-camera-extension"
INSTALLER_BIN=".build/release/vphone-camera-installer"
IDENTITY="${CODESIGN_IDENTITY:--}"
EXTENSION_ENTITLEMENTS="${EXTENSION_ENTITLEMENTS:-sources/vphone-camera-extension.entitlements}"
INSTALLER_ENTITLEMENTS="${CAMERA_INSTALLER_ENTITLEMENTS:-sources/vphone-camera-installer.entitlements}"
EXTENSION_PROFILE="${EXTENSION_PROVISIONING_PROFILE:-}"
INSTALLER_PROFILE="${CAMERA_INSTALLER_PROVISIONING_PROFILE:-}"
TEAM_IDENTIFIER="${TEAM_IDENTIFIER:-}"
CAMERA_APP_GROUP="${CAMERA_APP_GROUP:-}"

if [[ -z "$TEAM_IDENTIFIER" && -n "$EXTENSION_PROFILE" ]]; then
  PROFILE_PLIST="$(mktemp -t vphone-camera-profile).plist"
  trap 'rm -f "$PROFILE_PLIST"' EXIT
  security cms -D -i "$EXTENSION_PROFILE" -o "$PROFILE_PLIST" >/dev/null
  TEAM_IDENTIFIER="$(/usr/libexec/PlistBuddy -c \
    'Print :Entitlements:com.apple.developer.team-identifier' "$PROFILE_PLIST" 2>/dev/null || true)"
fi
[[ -n "$TEAM_IDENTIFIER" ]] \
  || { echo "Error: cannot determine Team ID for CMIO Mach service name" >&2; exit 1; }
if [[ -z "$CAMERA_APP_GROUP" && -n "$EXTENSION_PROFILE" ]]; then
  # Prefer the first group explicitly granted by the downloaded profile. This
  # keeps portal naming (including TeamIdentifierPrefix-qualified macOS groups)
  # out of the source and avoids silently signing with a different identifier.
  CAMERA_APP_GROUP="$(/usr/libexec/PlistBuddy -c \
    'Print :Entitlements:com.apple.security.application-groups:0' "$PROFILE_PLIST" \
    2>/dev/null || true)"
fi
if [[ -z "$CAMERA_APP_GROUP" ]]; then
  # Fallback is useful for producing a diagnostic build; activation will still
  # fail closed below until the profile grants this exact group.
  CAMERA_APP_GROUP="${TEAM_IDENTIFIER}.com.vp.vphone"
fi
CMIO_MACH_SERVICE_NAME="${CAMERA_APP_GROUP}.${EXT_ID##*.}"

GENERATED_EXTENSION_ENTITLEMENTS=".build/vphone-camera-extension.entitlements.generated.plist"
cp -f "$EXTENSION_ENTITLEMENTS" "$GENERATED_EXTENSION_ENTITLEMENTS"
/usr/libexec/PlistBuddy -c \
  "Set :com.apple.security.application-groups:0 ${CAMERA_APP_GROUP}" \
  "$GENERATED_EXTENSION_ENTITLEMENTS"

if [[ -n "$EXTENSION_PROFILE" ]]; then
  PROFILE_GROUPS="$(/usr/libexec/PlistBuddy -c \
    'Print :Entitlements:com.apple.security.application-groups' "$PROFILE_PLIST" \
    2>/dev/null || true)"
  # PlistBuddy formats array members with indentation; normalize that
  # presentation before doing an exact membership check.
  if ! printf '%s\n' "$PROFILE_GROUPS" \
      | sed -E 's/^[[:space:]]+//' \
      | grep -Fqx "$CAMERA_APP_GROUP"; then
    echo "Error: extension provisioning profile does not permit App Group:" >&2
    echo "  ${CAMERA_APP_GROUP}" >&2
    echo "Create/enable this exact macOS App Group for ${EXT_ID}, then regenerate" >&2
    echo "EXTENSION_PROVISIONING_PROFILE. The CMIO Mach service must be prefixed" >&2
    echo "by a group listed in the extension profile." >&2
    exit 1
  fi
fi

echo "=== Building CMIO extension ==="
swift build -c release --product vphone-camera-extension
swift build -c release --product vphone-camera-installer
[[ -x "$EXT_BIN" ]] || { echo "extension binary missing: $EXT_BIN" >&2; exit 1; }
[[ -x "$INSTALLER_BIN" ]] || { echo "installer binary missing: $INSTALLER_BIN" >&2; exit 1; }

case "$INSTALLER_APP" in
  .build/*.app|"$PROJECT_ROOT"/.build/*.app) ;;
  *)
    echo "Error: CAMERA_INSTALLER_BUNDLE must be an .app below $PROJECT_ROOT/.build" >&2
    exit 1
    ;;
esac
rm -rf "$INSTALLER_APP"
mkdir -p "$EXT_DIR/Contents/MacOS" "$INSTALLER_APP/Contents/MacOS" \
  "$INSTALLER_APP/Contents/Resources"
cp -f "$EXT_BIN" "$EXT_DIR/Contents/MacOS/vphone-camera-extension"
cp -f sources/VPhoneCameraExtension-Info.plist "$EXT_DIR/Contents/Info.plist"
cp -f "$INSTALLER_BIN" "$INSTALLER_APP/Contents/MacOS/vphone-camera-installer"
cp -f sources/VPhoneCameraInstaller-Info.plist "$INSTALLER_APP/Contents/Info.plist"
# The installer is the app users see while macOS asks them to approve the
# Camera Extension. Keep its identity visually identical to vphone-cli.
cp -f sources/AppIcon.icns "$INSTALLER_APP/Contents/Resources/AppIcon.icns"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier ${EXT_ID}" \
  "$EXT_DIR/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CMIOExtension:CMIOExtensionMachServiceName ${CMIO_MACH_SERVICE_NAME}" \
  "$EXT_DIR/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier ${INSTALLER_ID}" \
  "$INSTALLER_APP/Contents/Info.plist"
if [[ -n "$EXTENSION_PROFILE" ]]; then
  [[ -f "$EXTENSION_PROFILE" ]] \
    || { echo "Error: EXTENSION_PROVISIONING_PROFILE not found: $EXTENSION_PROFILE" >&2; exit 1; }
  cp -f "$EXTENSION_PROFILE" "$EXT_DIR/Contents/embedded.provisionprofile"
fi
if [[ -n "$INSTALLER_PROFILE" ]]; then
  [[ -f "$INSTALLER_PROFILE" ]] \
    || { echo "Error: CAMERA_INSTALLER_PROVISIONING_PROFILE not found: $INSTALLER_PROFILE" >&2; exit 1; }
  cp -f "$INSTALLER_PROFILE" "$INSTALLER_APP/Contents/embedded.provisionprofile"
fi

codesign --force --sign "$IDENTITY" --entitlements "$GENERATED_EXTENSION_ENTITLEMENTS" "$EXT_DIR"
codesign --force --sign "$IDENTITY" --entitlements "$INSTALLER_ENTITLEMENTS" \
  "$INSTALLER_APP/Contents/MacOS/vphone-camera-installer"
codesign --force --sign "$IDENTITY" --entitlements "$INSTALLER_ENTITLEMENTS" "$INSTALLER_APP"
echo "CMIO installer app built at $INSTALLER_APP"
echo "CMIO extension embedded at $EXT_DIR"
