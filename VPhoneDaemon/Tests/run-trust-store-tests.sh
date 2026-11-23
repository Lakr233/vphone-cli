#!/bin/zsh
set -euo pipefail

# Builds the guest-independent GuestTrustStore logic with TrustStoreTests.swift
# for the Mac and runs them: the admin-domain install/remove/list flow driven
# through injected GuestTrustStore.SPI fakes (the all-or-none install flow and
# its rollback, the SPI-failure / malformed-CopyAll / SPI-unavailable /
# NULL-store paths, and the serial-queue serialization), the REQ-006 input
# rejects, and the SecCertificateCopySubjectSummary subject rendering with its
# control-char sanitization. No live trustd and no guest are needed. A fixture CA
# (CN=Test CA) is generated with openssl and passed as argv[1] for the subject
# and sha256 assertions.

daemon="${0:a:h:h}"
temporary="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/vphone-trust-store-tests.XXXXXX")"
trap '/bin/rm -rf "$temporary"' EXIT

compiler=("${SWIFTC:-swiftc}")
[[ -x /usr/bin/xcrun ]] && compiler=(/usr/bin/xcrun --sdk macosx swiftc)

flags=(-swift-version 6 -module-cache-path "$temporary/modules")

"${compiler[@]}" "${flags[@]}" -parse-as-library \
    "$daemon/Daemon/GuestMethodSpec.swift" \
    "$daemon/Daemon/GuestPaging.swift" \
    "$daemon/Daemon/GuestTrustStore.swift" \
    "$daemon/Daemon/GuestSecurityCADispatch.swift" \
    "$daemon/Tests/TrustStoreTests.swift" \
    -o "$temporary/trust-store-tests"

/usr/bin/openssl req -x509 -newkey rsa:2048 -keyout "$temporary/key.pem" -nodes -days 1 \
    -subj "/CN=Test CA" -outform DER -out "$temporary/cert.der" 2>/dev/null

"$temporary/trust-store-tests" "$temporary/cert.der"
