#!/bin/zsh
# build.sh — Build, sign, and bundle vphone-cli (+ cross-compile vphoned).
#
# This is the bootstrap step that a running binary cannot do for itself:
# it compiles the vphone-cli binary, signs it with the PV=3 entitlements,
# wraps it in the .app bundle used for GUI boot, and cross-compiles + signs
# the vphoned guest daemon. Everything else in the project is driven by the
# resulting `vphone-cli` binary — this script is the only build entrypoint.
#
# Usage:
#   ./scripts/build.sh              # build + sign + bundle + vphoned
#   ./scripts/build.sh --no-vphoned # skip the vphoned cross-compile
set -euo pipefail

SCRIPT_DIR="${0:A:h}"
PROJECT_ROOT="${SCRIPT_DIR:h}"
cd "$PROJECT_ROOT"

# Four host binaries, and only ONE of them is entitled. vphone-cli is the
# user-facing entry point and carries nothing, so it always launches; vphone-vm
# holds the private virtualization keys and is what amfid can refuse;
# vphone-letmein opens a window when it does; vphone-archive unpacks and packs
# without gtar, bsdtar, unzip or zstd.
BINARY=".build/release/vphone-cli"
VM_BINARY=".build/release/vphone-vm"
LETMEIN_BINARY=".build/release/vphone-letmein"
ARCHIVE_BINARY=".build/release/vphone-archive"
BUNDLE=".build/vphone-cli.app"
BUNDLE_BIN="${BUNDLE}/Contents/MacOS/vphone-cli"
BUNDLE_VM="${BUNDLE}/Contents/MacOS/vphone-vm"
BUNDLE_LETMEIN="${BUNDLE}/Contents/MacOS/vphone-letmein"
BUNDLE_ARCHIVE="${BUNDLE}/Contents/MacOS/vphone-archive"
INFO_PLIST="sources/Info.plist"
ENTITLEMENTS="sources/vphone.entitlements"
BUILD_INFO="sources/VPhoneCore/VPhoneBuildInfo.swift"
GIT_HASH="$(git rev-parse --short HEAD 2>/dev/null || echo unknown)"

BUILD_VPHONED=1
for arg in "$@"; do
  case "$arg" in
    --no-vphoned) BUILD_VPHONED=0 ;;
    -h|--help) echo "Usage: $0 [--no-vphoned]"; exit 0 ;;
    *) echo "Unknown option: $arg" >&2; exit 1 ;;
  esac
done

# --- Build + sign the binary ---
echo "=== Building vphone-cli (${GIT_HASH}) ==="
echo '// Auto-generated — do not edit' > "$BUILD_INFO"
echo "enum VPhoneBuildInfo { static let commitHash = \"${GIT_HASH}\" }" >> "$BUILD_INFO"
swift build -c release

# Only vphone-vm gets the entitlements. Signing vphone-cli with them too would
# put us straight back where we started: the entry point itself unable to
# launch without an AMFI bypass already in place.
echo "=== Signing ==="
codesign --force --sign - --entitlements "$ENTITLEMENTS" "$VM_BINARY"
codesign --force --sign - "$BINARY"
codesign --force --sign - "$LETMEIN_BINARY"
codesign --force --sign - "$ARCHIVE_BINARY"
echo "  signed: vphone-vm (entitled), vphone-cli, vphone-letmein, vphone-archive"

# An unentitled vphone-vm is worse than a broken one: it launches perfectly,
# which convinces vphone-cli's AMFI probe that nothing is wrong, and only fails
# later when it tries to create a PV=3 machine. A bare `swift build` leaves
# exactly that state behind. Catch it at the source.
if ! codesign -d --entitlements - --xml "$VM_BINARY" 2>/dev/null \
     | grep -q 'com.apple.private.virtualization'; then
  echo "Error: ${VM_BINARY} is not entitled after signing." >&2
  echo "       It would still launch, and would still fail to create a VM." >&2
  exit 1
fi

# --- Bundle (.app used for GUI boot) ---
# The .app is never opened through Launch Services — every caller runs a binary
# inside it directly. It exists so the process that becomes an NSApplication
# has a bundle: icon, LSUIElement, and the location usage strings. That process
# is vphone-vm, which is why it, and not vphone-cli, is CFBundleExecutable.
echo "=== Bundling ${BUNDLE} ==="
mkdir -p "${BUNDLE}/Contents/MacOS" "${BUNDLE}/Contents/Resources"
cp -f "$BINARY" "$BUNDLE_BIN"
cp -f "$VM_BINARY" "$BUNDLE_VM"
cp -f "$LETMEIN_BINARY" "$BUNDLE_LETMEIN"
cp -f "$ARCHIVE_BINARY" "$BUNDLE_ARCHIVE"
cp -f "$INFO_PLIST" "${BUNDLE}/Contents/Info.plist"
cp -f "sources/AppIcon.icns" "${BUNDLE}/Contents/Resources/AppIcon.icns"
cp -f "scripts/vphoned/signcert.p12" "${BUNDLE}/Contents/Resources/signcert.p12"
# The bundle is built over whatever is already there, so Contents/MacOS/ldid is
# removed although nothing copies it any more: bundles built before VPhoneSign
# replaced ldid carry the Homebrew one, which is the only thing in here linking
# libcrypto.3 and libplist-2.0.4 and so the only thing failing gate 1. It has to
# go before the seal below, not after — removing nested code from a sealed
# bundle is what makes `codesign -v` report it as modified.
rm -f "${BUNDLE}/Contents/MacOS/ldid"
# Order matters: vphone-vm is CFBundleExecutable, so signing it seals the whole
# bundle, and everything beside it in Contents/MacOS counts as nested code.
# Sign the nested binaries FIRST or the seal captures them in an earlier state
# and `codesign -v` on the bundle reports "nested code is modified or invalid".
codesign --force --sign - "$BUNDLE_BIN"
codesign --force --sign - "$BUNDLE_LETMEIN"
codesign --force --sign - "$BUNDLE_ARCHIVE"
codesign --force --sign - --entitlements "$ENTITLEMENTS" "$BUNDLE_VM"
echo "  bundled → ${BUNDLE}"

