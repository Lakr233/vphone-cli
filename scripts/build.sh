#!/bin/zsh
# vphone-tier: build
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

# Five host binaries, and only ONE of them is entitled. vphone-cli is the
# user-facing entry point and carries nothing, so it always launches; vphone-vm
# holds the private virtualization keys and is what amfid can refuse;
# vphone-archive unpacks and packs without gtar, bsdtar, unzip or zstd;
# vphone-ask-for-permission is the SUDO_ASKPASS helper; vphone-amfi-allow is
# what gets vphone-vm past amfid.
#
# `make amfi_allow` runs that last one for the binaries built below. It is a
# per-build step, not a once-per-machine one, because it allowlists cdhashes and
# those change every time anything is signed.
BINARY=".build/release/vphone-cli"
VM_BINARY=".build/release/vphone-vm"
ARCHIVE_BINARY=".build/release/vphone-archive"
ASKPASS_BINARY=".build/release/vphone-ask-for-permission"
# Not built by `swift build`: SwiftPM emits arm64 and this one has to be arm64e
# to walk amfid's ObjC runtime. See the header of its C file.
AMFI_BINARY=".build/release/vphone-amfi-allow"
AMFI_SOURCE="sources/vphone-amfi-allow/vphone-amfi-allow.c"
BUNDLE=".build/vphone-cli.app"
BUNDLE_BIN="${BUNDLE}/Contents/MacOS/vphone-cli"
BUNDLE_VM="${BUNDLE}/Contents/MacOS/vphone-vm"
BUNDLE_ARCHIVE="${BUNDLE}/Contents/MacOS/vphone-archive"
BUNDLE_ASKPASS="${BUNDLE}/Contents/MacOS/vphone-ask-for-permission"
BUNDLE_AMFI="${BUNDLE}/Contents/MacOS/vphone-amfi-allow"
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
swift build -c release --jobs "${SWIFT_JOBS:-4}"

# vphone-amfi-allow, which SwiftPM cannot produce: it reads amfid's ObjC runtime
# and so must match amfid's own slice, which is arm64e. Plain clang, two system
# frameworks, no Xcode.app and nothing on PATH beyond the toolchain that just
# built everything else.
echo "=== Building vphone-amfi-allow (arm64e) ==="
clang -arch arm64e -O2 \
  -framework CoreFoundation -framework Security \
  -o "$AMFI_BINARY" "$AMFI_SOURCE"
# An arm64 build would compile and link and then fail at run time with nothing
# to say, because task_for_pid on an arm64e amfid from an arm64 tool cannot read
# the pointer-authenticated slot it is looking for. Assert the slice.
if ! file "$AMFI_BINARY" | grep -q arm64e; then
  echo "Error: ${AMFI_BINARY} is not arm64e." >&2
  exit 1
fi

# Only vphone-vm gets the entitlements. Signing vphone-cli with them too would
# put us straight back where we started: the entry point itself unable to
# launch without an AMFI bypass already in place.
echo "=== Signing ==="
codesign --force --sign - --entitlements "$ENTITLEMENTS" "$VM_BINARY"
codesign --force --sign - "$BINARY"
codesign --force --sign - "$ARCHIVE_BINARY"
codesign --force --sign - "$ASKPASS_BINARY"
codesign --force --sign - "$AMFI_BINARY"
echo "  signed: vphone-vm (entitled), vphone-cli, vphone-archive,"
echo "          vphone-ask-for-permission, vphone-amfi-allow"

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
cp -f "$ARCHIVE_BINARY" "$BUNDLE_ARCHIVE"
cp -f "$ASKPASS_BINARY" "$BUNDLE_ASKPASS"
cp -f "$AMFI_BINARY" "$BUNDLE_AMFI"
cp -f "$INFO_PLIST" "${BUNDLE}/Contents/Info.plist"
cp -f "sources/AppIcon.icns" "${BUNDLE}/Contents/Resources/AppIcon.icns"
cp -f "scripts/vphoned/signcert.p12" "${BUNDLE}/Contents/Resources/signcert.p12"
# The bundle is built over whatever is already there, so these two are removed
# although nothing copies either one any more: bundles built before VPhoneSign
# replaced ldid carry the Homebrew ldid, the only thing in here linking
# libcrypto.3 and libplist-2.0.4 and so the only thing failing gate 1; bundles
# built before the AMFI bypass became the user's own business carry
# vphone-letmein, which patched amfid's __TEXT — a write the kernel kills amfid
# for wherever vm.cs_system_enforcement is 1. Both have to go before the seal
# below, not after — removing nested code from a sealed bundle is what makes
# `codesign -v` report it as modified.
rm -f "${BUNDLE}/Contents/MacOS/ldid" "${BUNDLE}/Contents/MacOS/vphone-letmein"
# Order matters: vphone-vm is CFBundleExecutable, so signing it seals the whole
# bundle, and everything beside it in Contents/MacOS counts as nested code.
# Sign the nested binaries FIRST or the seal captures them in an earlier state
# and `codesign -v` on the bundle reports "nested code is modified or invalid".
codesign --force --sign - "$BUNDLE_BIN"
codesign --force --sign - "$BUNDLE_ARCHIVE"
codesign --force --sign - "$BUNDLE_ASKPASS"
codesign --force --sign - "$BUNDLE_AMFI"
codesign --force --sign - --entitlements "$ENTITLEMENTS" "$BUNDLE_VM"
echo "  bundled → ${BUNDLE}"

