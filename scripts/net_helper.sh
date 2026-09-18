#!/bin/zsh
# net_helper.sh — fetch the userspace networking helper (gvproxy) used by
# `--network tunnel`.
#
#   make net_helper
#   GVPROXY_VERSION=v0.8.9 FORCE=1 make net_helper
#
# Why a helper exists at all: Apple's VZNATNetworkDeviceAttachment reuses Internet
# Sharing / vmnet, and the pf NAT rules it installs are bound to the host's *physical*
# interface. Once a VPN owns the default route, guest egress is black-holed — in NAT and
# bridged alike. gvproxy terminates the guest's DHCP/DNS/TCP in userspace and dials out
# with ordinary host sockets, so egress follows the host routing table, VPN included.
# See research/userspace_networking_gvproxy.md.

set -euo pipefail

SCRIPT_DIR="${0:a:h}"
PROJECT_ROOT="${SCRIPT_DIR:h}"

VERSION="${GVPROXY_VERSION:-v0.8.9}"
TOOLS_PREFIX="${TOOLS_PREFIX:-${PROJECT_ROOT}/.tools}"
DEST_DIR="${TOOLS_PREFIX}/bin"
DEST="${DEST_DIR}/gvproxy"
FORCE="${FORCE:-0}"

# sha256 of the pinned release's gvproxy-darwin asset (from its sha256sums file).
PINNED_VERSION="v0.8.9"
PINNED_SHA256="c6f7b4bc7f21bf810b5cf54e04d979b014c5d96472a03a9e97fe62a00940067c"

BASE_URL="https://github.com/containers/gvisor-tap-vsock/releases/download/${VERSION}"

if [[ -x "${DEST}" && "${FORCE}" != "1" ]]; then
  echo "[=] gvproxy already present: ${DEST}"
  echo "    (re-download with: FORCE=1 make net_helper)"
  exit 0
fi

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

echo "=== Downloading gvproxy ${VERSION} (gvisor-tap-vsock) ==="
curl -fL --progress-bar -o "${TMP_DIR}/gvproxy" "${BASE_URL}/gvproxy-darwin"

expected_sha="${PINNED_SHA256}"
if [[ "${VERSION}" != "${PINNED_VERSION}" ]]; then
  # Unpinned versions are verified against the release's own checksum file.
  expected_sha=""
  if curl -fsL -o "${TMP_DIR}/sha256sums" "${BASE_URL}/sha256sums"; then
    expected_sha="$(awk '$2 == "gvproxy-darwin" { print $1 }' "${TMP_DIR}/sha256sums")"
  fi
  if [[ -z "${expected_sha}" ]]; then
    echo "[!] no checksum available for ${VERSION}; skipping verification" >&2
  fi
fi

if [[ -n "${expected_sha}" ]]; then
  actual_sha="$(shasum -a 256 "${TMP_DIR}/gvproxy" | awk '{ print $1 }')"
  if [[ "${actual_sha}" != "${expected_sha}" ]]; then
    echo "[x] checksum mismatch for gvproxy-darwin ${VERSION}" >&2
    echo "    expected: ${expected_sha}" >&2
    echo "    actual:   ${actual_sha}" >&2
    exit 1
  fi
  echo "[+] checksum OK (${actual_sha})"
fi

mkdir -p "${DEST_DIR}"
install -m 0755 "${TMP_DIR}/gvproxy" "${DEST}"
# curl does not set the quarantine attribute, but strip it if some setup added it.
xattr -d com.apple.quarantine "${DEST}" 2>/dev/null || true

echo "[+] installed: ${DEST}"
echo ""
echo "Use it with:"
echo "  ./.build/release/vphone-cli vm config <VM_NAME> --network tunnel"
echo "  make boot"
