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

BINARY=".build/release/vphone-cli"
BUNDLE=".build/vphone-cli.app"
BUNDLE_BIN="${BUNDLE}/Contents/MacOS/vphone-cli"
INFO_PLIST="sources/Info.plist"
ENTITLEMENTS="sources/vphone.entitlements"
BUILD_INFO="sources/vphone-cli/VPhoneBuildInfo.swift"
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

echo "=== Signing with entitlements ==="
codesign --force --sign - --entitlements "$ENTITLEMENTS" "$BINARY"
echo "  signed OK → ${BINARY}"

# --- Bundle (.app used for GUI boot) ---
echo "=== Bundling ${BUNDLE} ==="
mkdir -p "${BUNDLE}/Contents/MacOS" "${BUNDLE}/Contents/Resources"
cp -f "$BINARY" "$BUNDLE_BIN"
cp -f "$INFO_PLIST" "${BUNDLE}/Contents/Info.plist"
cp -f "sources/AppIcon.icns" "${BUNDLE}/Contents/Resources/AppIcon.icns"
cp -f "scripts/vphoned/signcert.p12" "${BUNDLE}/Contents/Resources/signcert.p12"
cp -f "$(command -v ldid)" "${BUNDLE}/Contents/MacOS/ldid"
codesign --force --sign - "${BUNDLE}/Contents/MacOS/ldid"
codesign --force --sign - --entitlements "$ENTITLEMENTS" "$BUNDLE_BIN"
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
rm -rf "${RES}/scripts" "${RES}/tools" "${RES}/.tools" "${RES}/vphoned.signed"
mkdir -p "${RES}/scripts" "${RES}/tools" "${RES}/.tools/bin"
# Mirror scripts/ EXCEPT the make-coupled orchestrator, toolchain source, caches.
rsync -a \
  --exclude 'setup_machine.sh' \
  --exclude 'repos' \
  --exclude '__pycache__' \
  --exclude '.git' \
  --exclude '.build' \
  scripts/ "${RES}/scripts/"
cp -f tools/apfs_snap_rename.py "${RES}/tools/apfs_snap_rename.py"
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
# vphone-amfidont helper (allows this .app through amfid). Kept in Resources —
# NOT MacOS — so bundle signing doesn't reject it as unsigned nested code; a
# Homebrew `binary` symlink exposes it on PATH.
cp -f scripts/vphone-amfidont "${RES}/vphone-amfidont"
chmod +x "${RES}/vphone-amfidont"
echo "  bundled: scripts/ (patchers+resources), tools/, .tools/bin/{trustcache,insert_dylib}, vphoned.signed, requirements.txt, debs.list, README.md, vphone-amfidont"

# Re-sign: codesign seals Contents/Resources at sign time, so the earlier
# bundle-step signature (made before these assets existed) is now stale —
# re-signing here reseals against the final Resources tree.
echo "=== Re-signing ${BUNDLE_BIN} (resealing Resources) ==="
codesign --force --sign - --entitlements "$ENTITLEMENTS" "$BUNDLE_BIN"
echo "  resealed OK"

echo ""
echo "=== Build complete ==="
echo "  binary : ${BINARY}"
echo "  bundle : ${BUNDLE}"
[[ "$BUILD_VPHONED" -eq 1 ]] && echo "  vphoned: .build/vphoned.signed"
echo ""
echo "Run: ${BINARY} --help"