# --- Guest binaries (cross-compiled for iOS; see scripts/guest_binaries.mk) ---
# All five of them, because compiling them at CFW-install time is what made
# Xcode a requirement for running a VM. This is the build machine; it has Xcode.
if [[ "$BUILD_VPHONED" -eq 1 ]]; then
  make -f scripts/guest_binaries.mk guest_binaries GIT_HASH="$GIT_HASH"
  # vphoned.signed is the copy the host pushes into a *running* guest over vsock,
  # so it is signed here rather than at install time. ldid used to do this;
  # `vphone-cli sign` writes the same bytes and needs no Homebrew, which takes
  # the last external program out of the build as well as out of dist.
  echo "=== Signing vphoned ==="
  cp .build/guest/vphoned .build/vphoned.signed
  "$BINARY" sign \
    --entitlements scripts/vphoned/entitlements.plist --merge \
    --pkcs12 scripts/vphoned/signcert.p12 \
    .build/vphoned.signed
  echo "  signed → .build/vphoned.signed"
fi

# --- Bundle the standalone runtime mini-repo into Contents/Resources ---
RES="${BUNDLE}/Contents/Resources"
echo "=== Bundling runtime assets → ${RES} ==="
# The bundle is built over whatever is already there, so ${RES}/tools and
# ${RES}/requirements.txt are still removed although nothing creates either any
# more: bundles built before `cfw flip-snapshot` replaced the snapshot-rename
# script carry an empty tools/, and bundles built before the restore backend
# moved in-process carry a pip requirements list the app would never read.
# The bundle is built over whatever is already there, so these are removed
# although nothing creates any of them any more. ${RES}/tools and
# requirements.txt date from the Python restore bridge. ${RES}/.tools held a
# Homebrew-linked `trustcache` that nothing ever invoked — it was the only file
# in the bundle pulling in /opt/homebrew/opt/openssl@3/lib/libcrypto.3.dylib,
# and the only reason the dependency gate had anything left to find. The trust
# cache itself is generated by /System/Library/SecurityResearch's cryptexctl.
rm -rf "${RES}/scripts" "${RES}/guest" "${RES}/tools" "${RES}/.tools" \
  "${RES}/vphoned.signed" "${RES}/requirements.txt"
mkdir -p "${RES}/scripts"
# An ALLOWLIST, from each script's own `# vphone-tier:` line. This used to be a
# list of exclusions, which meant anything new shipped by default — and so the
# .app carried build.sh, check_aux.sh and setup_tools.sh, the last of which runs
# `brew install`. See scripts/dist_manifest.sh for the three tiers.
zsh scripts/dist_manifest.sh | rsync -a --files-from=- scripts/ "${RES}/scripts/"
# The five guest binaries, cross-compiled above. They are iOS Mach-Os and never
# run on this host; the CFW installers copy and sign them into the VM.
[[ -d .build/guest ]] && cp -R .build/guest "${RES}/guest"
[[ -f .build/vphoned.signed ]] && cp -f .build/vphoned.signed "${RES}/vphoned.signed" || true
# debs.list = extra-deb manifest (fetch_debs.sh reads $base/debs.list); README.md
# = the Tested-Environments table fw_prepare.sh reads to label Supported firmwares.
cp -f debs.list "${RES}/debs.list"
cp -f README.md "${RES}/README.md"
echo "  bundled: scripts/ (dist tier), guest/ (5 iOS binaries), vphoned.signed,"
echo "           debs.list, README.md"

# Re-sign: codesign seals Contents/Resources at sign time, so the earlier
# bundle-step signature (made before these assets existed) is now stale —
# re-signing here reseals against the final Resources tree.
echo "=== Re-signing bundled binaries (resealing Resources) ==="
# Nested first, main executable last — see the bundling step above.
codesign --force --sign - "$BUNDLE_BIN"
codesign --force --sign - "$BUNDLE_ARCHIVE"
codesign --force --sign - "$BUNDLE_ASKPASS"
codesign --force --sign - "$BUNDLE_AMFI"
codesign --force --sign - --entitlements "$ENTITLEMENTS" "$BUNDLE_VM"
codesign -v "$BUNDLE_VM" \
  || { echo "Error: the bundle seal did not verify after signing." >&2; exit 1; }
echo "  resealed OK"

echo ""
echo "=== Build complete ==="
echo "  vphone-cli         : ${BINARY} (no entitlements — always launches)"
echo "  vphone-vm          : ${VM_BINARY} (entitled — amfid may refuse it)"
echo "  vphone-archive     : ${ARCHIVE_BINARY}"
echo "  vphone-ask-for-permission : ${ASKPASS_BINARY}"
echo "  vphone-amfi-allow  : ${AMFI_BINARY} (arm64e)"
echo "  bundle             : ${BUNDLE}"
[[ "$BUILD_VPHONED" -eq 1 ]] && echo "  vphoned            : .build/vphoned.signed"
echo ""
echo "Run: ${BINARY} --help"
echo "If vphone-vm is killed the moment it launches, amfid refused its entitlements."
echo "'make amfi_allow' allows this build past it; re-run it after every build,"
echo "because it allowlists cdhashes and those change with every signature."