# --- vphoned guest daemon (cross-compiled + signed for iOS arm64) ---
if [[ "$BUILD_VPHONED" -eq 1 ]]; then
  command -v ldid >/dev/null 2>&1 \
    || { echo "Error: ldid not found. Run: brew install ldid-procursus" >&2; exit 1; }
  echo "=== Building vphoned ==="
  make -C scripts/vphoned GIT_HASH="$GIT_HASH"
  echo "=== Signing vphoned ==="
  mkdir -p .build
  cp scripts/vphoned/vphoned .build/vphoned.signed
  ldid \
    -Sscripts/vphoned/entitlements.plist \
    -M "-Kscripts/vphoned/signcert.p12" \
    .build/vphoned.signed
  echo "  signed → .build/vphoned.signed"
fi

# --- Bundle the standalone runtime mini-repo into Contents/Resources ---
RES="${BUNDLE}/Contents/Resources"
echo "=== Bundling runtime assets → ${RES} ==="
# The bundle is built over whatever is already there, so ${RES}/tools is still
# removed although nothing creates it any more: bundles built before
# `cfw flip-snapshot` replaced apfs_snap_rename.py carry an empty one.
rm -rf "${RES}/scripts" "${RES}/tools" "${RES}/.tools" "${RES}/vphoned.signed"
mkdir -p "${RES}/scripts" "${RES}/.tools/bin"
# Mirror scripts/ EXCEPT the make-coupled orchestrator, toolchain source, caches.
rsync -a \
  --exclude 'setup_machine.sh' \
  --exclude 'repos' \
  --exclude '__pycache__' \
  --exclude '.git' \
  --exclude '.build' \
  scripts/ "${RES}/scripts/"
# Custom-built tools (bundled; not brew/pip). apfs_sealvolume is NOT bundled
# (it is extracted from the target IPSW at `fw prepare` time — Task 5).
for t in trustcache insert_dylib; do
  if [[ -x ".tools/bin/$t" ]]; then cp -f ".tools/bin/$t" "${RES}/.tools/bin/$t"
  else echo "Error: .tools/bin/$t missing — run ./scripts/setup_tools.sh first" >&2; exit 1; fi
done
[[ -f .build/vphoned.signed ]] && cp -f .build/vphoned.signed "${RES}/vphoned.signed" || true
# requirements.txt lets the app provision its own ~/.vphone/venv on first run
# (see VPhoneResources.pythonExecutable) — the app carries no venv itself.
cp -f requirements.txt "${RES}/requirements.txt"
# debs.list = extra-deb manifest (fetch_debs.sh reads $base/debs.list); README.md
# = the Tested-Environments table fw_prepare.sh reads to label Supported firmwares.
cp -f debs.list "${RES}/debs.list"
cp -f README.md "${RES}/README.md"
echo "  bundled: scripts/ (patchers+resources), .tools/bin/{trustcache,insert_dylib}, vphoned.signed, requirements.txt, debs.list, README.md"

# Re-sign: codesign seals Contents/Resources at sign time, so the earlier
# bundle-step signature (made before these assets existed) is now stale —
# re-signing here reseals against the final Resources tree.
echo "=== Re-signing bundled binaries (resealing Resources) ==="
# Nested first, main executable last — see the bundling step above.
codesign --force --sign - "$BUNDLE_BIN"
codesign --force --sign - "$BUNDLE_LETMEIN"
codesign --force --sign - "$BUNDLE_ARCHIVE"
codesign --force --sign - --entitlements "$ENTITLEMENTS" "$BUNDLE_VM"
codesign -v "$BUNDLE_VM" \
  || { echo "Error: the bundle seal did not verify after signing." >&2; exit 1; }
echo "  resealed OK"

echo ""
echo "=== Build complete ==="
echo "  vphone-cli     : ${BINARY} (no entitlements — always launches)"
echo "  vphone-vm      : ${VM_BINARY} (entitled — amfid may refuse it)"
echo "  vphone-letmein : ${LETMEIN_BINARY}"
echo "  vphone-archive : ${ARCHIVE_BINARY}"
echo "  bundle         : ${BUNDLE}"
[[ "$BUILD_VPHONED" -eq 1 ]] && echo "  vphoned        : .build/vphoned.signed"
echo ""
echo "Run: ${BINARY} --help"
